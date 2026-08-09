import Darwin
import Foundation
import Hummingbird

struct CompanionGatewayEndpoint: Equatable, Sendable {
    let port: Int
    let loopbackURL: URL
    let lanURLs: [URL]

    init(
        port: Int,
        lanAddresses: [String] = CompanionNetworkAddresses.lanIPv4Addresses()
    ) {
        self.port = port
        loopbackURL = URL(string: "http://127.0.0.1:\(port)")!
        lanURLs = lanAddresses.compactMap {
            URL(string: "http://\($0):\(port)")
        }
    }

    var preferredLANURL: URL? {
        lanURLs.first
    }
}

enum CompanionNetworkAddresses {
    static func lanIPv4Addresses() -> [String] {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0 else { return [] }
        defer { freeifaddrs(interfacePointer) }

        var candidates: [(interface: String, address: String)] = []
        var current = interfacePointer
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }
            guard
                let socketAddress = interface.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET),
                interface.ifa_flags & UInt32(IFF_UP) != 0,
                interface.ifa_flags & UInt32(IFF_RUNNING) != 0,
                interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                interface.ifa_flags & UInt32(IFF_POINTOPOINT) == 0
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    socketAddress,
                    socklen_t(socketAddress.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0
            else {
                continue
            }
            candidates.append(
                (
                    String(cString: interface.ifa_name),
                    String(cString: host)
                )
            )
        }

        candidates.sort {
            let left = interfacePriority($0.interface)
            let right = interfacePriority($1.interface)
            return left == right
                ? $0.interface < $1.interface
                : left < right
        }

        var seen: Set<String> = []
        let addresses = candidates.map(\.address).filter { seen.insert($0).inserted }
        let routableAddresses = addresses.filter { !$0.hasPrefix("169.254.") }
        return routableAddresses.isEmpty ? addresses : routableAddresses
    }

    private static func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        if name.hasPrefix("bridge") { return 2 }
        return 3
    }
}

struct CompanionHealth: Codable, Equatable, Sendable {
    let v: Int
    let producer: String
    let streamID: String
    let ready: Bool

    enum CodingKeys: String, CodingKey {
        case v
        case producer
        case streamID = "streamId"
        case ready
    }
}

struct CompanionAssetStore: Sendable {
    let rootURL: URL?

    init(rootURL: URL? = CompanionAssetStore.defaultRootURL()) {
        self.rootURL = rootURL
    }

    var isReady: Bool {
        guard let rootURL else { return false }
        return ["index.html", "styles.css", "app.js"].allSatisfy {
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent($0).path
            )
        }
    }

    func load(_ filename: String) throws -> Data {
        guard
            let rootURL,
            ["index.html", "styles.css", "app.js"].contains(filename)
        else {
            throw HTTPError(.notFound)
        }
        return try Data(contentsOf: rootURL.appendingPathComponent(filename))
    }

    static func defaultRootURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment[
            "PUNDERCLASS_COMPANION_ASSET_DIR"
        ] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("LiveAssistant", isDirectory: true)
            )
        }
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Prototypes/LiveAssistant", isDirectory: true)
        )
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Prototypes/LiveAssistant", isDirectory: true)
        )
        return candidates.first { candidate in
            fileManager.fileExists(
                atPath: candidate.appendingPathComponent("index.html").path
            )
        }
    }
}

enum CompanionGatewayRoutes {
    static func router(
        hub: CompanionEventHub,
        assets: CompanionAssetStore
    ) -> Router<BasicRequestContext> {
        let router = Router()

        router.get("/") { request, _ -> Response in
            try validateCompanionHost(request)
            return try assetResponse(
                assets.load("index.html"),
                contentType: "text/html; charset=utf-8"
            )
        }
        router.get("/styles.css") { request, _ -> Response in
            try validateCompanionHost(request)
            return try assetResponse(
                assets.load("styles.css"),
                contentType: "text/css; charset=utf-8"
            )
        }
        router.get("/app.js") { request, _ -> Response in
            try validateCompanionHost(request)
            return try assetResponse(
                assets.load("app.js"),
                contentType: "text/javascript; charset=utf-8"
            )
        }

        router.get("/v1/health") { request, _ -> Response in
            try validateCompanionHost(request)
            return try jsonResponse(
                CompanionHealth(
                    v: 1,
                    producer: "PermanentUnderclass",
                    streamID: hub.streamID,
                    ready: assets.isReady
                )
            )
        }

        router.get("/v1/snapshot") { request, _ -> Response in
            try validateCompanionHost(request)
            return try jsonResponse(await hub.snapshot())
        }

        router.get("/v1/events") { request, _ -> Response in
            try validateCompanionHost(request)
            let queryCursor = request.uri.queryParameters["cursor"].map(String.init)
            let headerCursor = header(named: "last-event-id", in: request)
            // A fresh EventSource supplies the query cursor. Its built-in retry
            // then supplies a newer Last-Event-ID on the same URL, which must
            // win so a long-running client does not replay from its first cursor.
            let cursorDescription = resumeCursor(
                queryCursor: queryCursor,
                lastEventID: headerCursor
            )
            let cursor = cursorDescription.flatMap(CompanionCursor.init(description:))
            if cursorDescription != nil, cursor == nil {
                throw HTTPError(.badRequest, message: "The event cursor is invalid.")
            }
            let stream = await hub.subscribe(after: cursor)
            let body = ResponseBody { writer in
                try await writer.write(ByteBuffer(string: "retry: 1000\n\n"))
                do {
                    for await item in stream {
                        try Task.checkCancellation()
                        try await writer.write(try sseBuffer(for: item))
                    }
                    try await writer.finish(nil)
                } catch {
                    try? await writer.finish(nil)
                    throw error
                }
            }
            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/event-stream; charset=utf-8",
                    .cacheControl: "no-cache",
                    .connection: "keep-alive"
                ],
                body: body
            )
        }

        router.post("/v1/commands") { request, context -> Response in
            try validateCompanionHost(request)
            guard
                let key = header(named: "idempotency-key", in: request)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty,
                key.count <= 200
            else {
                throw HTTPError(
                    .badRequest,
                    message: "A valid Idempotency-Key header is required."
                )
            }
            let command = try await request.decode(
                as: CompanionCommandRequest.self,
                context: context
            )
            return try jsonResponse(
                await hub.apply(command: command, idempotencyKey: key)
            )
        }

        return router
    }

    private static func assetResponse(
        _ data: Data,
        contentType: String
    ) throws -> Response {
        Response(
            status: .ok,
            headers: [
                .contentType: contentType,
                .cacheControl: "no-store"
            ],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    private static func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        let data = try CompanionJSON.encoder().encode(value)
        return Response(
            status: .ok,
            headers: [
                .contentType: "application/json; charset=utf-8",
                .cacheControl: "no-store"
            ],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    private static func sseBuffer(for item: CompanionStreamItem) throws -> ByteBuffer {
        switch item {
        case let .heartbeat(date):
            let value = ISO8601DateFormatter().string(from: date)
            return ByteBuffer(
                string: ": heartbeat \(value)\nevent: heartbeat\ndata: {\"emittedAt\":\"\(value)\"}\n\n"
            )
        case let .event(event):
            let data = try CompanionJSON.encoder().encode(event)
            guard let json = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return ByteBuffer(
                string: "id: \(event.cursor)\nevent: \(event.name)\ndata: \(json)\n\n"
            )
        }
    }

    private static func header(named name: String, in request: Request) -> String? {
        request.headers.first {
            $0.name.description.compare(name, options: .caseInsensitive) == .orderedSame
        }?.value
    }

    private static func validateCompanionHost(_ request: Request) throws {
        guard
            let host = (request.head.authority ?? header(named: "host", in: request))?
                .lowercased()
        else {
            // Hummingbird's in-process router test transport does not synthesize
            // HTTP/1.1's required Host header. Real network requests always do.
            return
        }
        guard isAllowedCompanionAuthority(host) else {
            throw HTTPError(
                .forbidden,
                message: "Use a direct local-network address for the companion gateway."
            )
        }
    }

    static func isAllowedCompanionAuthority(_ authority: String) -> Bool {
        let normalized = authority
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "localhost" {
            return true
        }
        if normalized.hasPrefix("localhost:") {
            return isValidPort(String(normalized.dropFirst("localhost:".count)))
        }

        if normalized.hasPrefix("[") {
            guard let closingBracket = normalized.firstIndex(of: "]") else {
                return false
            }
            let hostStart = normalized.index(after: normalized.startIndex)
            let host = String(normalized[hostStart..<closingBracket])
            let suffix = normalized[normalized.index(after: closingBracket)...]
            if !suffix.isEmpty {
                guard
                    suffix.first == ":",
                    isValidPort(String(suffix.dropFirst()))
                else {
                    return false
                }
            }
            var address = in6_addr()
            return host.withCString {
                inet_pton(AF_INET6, $0, &address) == 1
            }
        }

        let parts = normalized.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard parts.count == 1 || parts.count == 2 else { return false }
        if parts.count == 2, !isValidPort(String(parts[1])) { return false }
        var address = in_addr()
        return String(parts[0]).withCString {
            inet_pton(AF_INET, $0, &address) == 1
        }
    }

    private static func isValidPort(_ value: String) -> Bool {
        guard let port = Int(value) else { return false }
        return (1...65_535).contains(port)
    }

    static func resumeCursor(queryCursor: String?, lastEventID: String?) -> String? {
        lastEventID ?? queryCursor
    }
}

final class CompanionGateway: @unchecked Sendable {
    static let preferredPort: Int = {
        guard
            let rawValue = ProcessInfo.processInfo.environment[
                "PUNDERCLASS_COMPANION_PORT"
            ],
            let value = Int(rawValue),
            (1_024...65_535).contains(value)
        else {
            return 4_173
        }
        return value
    }()

    let hub: CompanionEventHub
    let assets: CompanionAssetStore
    private let preferredPort: Int
    private var serverTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    init(
        hub: CompanionEventHub = CompanionEventHub(),
        assets: CompanionAssetStore = CompanionAssetStore(),
        preferredPort: Int = CompanionGateway.preferredPort
    ) {
        self.hub = hub
        self.assets = assets
        self.preferredPort = preferredPort
    }

    func start(
        onReady: @escaping (CompanionGatewayEndpoint) -> Void = { _ in },
        onFailure: @escaping (String) -> Void = { _ in }
    ) {
        guard serverTask == nil else { return }
        let callbacks = CompanionGatewayCallbacks(
            onReady: onReady,
            onFailure: onFailure
        )
        let router = CompanionGatewayRoutes.router(hub: hub, assets: assets)
        let preferredApp = Application(
            responder: router.buildResponder(),
            configuration: .init(
                address: .hostname("0.0.0.0", port: preferredPort),
                serverName: "PermanentUnderclass Companion"
            ),
            onServerRunning: { channel in
                guard let port = channel.localAddress?.port else {
                    callbacks.onFailure(
                        "The assistant server started without a usable port."
                    )
                    return
                }
                callbacks.onReady(CompanionGatewayEndpoint(port: port))
            }
        )
        let fallbackApp = Application(
            responder: router.buildResponder(),
            configuration: .init(
                address: .hostname("0.0.0.0", port: 0),
                serverName: "PermanentUnderclass Companion"
            ),
            onServerRunning: { channel in
                guard let port = channel.localAddress?.port else {
                    callbacks.onFailure(
                        "The assistant server started without a usable port."
                    )
                    return
                }
                callbacks.onReady(CompanionGatewayEndpoint(port: port))
            }
        )
        serverTask = Task.detached(priority: .userInitiated) {
            do {
                try await preferredApp.runService(gracefulShutdownSignals: [])
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else {
                    return
                }
                do {
                    try await fallbackApp.runService(gracefulShutdownSignals: [])
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else {
                        return
                    }
                    callbacks.onFailure(error.localizedDescription)
                }
            }
        }
        let hub = hub
        heartbeatTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await hub.heartbeat()
            }
        }
    }

    func stop() {
        serverTask?.cancel()
        heartbeatTask?.cancel()
        serverTask = nil
        heartbeatTask = nil
    }

    deinit {
        stop()
    }
}

private final class CompanionGatewayCallbacks: @unchecked Sendable {
    let onReady: (CompanionGatewayEndpoint) -> Void
    let onFailure: (String) -> Void

    init(
        onReady: @escaping (CompanionGatewayEndpoint) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.onReady = onReady
        self.onFailure = onFailure
    }
}

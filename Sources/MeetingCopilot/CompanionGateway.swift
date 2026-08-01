import Foundation
import Hummingbird

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
            try validateLoopbackHost(request)
            return try assetResponse(
                assets.load("index.html"),
                contentType: "text/html; charset=utf-8"
            )
        }
        router.get("/styles.css") { request, _ -> Response in
            try validateLoopbackHost(request)
            return try assetResponse(
                assets.load("styles.css"),
                contentType: "text/css; charset=utf-8"
            )
        }
        router.get("/app.js") { request, _ -> Response in
            try validateLoopbackHost(request)
            return try assetResponse(
                assets.load("app.js"),
                contentType: "text/javascript; charset=utf-8"
            )
        }

        router.get("/v1/health") { request, _ -> Response in
            try validateLoopbackHost(request)
            return try jsonResponse(
                CompanionHealth(
                    v: 1,
                    producer: "PUnderclass",
                    streamID: hub.streamID,
                    ready: assets.isReady
                )
            )
        }

        router.get("/v1/snapshot") { request, _ -> Response in
            try validateLoopbackHost(request)
            return try jsonResponse(await hub.snapshot())
        }

        router.get("/v1/events") { request, _ -> Response in
            try validateLoopbackHost(request)
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
            try validateLoopbackHost(request)
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

    private static func validateLoopbackHost(_ request: Request) throws {
        guard
            let host = (request.head.authority ?? header(named: "host", in: request))?
                .lowercased()
        else {
            // Hummingbird's in-process router test transport does not synthesize
            // HTTP/1.1's required Host header. Real network requests always do.
            return
        }
        guard isAllowedLoopbackAuthority(host) else {
            throw HTTPError(.forbidden, message: "The companion gateway is loopback-only.")
        }
    }

    static func isAllowedLoopbackAuthority(_ authority: String) -> Bool {
        switch authority.lowercased() {
        case CompanionGateway.host,
             "\(CompanionGateway.host):\(CompanionGateway.port)",
             "localhost",
             "localhost:\(CompanionGateway.port)":
            true
        default:
            false
        }
    }

    static func resumeCursor(queryCursor: String?, lastEventID: String?) -> String? {
        lastEventID ?? queryCursor
    }
}

final class CompanionGateway: @unchecked Sendable {
    static let host = "127.0.0.1"
    static let port = 4_173
    static let url = URL(string: "http://\(host):\(port)")!

    let hub: CompanionEventHub
    let assets: CompanionAssetStore
    private var serverTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    init(
        hub: CompanionEventHub = CompanionEventHub(),
        assets: CompanionAssetStore = CompanionAssetStore()
    ) {
        self.hub = hub
        self.assets = assets
    }

    func start(
        onReady: @escaping () -> Void = {},
        onFailure: @escaping (String) -> Void = { _ in }
    ) {
        guard serverTask == nil else { return }
        let callbacks = CompanionGatewayCallbacks(
            onReady: onReady,
            onFailure: onFailure
        )
        let router = CompanionGatewayRoutes.router(hub: hub, assets: assets)
        let app = Application(
            responder: router.buildResponder(),
            configuration: .init(
                address: .hostname(Self.host, port: Self.port),
                serverName: "PUnderclass Companion"
            ),
            onServerRunning: { _ in callbacks.onReady() }
        )
        serverTask = Task.detached(priority: .userInitiated) {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                return
            } catch {
                callbacks.onFailure(error.localizedDescription)
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
    let onReady: () -> Void
    let onFailure: (String) -> Void

    init(
        onReady: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.onReady = onReady
        self.onFailure = onFailure
    }
}

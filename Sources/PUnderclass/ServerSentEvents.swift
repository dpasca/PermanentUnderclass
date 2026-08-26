import Foundation

struct LiveAssistantLatencyMilestones: Equatable, Sendable {
    let responseHeadersMilliseconds: Int?
    let firstEventMilliseconds: Int?
    let firstTextDeltaMilliseconds: Int?
    let firstRenderableTextMilliseconds: Int?
    let validatedCueMilliseconds: Int

    static func unavailable(
        validatedCueMilliseconds: Int
    ) -> LiveAssistantLatencyMilestones {
        LiveAssistantLatencyMilestones(
            responseHeadersMilliseconds: nil,
            firstEventMilliseconds: nil,
            firstTextDeltaMilliseconds: nil,
            firstRenderableTextMilliseconds: nil,
            validatedCueMilliseconds: max(0, validatedCueMilliseconds)
        )
    }
}

struct LiveAssistantTransportResponse: Sendable {
    let data: Data
    let responseHeadersMilliseconds: Int?
    let firstEventMilliseconds: Int?
    let firstTextDeltaMilliseconds: Int?

    init(
        data: Data,
        responseHeadersMilliseconds: Int? = nil,
        firstEventMilliseconds: Int? = nil,
        firstTextDeltaMilliseconds: Int? = nil
    ) {
        self.data = data
        self.responseHeadersMilliseconds = responseHeadersMilliseconds
        self.firstEventMilliseconds = firstEventMilliseconds
        self.firstTextDeltaMilliseconds = firstTextDeltaMilliseconds
    }

    func latencyMilestones(
        validatedCueMilliseconds: Int,
        requestStartOffsetMilliseconds: Int = 0,
        firstRenderableTextMilliseconds: Int? = nil
    ) -> LiveAssistantLatencyMilestones {
        let offset = max(0, requestStartOffsetMilliseconds)
        return LiveAssistantLatencyMilestones(
            responseHeadersMilliseconds: responseHeadersMilliseconds.map {
                $0 + offset
            },
            firstEventMilliseconds: firstEventMilliseconds.map { $0 + offset },
            firstTextDeltaMilliseconds: firstTextDeltaMilliseconds.map {
                $0 + offset
            },
            firstRenderableTextMilliseconds:
                firstRenderableTextMilliseconds.map { $0 + offset },
            validatedCueMilliseconds: max(0, validatedCueMilliseconds)
        )
    }
}

struct ServerSentEvent: Equatable, Sendable {
    let name: String?
    let data: String
    let id: String?
}

struct ServerSentEventParser: Sendable {
    private var name: String?
    private var dataLines: [String] = []
    private var id: String?

    mutating func consume(line: String) -> ServerSentEvent? {
        if line.isEmpty {
            return dispatch()
        }
        guard !line.hasPrefix(":") else { return nil }

        let field: Substring
        var value: Substring
        if let separator = line.firstIndex(of: ":") {
            field = line[..<separator]
            value = line[line.index(after: separator)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            if !dataLines.isEmpty {
                let pendingEvent = dispatch()
                name = String(value)
                return pendingEvent
            }
            name = String(value)
        case "data":
            if !dataLines.isEmpty, accumulatedDataIsComplete() {
                let pendingEvent = dispatch()
                dataLines.append(String(value))
                return pendingEvent
            }
            dataLines.append(String(value))
        case "id":
            if !value.contains("\0") {
                id = String(value)
            }
        default:
            break
        }
        return nil
    }

    mutating func finish() -> ServerSentEvent? {
        dispatch()
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            name = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(
            name: name,
            data: dataLines.joined(separator: "\n"),
            id: id
        )
    }

    private func accumulatedDataIsComplete() -> Bool {
        let data = dataLines.joined(separator: "\n")
        if data == "[DONE]" { return true }
        guard let bytes = data.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: bytes)) != nil
    }
}

enum LiveAssistantTransportClock {
    static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int {
        let duration = ContinuousClock.now - start
        return max(
            0,
            Int(
                duration.components.seconds * 1_000
                    + duration.components.attoseconds
                        / 1_000_000_000_000_000
            )
        )
    }
}

enum LiveAssistantHTTPBody {
    static func collect(
        _ bytes: URLSession.AsyncBytes,
        limit: Int = 1_048_576
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 16_384))
        for try await byte in bytes {
            guard data.count < limit else { break }
            data.append(byte)
        }
        return data
    }
}

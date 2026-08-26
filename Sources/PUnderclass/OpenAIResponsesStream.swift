import Foundation

typealias OpenAITextDeltaHandler = @Sendable (
    _ delta: String,
    _ elapsedMilliseconds: Int
) async -> Void

enum OpenAIResponsesStream {
    static func load(
        session: URLSession,
        apiKey: String,
        body: Data,
        onTextDelta: OpenAITextDeltaHandler? = nil
    ) async throws -> LiveAssistantTransportResponse {
        var request = URLRequest(url: LiveAssistantClient.endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "text/event-stream",
            forHTTPHeaderField: "Accept"
        )
        request.timeoutInterval = 30
        request.httpBody = body

        let startedAt = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        let responseHeadersMilliseconds =
            LiveAssistantTransportClock.elapsedMilliseconds(since: startedAt)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveAssistantError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let data = try await LiveAssistantHTTPBody.collect(bytes)
            throw LiveAssistantError.requestFailed(errorMessage(from: data))
        }

        var parser = ServerSentEventParser()
        var assembler = OpenAIResponsesStreamAssembler()
        var firstEventMilliseconds: Int?
        var firstTextDeltaMilliseconds: Int?

        for try await line in bytes.lines {
            guard let event = parser.consume(line: line) else { continue }
            let elapsed = LiveAssistantTransportClock.elapsedMilliseconds(
                since: startedAt
            )
            if firstEventMilliseconds == nil {
                firstEventMilliseconds = elapsed
            }
            if let delta = try assembler.consume(event) {
                if firstTextDeltaMilliseconds == nil {
                    firstTextDeltaMilliseconds = elapsed
                }
                await onTextDelta?(delta, elapsed)
            }
        }
        if let event = parser.finish() {
            let elapsed = LiveAssistantTransportClock.elapsedMilliseconds(
                since: startedAt
            )
            if firstEventMilliseconds == nil {
                firstEventMilliseconds = elapsed
            }
            if let delta = try assembler.consume(event) {
                if firstTextDeltaMilliseconds == nil {
                    firstTextDeltaMilliseconds = elapsed
                }
                await onTextDelta?(delta, elapsed)
            }
        }

        return LiveAssistantTransportResponse(
            data: try assembler.completedResponseData(),
            responseHeadersMilliseconds: responseHeadersMilliseconds,
            firstEventMilliseconds: firstEventMilliseconds,
            firstTextDeltaMilliseconds: firstTextDeltaMilliseconds
        )
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        else {
            return "HTTP response could not be read"
        }
        return message
    }
}

struct OpenAIResponsesStreamAssembler {
    private var completedResponse: [String: Any]?

    /// Returns the text fragment carried by an output-text delta event.
    mutating func consume(_ event: ServerSentEvent) throws -> String? {
        guard event.data != "[DONE]" else { return nil }
        guard
            let data = event.data.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw LiveAssistantError.invalidResponse
        }

        let type = root["type"] as? String ?? event.name ?? ""
        switch type {
        case "response.output_text.delta":
            let delta = root["delta"] as? String ?? ""
            return delta.isEmpty ? nil : delta
        case "response.completed", "response.incomplete", "response.failed":
            guard let response = root["response"] as? [String: Any] else {
                throw LiveAssistantError.invalidResponse
            }
            completedResponse = response
        case "error":
            let message = root["message"] as? String
                ?? (root["error"] as? [String: Any])?["message"] as? String
                ?? "OpenAI response stream failed"
            throw LiveAssistantError.requestFailed(message)
        default:
            break
        }
        return nil
    }

    func completedResponseData() throws -> Data {
        guard let completedResponse else {
            throw LiveAssistantError.invalidResponse
        }
        return try JSONSerialization.data(
            withJSONObject: completedResponse,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

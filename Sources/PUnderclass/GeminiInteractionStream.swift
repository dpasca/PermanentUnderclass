import Foundation

enum GeminiInteractionStream {
    static func load(
        session: URLSession,
        apiKey: String,
        body: Data
    ) async throws -> LiveAssistantTransportResponse {
        var request = URLRequest(url: GeminiLiveAssistantAPI.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
        var assembler = GeminiInteractionStreamAssembler()
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
            if
                try assembler.consume(event),
                firstTextDeltaMilliseconds == nil
            {
                firstTextDeltaMilliseconds = elapsed
            }
        }
        if let event = parser.finish() {
            let elapsed = LiveAssistantTransportClock.elapsedMilliseconds(
                since: startedAt
            )
            if firstEventMilliseconds == nil {
                firstEventMilliseconds = elapsed
            }
            if
                try assembler.consume(event),
                firstTextDeltaMilliseconds == nil
            {
                firstTextDeltaMilliseconds = elapsed
            }
        }

        let interaction = try assembler.completedInteractionData()
        return LiveAssistantTransportResponse(
            data: try GeminiLiveAssistantAPI.normalizedResponse(interaction),
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

struct GeminiInteractionStreamAssembler {
    private var stepsByIndex: [Int: [String: Any]] = [:]
    private var argumentDeltasByIndex: [Int: String] = [:]
    private var completedInteraction: [String: Any]?

    /// Returns true when this event includes visible final-answer text. Thought
    /// summaries and tool text deliberately do not count as first output.
    mutating func consume(_ event: ServerSentEvent) throws -> Bool {
        guard event.data != "[DONE]" else { return false }
        guard
            let data = event.data.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw LiveAssistantError.invalidResponse
        }

        let eventType = root["event_type"] as? String
            ?? root["type"] as? String
            ?? event.name
            ?? ""
        switch eventType {
        case "step.start":
            guard
                let index = Self.integer(root["index"]),
                let step = root["step"] as? [String: Any]
            else {
                throw LiveAssistantError.invalidResponse
            }
            stepsByIndex[index] = step
            return Self.containsVisibleText(step)
        case "step.delta":
            guard
                let index = Self.integer(root["index"]),
                let delta = root["delta"] as? [String: Any]
            else {
                throw LiveAssistantError.invalidResponse
            }
            return try consume(delta: delta, at: index)
        case "step.stop":
            guard let index = Self.integer(root["index"]) else {
                throw LiveAssistantError.invalidResponse
            }
            try finalizeArguments(at: index)
        case "interaction.completed":
            guard let interaction = root["interaction"] as? [String: Any] else {
                throw LiveAssistantError.invalidResponse
            }
            completedInteraction = interaction
        case "error":
            let message = root["message"] as? String
                ?? (root["error"] as? [String: Any])?["message"] as? String
                ?? "Gemini interaction stream failed"
            throw LiveAssistantError.requestFailed(message)
        default:
            break
        }
        return false
    }

    func completedInteractionData() throws -> Data {
        guard var completedInteraction else {
            throw LiveAssistantError.invalidResponse
        }
        completedInteraction["steps"] = stepsByIndex.keys.sorted().compactMap {
            stepsByIndex[$0]
        }
        return try JSONSerialization.data(
            withJSONObject: completedInteraction,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private mutating func consume(
        delta: [String: Any],
        at index: Int
    ) throws -> Bool {
        guard var step = stepsByIndex[index] else {
            throw LiveAssistantError.invalidResponse
        }
        let deltaType = delta["type"] as? String ?? ""
        switch deltaType {
        case "text":
            var content = step["content"] as? [[String: Any]] ?? []
            content.append(delta)
            step["content"] = content
        case "arguments_delta":
            let fragment = delta["arguments"] as? String ?? ""
            argumentDeltasByIndex[index, default: ""] += fragment
        case "thought_summary":
            var summary = step["summary"] as? [[String: Any]] ?? []
            if let content = delta["content"] as? [String: Any] {
                summary.append(content)
            }
            step["summary"] = summary
        default:
            Self.merge(delta, into: &step, preservingStepType: true)
        }
        stepsByIndex[index] = step
        return step["type"] as? String == "model_output"
            && deltaType == "text"
            && !(delta["text"] as? String ?? "").isEmpty
    }

    private mutating func finalizeArguments(at index: Int) throws {
        guard
            let rawArguments = argumentDeltasByIndex.removeValue(forKey: index),
            !rawArguments.isEmpty
        else {
            return
        }
        guard
            let data = rawArguments.data(using: .utf8),
            let arguments = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            var step = stepsByIndex[index]
        else {
            throw LiveAssistantError.invalidResponse
        }
        step["arguments"] = arguments
        stepsByIndex[index] = step
    }

    private static func containsVisibleText(_ step: [String: Any]) -> Bool {
        guard step["type"] as? String == "model_output" else { return false }
        return (step["content"] as? [[String: Any]] ?? []).contains {
            $0["type"] as? String == "text"
                && !($0["text"] as? String ?? "").isEmpty
        }
    }

    private static func merge(
        _ source: [String: Any],
        into destination: inout [String: Any],
        preservingStepType: Bool
    ) {
        for (key, value) in source {
            if preservingStepType, key == "type" { continue }
            if
                var existing = destination[key] as? [String: Any],
                let incoming = value as? [String: Any]
            {
                merge(
                    incoming,
                    into: &existing,
                    preservingStepType: false
                )
                destination[key] = existing
            } else if
                let existing = destination[key] as? [Any],
                let incoming = value as? [Any]
            {
                destination[key] = existing + incoming
            } else if
                let existing = destination[key] as? String,
                let incoming = value as? String,
                key == "signature"
            {
                destination[key] = existing + incoming
            } else {
                destination[key] = value
            }
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

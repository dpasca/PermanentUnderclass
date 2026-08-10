import Foundation

struct EarlyInterviewBridgeGeneration: Equatable, Sendable {
    let bridge: String?
    let usage: AssistantGenerationUsage
    let generationMilliseconds: Int
    let serviceTier: String?
}

private struct EarlyInterviewBridgeOutput: Decodable {
    let bridge: String
}

struct EarlyInterviewBridgeClient: Sendable {
    static let model = "gpt-5.6-luna"
    static let serviceTier = "priority"
    static let maximumOutputTokens = 60

    static let behaviorInstructions = """
    You create an early speaking bridge for a live job interview. This is a temporary first sentence, not the substantive answer. The supplied speech state says whether the transcript is still forming, has reached a meaningful pause, or is finalized.

    If the partial speech already reveals a stable request, return one natural first-person sentence of 7 to 14 words that the candidate could begin saying immediately. Give the answer a useful direction in ordinary words: name what matters first, what should be checked, or the kind of example that should come next. Prefer simple forms such as "I'd first check what's actually slow," "I'd use one example and walk through what changed," or "The main thing is to check where the time is going" when they fit. The later answer must be able to continue naturally from the bridge.

    Use short clauses, contractions, and common words. Avoid formal coaching language such as "I'd frame this around," "I'd separate," "I'll anchor that in," "diagnostic frame," or "measurement boundary." Keep a technical term only when the partial question needs it.

    Never claim or imply a project, employer, action already taken, result, metric, achievement, responsibility, or other personal history. Never guess the missing end of a question. Do not praise or repeat the question, and do not use empty filler such as "well," "I guess," "that's a great question," or "let me think." If the request could still change materially, return an empty bridge.
    """

    private let responseLoader: @Sendable (String, Data) async throws -> Data

    init(session: URLSession = .shared) {
        responseLoader = { apiKey, body in
            try await Self.responseData(
                session: session,
                apiKey: apiKey,
                body: body
            )
        }
    }

    init(
        responseLoader: @escaping @Sendable (String, Data) async throws -> Data
    ) {
        self.responseLoader = responseLoader
    }

    func generate(
        apiKey: String,
        currentPartial: String,
        recentTranscript: String = "",
        sessionContext: String = "",
        opportunity: EarlyInterviewBridgeEvaluationPolicy.Opportunity =
            .formingTranscript
    ) async throws -> EarlyInterviewBridgeGeneration {
        let startedAt = ContinuousClock.now
        let data = try await responseLoader(
            apiKey,
            try Self.requestBody(
                currentPartial: currentPartial,
                recentTranscript: recentTranscript,
                sessionContext: sessionContext,
                opportunity: opportunity
            )
        )
        return try Self.parseResponse(
            data,
            generationMilliseconds: Self.milliseconds(
                from: ContinuousClock.now - startedAt
            )
        )
    }

    static func requestBody(
        currentPartial: String,
        recentTranscript: String = "",
        sessionContext: String = "",
        opportunity: EarlyInterviewBridgeEvaluationPolicy.Opportunity =
            .formingTranscript
    ) throws -> Data {
        let request: [String: Any] = [
            "model": model,
            "service_tier": serviceTier,
            "store": false,
            "max_output_tokens": maximumOutputTokens,
            "reasoning": ["effort": "none"],
            "input": [
                [
                    "type": "message",
                    "role": "developer",
                    "content": [
                        [
                            "type": "input_text",
                            "text": behaviorInstructions
                        ]
                    ]
                ],
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": volatilePrompt(
                                currentPartial: currentPartial,
                                recentTranscript: recentTranscript,
                                sessionContext: sessionContext,
                                opportunity: opportunity
                            )
                        ]
                    ]
                ]
            ],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "early_interview_bridge",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "bridge": ["type": "string"]
                        ],
                        "required": ["bridge"]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(
            withJSONObject: request,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func parseResponse(
        _ data: Data,
        generationMilliseconds: Int
    ) throws -> EarlyInterviewBridgeGeneration {
        guard
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw LiveAssistantError.invalidResponse
        }
        if root["status"] as? String == "incomplete" {
            let details = root["incomplete_details"] as? [String: Any]
            throw LiveAssistantError.incomplete(
                details?["reason"] as? String ?? "unknown reason"
            )
        }

        var outputText: String?
        var refusal: String?
        for output in root["output"] as? [[String: Any]] ?? [] {
            for content in output["content"] as? [[String: Any]] ?? [] {
                switch content["type"] as? String {
                case "output_text":
                    outputText = content["text"] as? String
                case "refusal":
                    refusal = content["refusal"] as? String
                default:
                    continue
                }
            }
        }
        if let refusal {
            throw LiveAssistantError.refused(refusal)
        }
        guard
            let outputText,
            let outputData = outputText.data(using: .utf8),
            let output = try? JSONDecoder().decode(
                EarlyInterviewBridgeOutput.self,
                from: outputData
            )
        else {
            throw LiveAssistantError.invalidResponse
        }

        let normalized = output.bridge.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let words = normalized.split(whereSeparator: \Character.isWhitespace)
        guard
            normalized.isEmpty
                || (normalized.count <= 180 && (5...18).contains(words.count))
        else {
            throw LiveAssistantError.invalidResponse
        }
        return EarlyInterviewBridgeGeneration(
            bridge: normalized.isEmpty ? nil : normalized,
            usage: usage(from: root),
            generationMilliseconds: max(0, generationMilliseconds),
            serviceTier: root["service_tier"] as? String
        )
    }

    private static func volatilePrompt(
        currentPartial: String,
        recentTranscript: String,
        sessionContext: String,
        opportunity: EarlyInterviewBridgeEvaluationPolicy.Opportunity
    ) -> String {
        let recent = recentTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let context = sessionContext.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let speechState: String
        switch opportunity {
        case .formingTranscript:
            speechState =
                "Still forming. Return an empty bridge if the request can still change materially."
        case .speechPause:
            speechState =
                "Meaningful speech pause. If the text contains a clear request, provide the opening now; do not wait for formal turn finalization."
        case .finalizedTurn:
            speechState =
                "Finalized interviewer turn. Return an empty bridge only when there is no clear request to answer."
        }
        return """
        SESSION CONTEXT
        \(context.isEmpty ? "Technical job interview." : context)

        SPEECH STATE
        \(speechState)

        MOST RECENT COMPLETED EXCHANGE
        \(recent.isEmpty ? "None." : recent)

        CURRENT PARTIAL INTERVIEWER SPEECH
        \(currentPartial)
        """
    }

    private static func responseData(
        session: URLSession,
        apiKey: String,
        body: Data
    ) async throws -> Data {
        var request = URLRequest(url: LiveAssistantClient.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveAssistantError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LiveAssistantError.requestFailed(errorMessage(from: data))
        }
        return data
    }

    private static func usage(
        from root: [String: Any]
    ) -> AssistantGenerationUsage {
        let usage = root["usage"] as? [String: Any] ?? [:]
        let inputDetails = usage["input_tokens_details"] as? [String: Any] ?? [:]
        let outputDetails = usage["output_tokens_details"] as? [String: Any] ?? [:]
        return AssistantGenerationUsage(
            inputTokens: integer(usage["input_tokens"]),
            cachedInputTokens: integer(inputDetails["cached_tokens"]),
            cacheWriteTokens: integer(inputDetails["cache_write_tokens"]),
            outputTokens: integer(usage["output_tokens"]),
            reasoningTokens: integer(outputDetails["reasoning_tokens"])
        )
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return "HTTP response could not be read"
        }
        return message
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private static func milliseconds(
        from duration: ContinuousClock.Duration
    ) -> Int {
        max(
            0,
            Int(
                duration.components.seconds * 1_000
                    + duration.components.attoseconds
                        / 1_000_000_000_000_000
            )
        )
    }
}

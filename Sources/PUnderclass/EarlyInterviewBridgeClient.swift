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
    You create a brief thinking bridge in a live job interview. It appears early to buy the candidate a moment while a separate model prepares the substantive answer. The full answer is independent and will not continue from this wording. The supplied speech state says whether the transcript is still forming, has reached a meaningful pause, or is finalized. This feature runs only in visibly labeled plausible-rehearsal mode.

    If the partial speech already reveals a stable request, return one natural first-person sentence of 5 to 12 words that asks for a brief moment without answering the question. Useful shapes include "Let me think of the clearest example for a moment," "Give me a second to think that through," and "Let me choose the most relevant case." Adapt lightly to whether the request asks for an example, explanation, comparison, or decision, but do not introduce any answer substance. Vary the wording and avoid every recent bridge listed in the request.

    Use short clauses and common words. It should sound like spontaneous speech, not like coaching or an announced answer framework. Do not praise or repeat the question. Do not use filler such as "um," "you know," "that's a great question," or "I guess." Do not mention the assistant, a model, a draft, sources, or waiting for another answer.

    Never state a conclusion, approach, mechanism, action, fact, opinion, project, employer, result, metric, achievement, title, or responsibility. Never guess the missing end of a question. If the request could still change materially, return an empty bridge.
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
        recentBridges: [String] = [],
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
                recentBridges: recentBridges,
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
        recentBridges: [String] = [],
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
                                recentBridges: recentBridges,
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
                || (normalized.count <= 120 && (5...12).contains(words.count))
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
        recentBridges: [String],
        sessionContext: String,
        opportunity: EarlyInterviewBridgeEvaluationPolicy.Opportunity
    ) -> String {
        let recent = recentTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let context = sessionContext.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let bridges = recentBridges
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .map { "- \($0)" }
            .joined(separator: "\n")
        let speechState: String
        switch opportunity {
        case .formingTranscript:
            speechState =
                "Still forming. Return an empty bridge if the request can still change materially."
        case .speechPause:
            speechState =
                "Meaningful speech pause. If the text contains a clear request, provide the thinking bridge now; do not wait for formal turn finalization."
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

        RECENT THINKING BRIDGES TO AVOID REPEATING
        \(bridges.isEmpty ? "None." : bridges)

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

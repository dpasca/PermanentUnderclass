import Foundation

struct AssistantGenerationUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
}

struct InterviewWingmanGeneration: Equatable, Sendable {
    let suggestion: CompanionAssistantSuggestion?
    let usage: AssistantGenerationUsage
}

enum InterviewWingmanError: LocalizedError, Equatable {
    case invalidResponse
    case requestFailed(String)
    case incomplete(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The assistant returned an unreadable response."
        case let .requestFailed(message):
            "Assistant request failed: \(message)"
        case let .incomplete(reason):
            "The assistant response was incomplete: \(reason)"
        case let .refused(message):
            "The assistant could not answer: \(message)"
        }
    }
}

private struct InterviewWingmanOutput: Decodable {
    let shouldShow: Bool
    let grounding: CompanionSuggestionGrounding
    let question: String
    let lead: String
    let talkingPoints: [CompanionTalkingPoint]
    let proof: [CompanionProofPoint]
    let watchoutTitle: String
    let watchoutBody: String
    let followup: String
    let citations: [CompanionCitation]
    let confidence: CompanionSuggestionConfidence
}

struct InterviewWingmanClient: Sendable {
    static let model = "gpt-5.6-luna"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static let behaviorInstructions = """
    You are Interview Wingman, a low-latency assistant watching a live interview transcript. Decide whether the newest completed turn from either speaker creates a useful moment for concise, immediate guidance. A turn from You may ask for help, surface uncertainty, or introduce a topic that would benefit from support; ordinary answer narration does not automatically require an interruption. A turn from Other may ask a direct question or create another useful coaching moment. Prefer the supplied local reference documents when they support the response. When they do, set grounding to localReferences and cite every document used by its exact path. When local references do not support the topic but a useful response can be given using the live discussion as context and general model knowledge, still provide it, set grounding to generalKnowledge, and return an empty citations array. Never invent personal achievements, metrics, employers, dates, or responsibilities, and never present general knowledge as locally verified. Set shouldShow to false only when neither locally grounded nor general guidance would be useful. Keep the lead short, use at most three talking points, and make the answer natural to say aloud.
    """

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generate(
        apiKey: String,
        references: ReferenceLibrarySnapshot?,
        recentTranscript: String,
        currentPartial: String,
        basedOnSequence: Int
    ) async throws -> InterviewWingmanGeneration {
        let prefix = try AssistantPromptBuilder.cachedPrefix(
            behaviorInstructions: Self.behaviorInstructions,
            references: references
        )
        let plan = AssistantPromptBuilder.plan(
            cachedPrefix: prefix,
            recentTranscript: recentTranscript,
            currentPartial: currentPartial
        )
        let body = try Self.requestBody(for: plan)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = body

        let startedAt = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InterviewWingmanError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw InterviewWingmanError.requestFailed(Self.errorMessage(from: data))
        }
        let elapsed = ContinuousClock.now - startedAt
        let milliseconds = Int(
            elapsed.components.seconds * 1_000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
        )
        return try Self.parseResponse(
            data,
            allowedReferencePaths: Set(references?.documents.map(\.relativePath) ?? []),
            basedOnSequence: basedOnSequence,
            generationMilliseconds: max(0, milliseconds)
        )
    }

    static func requestBody(for plan: AssistantPromptPlan) throws -> Data {
        let request: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 1_200,
            "reasoning": ["effort": "low"],
            "input": [
                [
                    "type": "message",
                    "role": "developer",
                    "content": [
                        [
                            "type": "input_text",
                            "text": plan.cachedPrefix,
                            "prompt_cache_breakpoint": ["mode": "explicit"]
                        ]
                    ]
                ],
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": plan.volatileSuffix]
                    ]
                ]
            ],
            "prompt_cache_key": plan.promptCacheKey,
            "prompt_cache_options": ["mode": "explicit"],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "interview_wingman_suggestion",
                    "strict": true,
                    "schema": outputSchema
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
        allowedReferencePaths: Set<String>,
        basedOnSequence: Int,
        generationMilliseconds: Int
    ) throws -> InterviewWingmanGeneration {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InterviewWingmanError.invalidResponse
        }
        if root["status"] as? String == "incomplete" {
            let details = root["incomplete_details"] as? [String: Any]
            throw InterviewWingmanError.incomplete(
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
            throw InterviewWingmanError.refused(refusal)
        }
        guard let outputText, let outputData = outputText.data(using: .utf8) else {
            throw InterviewWingmanError.invalidResponse
        }
        let output = try JSONDecoder().decode(InterviewWingmanOutput.self, from: outputData)
        let usage = usage(from: root)
        guard output.shouldShow else {
            return InterviewWingmanGeneration(suggestion: nil, usage: usage)
        }

        let allowedCitations = output.citations.filter {
            allowedReferencePaths.contains($0.path)
        }
        guard output.grounding != .localReferences || !allowedCitations.isEmpty else {
            return InterviewWingmanGeneration(suggestion: nil, usage: usage)
        }
        let citations = output.grounding == .localReferences ? allowedCitations : []
        let suggestion = CompanionAssistantSuggestion(
            id: UUID().uuidString.lowercased(),
            basedOnSequence: basedOnSequence,
            question: output.question,
            lead: output.lead,
            talkingPoints: Array(output.talkingPoints.prefix(3)),
            proof: Array(output.proof.prefix(4)),
            watchoutTitle: output.watchoutTitle,
            watchoutBody: output.watchoutBody,
            followup: output.followup,
            citations: citations,
            grounding: output.grounding,
            confidence: output.confidence,
            generatedAt: Date(),
            generationMilliseconds: generationMilliseconds
        )
        return InterviewWingmanGeneration(suggestion: suggestion, usage: usage)
    }

    private static func usage(from root: [String: Any]) -> AssistantGenerationUsage {
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
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "shouldShow": ["type": "boolean"],
            "grounding": [
                "type": "string",
                "enum": ["localReferences", "generalKnowledge"]
            ],
            "question": ["type": "string"],
            "lead": ["type": "string"],
            "talkingPoints": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "title": ["type": "string"],
                        "body": ["type": "string"]
                    ],
                    "required": ["title", "body"]
                ]
            ],
            "proof": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "value": ["type": "string"],
                        "label": ["type": "string"]
                    ],
                    "required": ["value", "label"]
                ]
            ],
            "watchoutTitle": ["type": "string"],
            "watchoutBody": ["type": "string"],
            "followup": ["type": "string"],
            "citations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "label": ["type": "string"],
                        "path": ["type": "string"]
                    ],
                    "required": ["label", "path"]
                ]
            ],
            "confidence": [
                "type": "string",
                "enum": ["low", "medium", "high"]
            ]
        ],
        "required": [
            "shouldShow",
            "grounding",
            "question",
            "lead",
            "talkingPoints",
            "proof",
            "watchoutTitle",
            "watchoutBody",
            "followup",
            "citations",
            "confidence"
        ]
    ]
}

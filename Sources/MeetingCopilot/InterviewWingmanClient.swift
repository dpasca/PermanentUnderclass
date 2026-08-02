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
    let generationMilliseconds: Int
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
    let beats: [CompanionAnswerBeat]
    let citations: [CompanionCitation]
    let confidence: CompanionSuggestionConfidence
}

struct InterviewWingmanClient: Sendable {
    static let model = "gpt-5.6-luna"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static let behaviorInstructions = """
    You are Answer Mirror, a low-latency interview companion. The current response target is an interviewer moment captured after a speech pause or at turn finalization. When it contains a sufficiently clear question or prompt, return a compact answer outline the candidate can compare with their own live response and set shouldShow to true.

    Return three to five beats, ordered as they would be spoken. Each beat has a one-to-three-word label and one terse point of roughly four to twelve words. Use telegraphic fragments, not polished sentences or prose; omit filler, transitions, and marginal wording.

    Make the outline feel like rough notes a capable person could actually say under pressure, not an idealized interview answer. Use plain, conversational wording and concrete technical nouns and verbs. Avoid resume language, corporate abstractions, slogans, tidy STAR-style arcs, and polished moral-of-the-story lessons. Do not make every beat sound optimized or impressive. When it is honest and relevant, include uncertainty, a caveat, a failed first try, or what the candidate would check next; do not invent flaws merely to sound casual. Prefer ordinary labels such as Short answer, What I saw, What I tried, Check, Catch, Result, Not sure, and Next step. Choose labels that fit the question instead of always forcing Context, My move, Proof, and Learning.

    Treat a partial as potentially incomplete and do not invent its missing ending. Prefer the supplied local reference documents for personal and context-specific facts. When they support the outline, set grounding to localReferences and cite every document used by its exact path. When they do not support the question, you may still give an approach-oriented outline using general model knowledge, set grounding to generalKnowledge, return no citations, and avoid claiming the candidate actually performed work not established in the references. Never invent achievements, metrics, employers, dates, or responsibilities. Set shouldShow to false when the interviewer moment is not clear enough to answer. Return the interviewer question in question and the shorthand outline in beats.
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
        interviewerText: String,
        basedOnSequence: Int
    ) async throws -> InterviewWingmanGeneration {
        let prefix = try AssistantPromptBuilder.cachedPrefix(
            behaviorInstructions: Self.behaviorInstructions,
            references: references
        )
        let plan = AssistantPromptBuilder.plan(
            cachedPrefix: prefix,
            recentTranscript: recentTranscript,
            currentPartial: currentPartial,
            focusSpeaker: SpeakerTag.other.rawValue,
            focusText: interviewerText
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
            "max_output_tokens": 350,
            "reasoning": ["effort": "none"],
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
                    "name": "interview_answer_mirror",
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
            return InterviewWingmanGeneration(
                suggestion: nil,
                usage: usage,
                generationMilliseconds: generationMilliseconds
            )
        }
        let question = output.question.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let beats = output.beats.map {
            CompanionAnswerBeat(
                label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                point: $0.point.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard
            !question.isEmpty,
            (3...5).contains(beats.count),
            beats.allSatisfy({ !$0.label.isEmpty && !$0.point.isEmpty })
        else {
            throw InterviewWingmanError.invalidResponse
        }

        let allowedCitations = output.citations.filter {
            allowedReferencePaths.contains($0.path)
        }
        guard output.grounding != .localReferences || !allowedCitations.isEmpty else {
            return InterviewWingmanGeneration(
                suggestion: nil,
                usage: usage,
                generationMilliseconds: generationMilliseconds
            )
        }
        let citations = output.grounding == .localReferences ? allowedCitations : []
        let suggestion = CompanionAssistantSuggestion(
            id: UUID().uuidString.lowercased(),
            basedOnSequence: basedOnSequence,
            question: question,
            beats: beats,
            citations: citations,
            grounding: output.grounding,
            confidence: output.confidence,
            generatedAt: Date(),
            generationMilliseconds: generationMilliseconds
        )
        return InterviewWingmanGeneration(
            suggestion: suggestion,
            usage: usage,
            generationMilliseconds: generationMilliseconds
        )
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
            "beats": [
                "type": "array",
                "minItems": 3,
                "maxItems": 5,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "label": ["type": "string"],
                        "point": ["type": "string"]
                    ],
                    "required": ["label", "point"]
                ]
            ],
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
            "beats",
            "citations",
            "confidence"
        ]
    ]
}

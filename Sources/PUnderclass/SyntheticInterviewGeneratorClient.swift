import Foundation

struct SyntheticInterviewGeneration: Equatable, Sendable {
    let scenario: SyntheticInterviewScenario
    let usage: AssistantGenerationUsage
    let generationMilliseconds: Int
}

enum SyntheticInterviewGeneratorError: LocalizedError, Equatable {
    case invalidResponse
    case invalidGrounding
    case requestFailed(String)
    case incomplete(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The replay generator returned an unreadable response."
        case .invalidGrounding:
            "The generated replay did not cite the indexed reference documents."
        case let .requestFailed(message):
            "Replay generation failed: \(message)"
        case let .incomplete(reason):
            "Replay generation was incomplete: \(reason)"
        case let .refused(message):
            "The replay generator could not create the scenario: \(message)"
        }
    }
}

private struct SyntheticInterviewGeneratorOutput: Decodable {
    struct Exchange: Decodable {
        let question: String
        let response: String
        let sourcePaths: [String]
    }

    let title: String
    let exchanges: [Exchange]
}

struct SyntheticInterviewGeneratorClient: Sendable {
    static let model = "gpt-5.6-luna"
    static let endpoint = LiveAssistantClient.endpoint

    static let interviewBehaviorInstructions = """
    You create a five-question mock interview from the supplied local reference documents. Choose distinct, progressively deeper questions that an interviewer could ask about the roles, projects, skills, claims, or requirements in those documents. Make the final two questions deeply technical CUDA questions when the references support CUDA as a subject. Probe concrete execution or performance-debugging details such as occupancy versus stalls, memory coalescing, divergence, shared-memory bank conflicts, register pressure, synchronization, or profiler evidence. If the references do not support CUDA as a subject, use the deepest technical topic they do support instead of inventing a CUDA background.

    For each question, write one natural first-person candidate answer of roughly 35 to 60 words so an observer can compare it with a separate live model outline. Make it sound like a capable person thinking aloud, not a memorized ideal answer. Use plain, common wording and concrete details. A candid caveat, first check, uncertainty, or failed attempt is welcome when the references support it. Avoid corporate language, resume polish, tidy STAR arcs, and a perfect lesson at the end of every answer.

    Every personal claim, metric, employer, date, responsibility, and result must be supported by the cited documents. When the documents describe a role or subject rather than the candidate's history, write an honest approach-oriented or hypothetical answer instead of inventing experience. Do not mention the documents in the spoken question or answer. Return exact indexed paths in sourcePaths and use at least one path for every exchange.
    """

    static let meetingBehaviorInstructions = """
    You create a five-question mock working meeting from the supplied local reference documents. The other participant should ask distinct, realistic questions or requests about the projects, products, plans, architecture, constraints, decisions, status, or terminology found in those documents. This is not a job interview: do not ask for career stories, strengths, weaknesses, or resume walkthroughs. Make the sequence feel like one coherent meeting that becomes more specific as it progresses.

    For each question, write one natural first-person participant response of roughly 35 to 60 words so an observer can compare it with a separate live Meeting Assistant outline. Answer the question directly, use concrete facts supported by the documents, mention an important caveat when relevant, and include a practical next step only when the material supports one. Use plain spoken language rather than corporate filler.

    Every project fact, metric, date, commitment, responsibility, decision, status, and result must be supported by the cited documents. Never invent a deadline, customer statement, decision, or promise. Do not mention the documents in the spoken question or response. Return exact indexed paths in sourcePaths and use at least one path for every exchange.
    """

    static func behaviorInstructions(for purpose: CapturePurpose) -> String {
        switch purpose {
        case .meeting:
            meetingBehaviorInstructions
        case .interview:
            interviewBehaviorInstructions
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generate(
        apiKey: String,
        references: ReferenceLibrarySnapshot,
        purpose: CapturePurpose
    ) async throws -> SyntheticInterviewGeneration {
        let body = try Self.requestBody(
            references: references,
            purpose: purpose
        )
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = body

        let startedAt = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyntheticInterviewGeneratorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SyntheticInterviewGeneratorError.requestFailed(
                Self.errorMessage(from: data)
            )
        }
        let generationMilliseconds = Self.milliseconds(
            from: ContinuousClock.now - startedAt
        )
        return try Self.parseResponse(
            data,
            references: references,
            purpose: purpose,
            generatedAt: Date(),
            generationMilliseconds: generationMilliseconds
        )
    }

    static func requestBody(
        references: ReferenceLibrarySnapshot,
        purpose: CapturePurpose
    ) throws -> Data {
        let referencePrefix = try AssistantPromptBuilder.cachedPrefix(
            behaviorInstructions: behaviorInstructions(for: purpose),
            references: references,
            referencePolicy: .requireLocalReferences
        )
        let request: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 1_600,
            "reasoning": ["effort": "low"],
            "input": [
                [
                    "type": "message",
                    "role": "developer",
                    "content": [
                        ["type": "input_text", "text": referencePrefix]
                    ]
                ],
                [
                    "type": "message",
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": purpose == .meeting
                            ? "Generate the five-exchange meeting now."
                            : "Generate the five-exchange interview now."
                    ]]
                ]
            ],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": purpose == .meeting
                        ? "reference_grounded_synthetic_meeting"
                        : "reference_grounded_synthetic_interview",
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
        references: ReferenceLibrarySnapshot,
        purpose: CapturePurpose,
        generatedAt: Date,
        generationMilliseconds: Int
    ) throws -> SyntheticInterviewGeneration {
        guard
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw SyntheticInterviewGeneratorError.invalidResponse
        }
        if root["status"] as? String == "incomplete" {
            let details = root["incomplete_details"] as? [String: Any]
            throw SyntheticInterviewGeneratorError.incomplete(
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
            throw SyntheticInterviewGeneratorError.refused(refusal)
        }
        guard let outputText, let outputData = outputText.data(using: .utf8) else {
            throw SyntheticInterviewGeneratorError.invalidResponse
        }

        let output = try JSONDecoder().decode(
            SyntheticInterviewGeneratorOutput.self,
            from: outputData
        )
        guard output.exchanges.count == 5 else {
            throw SyntheticInterviewGeneratorError.invalidResponse
        }

        let allowedPaths = Set(references.documents.map(\.relativePath))
        var turns: [SyntheticInterviewTurn] = []
        for (index, exchange) in output.exchanges.enumerated() {
            let question = exchange.question.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let answer = exchange.response.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                !question.isEmpty,
                !answer.isEmpty,
                !exchange.sourcePaths.isEmpty,
                exchange.sourcePaths.allSatisfy(allowedPaths.contains)
            else {
                throw SyntheticInterviewGeneratorError.invalidGrounding
            }

            let number = index + 1
            turns.append(
                SyntheticInterviewTurn(
                    id: "generated-\(purpose.rawValue)-question-\(number)",
                    speaker: .other,
                    text: question,
                    pauseAfterSpeech: 6
                )
            )
            turns.append(
                SyntheticInterviewTurn(
                    id: "generated-\(purpose.rawValue)-answer-\(number)",
                    speaker: .you,
                    text: answer,
                    pauseAfterSpeech: 3.4
                )
            )
        }

        let title = output.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw SyntheticInterviewGeneratorError.invalidResponse
        }
        return SyntheticInterviewGeneration(
            scenario: SyntheticInterviewScenario(
                generationVersion: SyntheticInterviewScenario.generationVersion,
                purpose: purpose,
                name: title,
                referenceRevision: references.revision,
                referenceDocumentCount: references.documents.count,
                generatedAt: generatedAt,
                finalizationDelay: 3,
                turns: turns
            ),
            usage: usage(from: root),
            generationMilliseconds: max(0, generationMilliseconds)
        )
    }

    private static func usage(
        from root: [String: Any]
    ) -> AssistantGenerationUsage {
        let usage = root["usage"] as? [String: Any] ?? [:]
        let inputDetails = usage["input_tokens_details"]
            as? [String: Any] ?? [:]
        let outputDetails = usage["output_tokens_details"]
            as? [String: Any] ?? [:]
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

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "title": ["type": "string"],
            "exchanges": [
                "type": "array",
                "minItems": 5,
                "maxItems": 5,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "question": ["type": "string"],
                        "response": ["type": "string"],
                        "sourcePaths": [
                            "type": "array",
                            "minItems": 1,
                            "items": ["type": "string"]
                        ]
                    ],
                    "required": [
                        "question",
                        "response",
                        "sourcePaths"
                    ]
                ]
            ]
        ],
        "required": ["title", "exchanges"]
    ]
}

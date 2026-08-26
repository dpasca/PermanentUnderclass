import Foundation
import XCTest
@testable import PUnderclass

final class LiveAssistantModelMatrixTests: XCTestCase {
    func testHostedCrossProviderSweetSpotMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_ASSISTANT_MODEL_MATRIX"] == "1" else {
            throw XCTSkip(
                "Set RUN_LIVE_ASSISTANT_MODEL_MATRIX=1 to run the hosted model matrix."
            )
        }

        let openAIAPIKey = try XCTUnwrap(environment["OPENAI_API_KEY"])
        let geminiAPIKey = try XCTUnwrap(environment["GEMINI_API_KEY"])
        let configurations = try Self.selectedConfigurations(
            environment["LIVE_ASSISTANT_MATRIX_CONFIGS"]
        )
        let benchmarkCases = try Self.selectedCases(
            environment["LIVE_ASSISTANT_MATRIX_CASES"]
        )
        let repetitions = max(
            1,
            Int(environment["LIVE_ASSISTANT_MATRIX_REPETITIONS"] ?? "1") ?? 1
        )
        let shouldWarmUp = environment["LIVE_ASSISTANT_MATRIX_WARMUP"] != "0"
        let judge = AnswerMirrorQualityJudge(
            apiKey: openAIAPIKey,
            model: environment["ANSWER_MIRROR_EVAL_JUDGE_MODEL"]
                ?? "gpt-5.6-sol"
        )

        if shouldWarmUp {
            for configuration in configurations {
                for benchmarkCase in Self.warmUpCases(
                    from: benchmarkCases
                ) {
                    print(
                        "MODEL_MATRIX_WARMUP_START configuration=\(configuration.id) case=\(benchmarkCase.name)"
                    )
                    do {
                        let generation = try await Self.generate(
                            configuration: configuration,
                            benchmarkCase: benchmarkCase,
                            openAIAPIKey: openAIAPIKey,
                            geminiAPIKey: geminiAPIKey,
                            sequence: 0
                        )
                        print(
                            "MODEL_MATRIX_WARMUP_DONE configuration=\(configuration.id) case=\(benchmarkCase.name) latency_ms=\(generation.generationMilliseconds)"
                        )
                    } catch {
                        print(
                            "MODEL_MATRIX_WARMUP_FAILED configuration=\(configuration.id) case=\(benchmarkCase.name) reason=\(Self.singleLine(error.localizedDescription))"
                        )
                    }
                }
            }
        }

        var attempts: [ModelMatrixAttempt] = []
        for repetition in 1...repetitions {
            for (caseIndex, benchmarkCase) in benchmarkCases.enumerated() {
                let orderedConfigurations = Self.rotated(
                    configurations,
                    by: caseIndex + repetition - 1
                )
                for configuration in orderedConfigurations {
                    print(
                        "MODEL_MATRIX_RUN_START configuration=\(configuration.id) case=\(benchmarkCase.name) repetition=\(repetition)"
                    )
                    do {
                        let generation = try await Self.generate(
                            configuration: configuration,
                            benchmarkCase: benchmarkCase,
                            openAIAPIKey: openAIAPIKey,
                            geminiAPIKey: geminiAPIKey,
                            sequence: repetition
                        )
                        let expectationPassed = benchmarkCase.expectation
                            .matches(generation.suggestion)
                        let grounding = generation.suggestion?.grounding.rawValue
                            ?? "none"
                        print(
                            "MODEL_MATRIX_RUN_DONE configuration=\(configuration.id) case=\(benchmarkCase.name) repetition=\(repetition) latency_ms=\(generation.generationMilliseconds) expectation_pass=\(expectationPassed) grounding=\(grounding) input_tokens=\(generation.usage.inputTokens) cached_tokens=\(generation.usage.cachedInputTokens) output_tokens=\(generation.usage.outputTokens) reasoning_tokens=\(generation.usage.reasoningTokens) model_calls=\(generation.usage.requestCount)"
                        )
                        attempts.append(
                            ModelMatrixAttempt(
                                configuration: configuration,
                                benchmarkCase: benchmarkCase,
                                repetition: repetition,
                                generation: generation,
                                expectationPassed: expectationPassed,
                                requestError: nil,
                                assessment: nil,
                                judgeError: nil
                            )
                        )
                    } catch {
                        print(
                            "MODEL_MATRIX_RUN_FAILED configuration=\(configuration.id) case=\(benchmarkCase.name) repetition=\(repetition) reason=\(Self.singleLine(error.localizedDescription))"
                        )
                        attempts.append(
                            ModelMatrixAttempt(
                                configuration: configuration,
                                benchmarkCase: benchmarkCase,
                                repetition: repetition,
                                generation: nil,
                                expectationPassed: false,
                                requestError: error.localizedDescription,
                                assessment: nil,
                                judgeError: nil
                            )
                        )
                    }
                }
            }
        }

        for index in attempts.indices {
            let attempt = attempts[index]
            guard
                case let .suggestion(expectedGrounding) =
                    attempt.benchmarkCase.expectation,
                let suggestion = attempt.generation?.suggestion
            else {
                continue
            }
            print(
                "MODEL_MATRIX_JUDGE_START configuration=\(attempt.configuration.id) case=\(attempt.benchmarkCase.name) repetition=\(attempt.repetition)"
            )
            do {
                let assessment = try await judge.assess(
                    question: attempt.benchmarkCase.question,
                    recentTranscript: attempt.benchmarkCase.recentTranscript,
                    expectedGrounding: expectedGrounding,
                    references: Self.references,
                    suggestion: suggestion
                )
                attempts[index].assessment = assessment
                let cue = Self.singleLine(
                    ([suggestion.preamble].compactMap { $0 }
                        + suggestion.beats.map(\.point))
                        .joined(separator: " / ")
                )
                print(
                    "MODEL_MATRIX_JUDGE_DONE configuration=\(attempt.configuration.id) case=\(attempt.benchmarkCase.name) repetition=\(attempt.repetition) quality=\(String(format: "%.3f", assessment.meanScore)) quality_pass=\(assessment.passesLiveAssistantMatrix) cue=\(cue) rationale=\(Self.singleLine(assessment.rationale))"
                )
            } catch {
                attempts[index].judgeError = error.localizedDescription
                print(
                    "MODEL_MATRIX_JUDGE_FAILED configuration=\(attempt.configuration.id) case=\(attempt.benchmarkCase.name) repetition=\(attempt.repetition) reason=\(Self.singleLine(error.localizedDescription))"
                )
            }
        }

        let summaries = configurations.map {
            Self.summary(for: $0, attempts: attempts)
        }.sorted(by: ModelMatrixSummary.isPreferred)
        XCTAssertFalse(summaries.isEmpty)
        for summary in summaries {
            print("MODEL_MATRIX_SUMMARY \(try Self.encoded(summary))")
        }
    }

    private static func generate(
        configuration: ModelMatrixConfiguration,
        benchmarkCase: ModelMatrixCase,
        openAIAPIKey: String,
        geminiAPIKey: String,
        sequence: Int
    ) async throws -> LiveAssistantGeneration {
        try await configuration.client.generate(
            apiKey: configuration.provider == .gemini
                ? geminiAPIKey
                : openAIAPIKey,
            references: references,
            recentTranscript: benchmarkCase.recentTranscript,
            currentPartial: benchmarkCase.currentPartial,
            otherSpeakerText: benchmarkCase.question,
            sessionContext: sessionContext,
            purpose: .interview,
            basedOnSequence: sequence,
            trigger: benchmarkCase.trigger,
            webSearchMode: .disabled,
            answerMode: benchmarkCase.answerMode
        )
    }

    private static func selectedConfigurations(
        _ value: String?
    ) throws -> [ModelMatrixConfiguration] {
        try selected(
            value,
            from: allConfigurations,
            id: \.id,
            kind: "configuration"
        )
    }

    private static func selectedCases(
        _ value: String?
    ) throws -> [ModelMatrixCase] {
        try selected(
            value,
            from: allCases,
            id: \.name,
            kind: "case"
        )
    }

    private static func selected<Value>(
        _ selection: String?,
        from values: [Value],
        id: KeyPath<Value, String>,
        kind: String
    ) throws -> [Value] {
        guard let selection, !selection.isEmpty else { return values }
        let requested = selection.split(separator: ",").map(String.init)
        var selected: [Value] = []
        for requestedID in requested {
            guard let value = values.first(where: {
                $0[keyPath: id] == requestedID
            }) else {
                throw ModelMatrixError.unknownSelection(kind, requestedID)
            }
            selected.append(value)
        }
        return selected
    }

    private static func warmUpCases(
        from cases: [ModelMatrixCase]
    ) -> [ModelMatrixCase] {
        var answerModes: Set<AssistantAnswerMode> = []
        return cases.filter { answerModes.insert($0.answerMode).inserted }
    }

    private static func rotated<Value>(
        _ values: [Value],
        by rawOffset: Int
    ) -> [Value] {
        guard !values.isEmpty else { return [] }
        let offset = rawOffset % values.count
        return values.indices.map { values[(offset + $0) % values.count] }
    }

    private static func summary(
        for configuration: ModelMatrixConfiguration,
        attempts: [ModelMatrixAttempt]
    ) -> ModelMatrixSummary {
        let matching = attempts.filter { $0.configuration.id == configuration.id }
        let successful = matching.compactMap(\.generation)
        let suggestionAttempts = matching.filter {
            $0.benchmarkCase.expectation.requiresSuggestion
        }
        let assessments = suggestionAttempts.compactMap(\.assessment)
        let latencies = successful.map(\.generationMilliseconds).sorted()
        let qualityPassCount = assessments.filter(
            \.passesLiveAssistantMatrix
        ).count
        let acceptableCount = matching.filter { attempt in
            guard attempt.expectationPassed else { return false }
            if attempt.benchmarkCase.expectation.requiresSuggestion {
                return attempt.assessment?.passesLiveAssistantMatrix == true
            }
            return true
        }.count
        let groundingRepairCount = successful.filter {
            $0.usage.groundingRepairAttempts > 0
        }.count
        return ModelMatrixSummary(
            configuration: configuration.id,
            provider: configuration.provider.rawValue,
            model: configuration.model,
            reasoningEffort: configuration.reasoningEffort.rawValue,
            requestedServiceTier: configuration.serviceTier,
            attemptCount: matching.count,
            requestSuccessRate: rate(successful.count, matching.count),
            expectationPassRate: rate(
                matching.filter(\.expectationPassed).count,
                matching.count
            ),
            qualityMean: mean(assessments.map(\.meanScore)),
            qualityPassRate: rate(
                qualityPassCount,
                suggestionAttempts.count
            ),
            acceptableRate: rate(acceptableCount, matching.count),
            underSixSecondRate: rate(
                successful.filter {
                    $0.generationMilliseconds
                        < LiveAssistantUsefulnessPolicy
                            .maximumInterviewLatencyMilliseconds
                }.count,
                matching.count
            ),
            meanGenerationMilliseconds: mean(
                latencies.map(Double.init)
            ),
            medianGenerationMilliseconds: percentile(
                latencies,
                percentile: 0.5
            ),
            p95GenerationMilliseconds: percentile(
                latencies,
                percentile: 0.95
            ),
            maximumGenerationMilliseconds: latencies.last ?? 0,
            meanInputTokens: mean(
                successful.map { Double($0.usage.inputTokens) }
            ),
            meanCachedInputTokens: mean(
                successful.map { Double($0.usage.cachedInputTokens) }
            ),
            meanOutputTokens: mean(
                successful.map { Double($0.usage.outputTokens) }
            ),
            meanReasoningTokens: mean(
                successful.map { Double($0.usage.reasoningTokens) }
            ),
            meanModelCalls: mean(
                successful.map { Double($0.usage.requestCount) }
            ),
            groundingRepairRate: rate(
                groundingRepairCount,
                matching.count
            )
        )
    }

    private static func rate(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(
        _ sortedValues: [Int],
        percentile: Double
    ) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let position = percentile * Double(sortedValues.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return Double(sortedValues[lower]) }
        let fraction = position - Double(lower)
        return Double(sortedValues[lower]) * (1 - fraction)
            + Double(sortedValues[upper]) * fraction
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static let sessionContext = """
    Senior rendering and performance-engineering interview. Give the candidate a concise cue they can say aloud immediately.
    """

    private static let references: ReferenceLibrarySnapshot = {
        let documents = [
            referenceDocument(
                path: "Portfolio/Renderer.md",
                content: "I built a DirectX 12 renderer with a scene graph and physically based materials. This overview does not document a CPU-versus-GPU profiling procedure, a debugging incident, or an optimization result."
            ),
            referenceDocument(
                path: "Projects/Checkout.md",
                content: "In 2024, checkout p95 reached 1.8 seconds because each line item repeated an inventory lookup. I used distributed traces to isolate the N+1 query, batched the lookup, and replayed recorded traffic in a load test. Checkout p95 fell to 1.05 seconds, and I added a latency alert for the path."
            )
        ]
        return ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/live-assistant-model-matrix"),
            documents: documents,
            revision: "cross-provider-synthetic-v1",
            indexedAt: Date(timeIntervalSince1970: 1_700_000_000),
            ignoredFileCount: 0,
            issues: []
        )
    }()

    private static func referenceDocument(
        path: String,
        content: String
    ) -> ReferenceDocument {
        ReferenceDocument(
            relativePath: path,
            kind: .markdown,
            content: content,
            sourceByteCount: content.utf8.count,
            isTruncated: false
        )
    }

    private static let allCases: [ModelMatrixCase] = [
        ModelMatrixCase(
            name: "checkout-grounded",
            recentTranscript: "",
            currentPartial: "",
            question: "Tell me about a time you improved the performance of a critical system.",
            answerMode: .grounded,
            trigger: .finalizedTurn,
            expectation: .suggestion(.localReferences)
        ),
        ModelMatrixCase(
            name: "renderer-diagnosis-grounded",
            recentTranscript: "",
            currentPartial: "",
            question: "Imagine a real-time renderer where frame time spikes in complex scenes. What first measurement would distinguish a CPU bottleneck from a GPU bottleneck, and what would you test next?",
            answerMode: .grounded,
            trigger: .finalizedTurn,
            expectation: .suggestion(.generalKnowledge)
        ),
        ModelMatrixCase(
            name: "renderer-plausible",
            recentTranscript: "",
            currentPartial: "",
            question: "Tell me about a rendering optimization you made. What changed, and how did you know it helped?",
            answerMode: .plausibleRehearsal,
            trigger: .finalizedTurn,
            expectation: .suggestion(.localReferences)
        ),
        ModelMatrixCase(
            name: "renderer-follow-up-plausible",
            recentTranscript: """
            Interviewer: Tell me about a rendering optimization you made.
            Candidate: In my DirectX 12 renderer the frame kept jumping when the scene got busy. I found the visible-object list was rebuilding the whole thing each time. I changed it so only dirty regions were updated, then ran the same camera path and the spikes went away.
            """,
            currentPartial: "",
            question: "How did you profile or verify that you were addressing the right bottleneck?",
            answerMode: .plausibleRehearsal,
            trigger: .finalizedTurn,
            expectation: .suggestion(.localReferences)
        ),
        ModelMatrixCase(
            name: "unfinished-fragment",
            recentTranscript: "",
            currentPartial: "Interviewer: And then, if the renderer maybe…",
            question: "And then, if the renderer maybe…",
            answerMode: .grounded,
            trigger: .partialTranscript,
            expectation: .noSuggestion
        )
    ]

    private static let allConfigurations: [ModelMatrixConfiguration] = [
        ModelMatrixConfiguration(
            id: "luna-none-priority",
            provider: .openAI,
            model: "gpt-5.6-luna",
            reasoningEffort: .none,
            serviceTier: "priority"
        ),
        ModelMatrixConfiguration(
            id: "luna-low-priority",
            provider: .openAI,
            model: "gpt-5.6-luna",
            reasoningEffort: .low,
            serviceTier: "priority"
        ),
        ModelMatrixConfiguration(
            id: "luna-medium-priority",
            provider: .openAI,
            model: "gpt-5.6-luna",
            reasoningEffort: .medium,
            serviceTier: "priority"
        ),
        ModelMatrixConfiguration(
            id: "luna-low-standard",
            provider: .openAI,
            model: "gpt-5.6-luna",
            reasoningEffort: .low,
            serviceTier: nil
        ),
        ModelMatrixConfiguration(
            id: "gemini-low",
            provider: .gemini,
            model: "gemini-3.7-flash",
            reasoningEffort: .low,
            serviceTier: nil
        ),
        ModelMatrixConfiguration(
            id: "gemini-medium",
            provider: .gemini,
            model: "gemini-3.7-flash",
            reasoningEffort: .medium,
            serviceTier: nil
        ),
        ModelMatrixConfiguration(
            id: "gemini-high",
            provider: .gemini,
            model: "gemini-3.7-flash",
            reasoningEffort: .high,
            serviceTier: nil
        ),
        ModelMatrixConfiguration(
            id: "terra-medium-priority",
            provider: .openAI,
            model: "gpt-5.6-terra",
            reasoningEffort: .medium,
            serviceTier: "priority"
        )
    ]
}

private enum ModelMatrixProvider: String {
    case openAI
    case gemini
}

private struct ModelMatrixConfiguration: Equatable {
    let id: String
    let provider: ModelMatrixProvider
    let model: String
    let reasoningEffort: LiveAssistantReasoningEffort
    let serviceTier: String?

    var client: LiveAssistantClient {
        let configuration = LiveAssistantConfiguration(
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            maximumOutputTokens: 4_096
        )
        switch provider {
        case .openAI:
            return LiveAssistantClient(configuration: configuration)
        case .gemini:
            return LiveAssistantClient.gemini(configuration: configuration)
        }
    }
}

private struct ModelMatrixCase {
    let name: String
    let recentTranscript: String
    let currentPartial: String
    let question: String
    let answerMode: AssistantAnswerMode
    let trigger: CompanionAssistantTrigger
    let expectation: ModelMatrixExpectation
}

private enum ModelMatrixExpectation {
    case suggestion(CompanionSuggestionGrounding)
    case noSuggestion

    var requiresSuggestion: Bool {
        if case .suggestion = self { return true }
        return false
    }

    func matches(_ suggestion: CompanionAssistantSuggestion?) -> Bool {
        switch self {
        case let .suggestion(grounding):
            suggestion?.grounding == grounding
        case .noSuggestion:
            suggestion == nil
        }
    }
}

private struct ModelMatrixAttempt {
    let configuration: ModelMatrixConfiguration
    let benchmarkCase: ModelMatrixCase
    let repetition: Int
    let generation: LiveAssistantGeneration?
    let expectationPassed: Bool
    let requestError: String?
    var assessment: AnswerMirrorQualityAssessment?
    var judgeError: String?
}

private struct ModelMatrixSummary: Encodable {
    let configuration: String
    let provider: String
    let model: String
    let reasoningEffort: String
    let requestedServiceTier: String?
    let attemptCount: Int
    let requestSuccessRate: Double
    let expectationPassRate: Double
    let qualityMean: Double
    let qualityPassRate: Double
    let acceptableRate: Double
    let underSixSecondRate: Double
    let meanGenerationMilliseconds: Double
    let medianGenerationMilliseconds: Double
    let p95GenerationMilliseconds: Double
    let maximumGenerationMilliseconds: Int
    let meanInputTokens: Double
    let meanCachedInputTokens: Double
    let meanOutputTokens: Double
    let meanReasoningTokens: Double
    let meanModelCalls: Double
    let groundingRepairRate: Double

    static func isPreferred(
        _ lhs: ModelMatrixSummary,
        _ rhs: ModelMatrixSummary
    ) -> Bool {
        if lhs.acceptableRate != rhs.acceptableRate {
            return lhs.acceptableRate > rhs.acceptableRate
        }
        if lhs.qualityMean != rhs.qualityMean {
            return lhs.qualityMean > rhs.qualityMean
        }
        return lhs.medianGenerationMilliseconds
            < rhs.medianGenerationMilliseconds
    }
}

private extension AnswerMirrorQualityAssessment {
    var passesLiveAssistantMatrix: Bool {
        [
            directness,
            spokenNaturalness,
            plainSpokenLanguage,
            specificity,
            anchorRelevance,
            temporalJudgment,
            causalUsefulness,
            mechanisticDepth,
            verificationRigor,
            groundingSafety,
            plausibilitySafety,
            answerModeUsefulness,
            conciseUsability
        ].allSatisfy { $0 >= 4 }
    }
}

private enum ModelMatrixError: LocalizedError {
    case unknownSelection(String, String)

    var errorDescription: String? {
        switch self {
        case let .unknownSelection(kind, value):
            "Unknown model-matrix \(kind): \(value)"
        }
    }
}

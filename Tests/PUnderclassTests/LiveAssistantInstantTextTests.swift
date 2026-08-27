import Foundation
import XCTest
@testable import PUnderclass

final class LiveAssistantInstantTextTests: XCTestCase {
    func testHostedInstantTextVersusVerifiedCue() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_ASSISTANT_INSTANT_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set RUN_LIVE_ASSISTANT_INSTANT_SMOKE=1 to run the hosted instant-text comparison."
            )
        }
        let apiKey = try XCTUnwrap(environment["OPENAI_API_KEY"])
        let client = LiveAssistantClient()
        let references = Self.references()
        let question = "Tell me about a time you reduced CPU rendering overhead, and how you verified the change."
        let recorder = InstantTextRecorder()

        let instant = try await client.generate(
            apiKey: apiKey,
            references: references,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: question,
            sessionContext: "A rendering-engineer interview.",
            purpose: .interview,
            basedOnSequence: 1,
            trigger: .finalizedTurn,
            webSearchMode: .disabled,
            answerMode: .grounded,
            deliveryMode: .instantText,
            onInstantText: { update in
                await recorder.record(update)
            }
        )
        let recordedFirstUpdate = await recorder.first()
        let firstUpdate = try XCTUnwrap(recordedFirstUpdate)
        let instantSuggestion = try XCTUnwrap(instant.suggestion)
        XCTAssertEqual(instant.deliveryMode, .instantText)
        XCTAssertEqual(instantSuggestion.deliveryMode, .instantText)
        XCTAssertFalse(firstUpdate.text.isEmpty)
        XCTAssertEqual(
            firstUpdate.firstRenderableTextMilliseconds,
            instant.latencyMilestones.firstRenderableTextMilliseconds
        )

        let verified = try await client.generate(
            apiKey: apiKey,
            references: references,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: question,
            sessionContext: "A rendering-engineer interview.",
            purpose: .interview,
            basedOnSequence: 2,
            trigger: .finalizedTurn,
            webSearchMode: .disabled,
            answerMode: .grounded,
            deliveryMode: .verified
        )
        let verifiedSuggestion = try XCTUnwrap(verified.suggestion)
        XCTAssertEqual(verified.deliveryMode, .verified)
        XCTAssertEqual(verifiedSuggestion.grounding, .localReferences)

        print(
            "INSTANT_TEXT_COMPARISON instant_first_renderable_ms=\(instant.latencyMilestones.firstRenderableTextMilliseconds ?? -1) instant_complete_ms=\(instant.generationMilliseconds) verified_first_delta_ms=\(verified.latencyMilestones.firstTextDeltaMilliseconds ?? -1) verified_complete_ms=\(verified.generationMilliseconds)"
        )
        print(
            "INSTANT_TEXT_CUE \(instantSuggestion.preamble ?? "")"
        )
        print(
            "VERIFIED_CUE \(Self.spokenText(verifiedSuggestion))"
        )
    }

    func testHostedSpeechStopToFirstDisplayTimeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_ASSISTANT_TIMELINE_BENCHMARK"] == "1" else {
            throw XCTSkip(
                "Set RUN_LIVE_ASSISTANT_TIMELINE_BENCHMARK=1 to run the speech-stop timeline benchmark."
            )
        }
        let apiKey = try XCTUnwrap(environment["OPENAI_API_KEY"])
        let requestedRepetitions = Int(
            environment["LIVE_ASSISTANT_TIMELINE_REPETITIONS"] ?? ""
        ) ?? 2
        let repetitions = min(10, max(1, requestedRepetitions))
        let client = LiveAssistantClient()
        let references = Self.references()
        let completeQuestion = "Tell me about a time you reduced CPU rendering overhead, and how you verified the change."
        let allScenarios = [
            SpeechStopBenchmarkScenario(
                name: "stable_identity",
                partialText: completeQuestion,
                finalText: completeQuestion
            ),
            SpeechStopBenchmarkScenario(
                name: "punctuation_update",
                partialText: String(completeQuestion.dropLast()),
                finalText: completeQuestion
            ),
            SpeechStopBenchmarkScenario(
                name: "unfinished_update",
                partialText: "Tell me about a time you reduced CPU rendering overhead, and how",
                finalText: completeQuestion
            )
        ]
        let requestedScenario = environment[
            "LIVE_ASSISTANT_TIMELINE_SCENARIO"
        ]
        let scenarios = requestedScenario.map { requested in
            allScenarios.filter { $0.name == requested }
        } ?? allScenarios
        if let requestedScenario {
            XCTAssertFalse(
                scenarios.isEmpty,
                "Unknown timeline scenario: \(requestedScenario)"
            )
        }
        var results: [SpeechStopBenchmarkResult] = []

        for repetition in 0..<repetitions {
            for (scenarioIndex, scenario) in scenarios.enumerated() {
                let modes: [LiveAssistantDeliveryMode] =
                    (repetition + scenarioIndex).isMultiple(of: 2)
                    ? [.verified, .instantText]
                    : [.instantText, .verified]
                for mode in modes {
                    let result = try await Self.runSpeechStopTimeline(
                        apiKey: apiKey,
                        client: client,
                        references: references,
                        scenario: scenario,
                        repetition: repetition + 1,
                        requestedDeliveryMode: mode,
                        basedOnSequence: results.count + 1
                    )
                    results.append(result)
                    Self.printTimelineResult(result)
                }
            }
        }

        Self.printTimelineSummary(results)
        for mode in LiveAssistantDeliveryMode.allCases {
            XCTAssertTrue(
                results.contains {
                    $0.requestedDeliveryMode == mode
                        && $0.firstUsableDisplay != nil
                },
                "Expected at least one visible cue for \(mode.rawValue)."
            )
        }
    }

    private static func references() -> ReferenceLibrarySnapshot {
        let resume = """
        Davide built a Metal renderer at Example Studio. To reduce CPU submission overhead, he batched draw calls by material and used indirect command buffers. On a fixed replay, CPU frame submission fell from 7 ms to 3 ms with matching rendered output.
        """
        return ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/instant-text-smoke"),
            documents: [
                ReferenceDocument(
                    relativePath: "resume.md",
                    kind: .markdown,
                    content: resume,
                    sourceByteCount: resume.utf8.count,
                    isTruncated: false
                )
            ],
            revision: "instant-text-smoke",
            indexedAt: Date(),
            ignoredFileCount: 0,
            issues: []
        )
    }

    private static func spokenText(
        _ suggestion: CompanionAssistantSuggestion
    ) -> String {
        ([suggestion.preamble] + suggestion.beats.map(\.point))
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func runSpeechStopTimeline(
        apiKey: String,
        client: LiveAssistantClient,
        references: ReferenceLibrarySnapshot,
        scenario: SpeechStopBenchmarkScenario,
        repetition: Int,
        requestedDeliveryMode: LiveAssistantDeliveryMode,
        basedOnSequence: Int
    ) async throws -> SpeechStopBenchmarkResult {
        let clock = ContinuousClock()
        let speechStoppedAt = clock.now
        let usefulnessDeadline = speechStoppedAt + .milliseconds(
            LiveAssistantUsefulnessPolicy.maximumInterviewLatencyMilliseconds
        )
        let recorder = SpeechStopDisplayRecorder()

        try await clock.sleep(
            until: speechStoppedAt + .milliseconds(
                AssistantEvaluationPolicy.partialSpeechPauseMilliseconds
            )
        )
        let partialTask = Task {
            await Self.runTimelineAttempt(
                apiKey: apiKey,
                client: client,
                references: references,
                text: scenario.partialText,
                currentPartial: "Other: \(scenario.partialText)",
                trigger: .partialTranscript,
                requestedDeliveryMode: requestedDeliveryMode,
                basedOnSequence: basedOnSequence,
                speechStoppedAt: speechStoppedAt,
                usefulnessDeadline: usefulnessDeadline,
                recorder: recorder
            )
        }

        try await clock.sleep(
            until: speechStoppedAt + .milliseconds(3_000)
        )
        let hasUsablePartial = await recorder.firstUsable() != nil
        let hasIdenticalIdentity = normalizedIdentityText(scenario.partialText)
            == normalizedIdentityText(scenario.finalText)
        let startsFinalizedTurnHedge = requestedDeliveryMode == .instantText
            && !hasUsablePartial
        let finalAttempt: SpeechStopBenchmarkAttempt?
        if hasUsablePartial
            || (hasIdenticalIdentity && !startsFinalizedTurnHedge)
        {
            finalAttempt = nil
        } else {
            if !startsFinalizedTurnHedge {
                partialTask.cancel()
            }
            finalAttempt = await Self.runTimelineAttempt(
                apiKey: apiKey,
                client: client,
                references: references,
                text: scenario.finalText,
                currentPartial: "",
                trigger: .finalizedTurn,
                requestedDeliveryMode: requestedDeliveryMode,
                basedOnSequence: basedOnSequence + 10_000,
                speechStoppedAt: speechStoppedAt,
                usefulnessDeadline: usefulnessDeadline,
                recorder: recorder
            )
        }

        let partialAttempt = await partialTask.value
        return SpeechStopBenchmarkResult(
            scenario: scenario.name,
            repetition: repetition,
            requestedDeliveryMode: requestedDeliveryMode,
            coalescedFinal: finalAttempt == nil,
            hedgedFinal: startsFinalizedTurnHedge,
            partialAttempt: partialAttempt,
            finalAttempt: finalAttempt,
            firstDisplay: await recorder.first(),
            firstUsableDisplay: await recorder.firstUsable()
        )
    }

    private static func runTimelineAttempt(
        apiKey: String,
        client: LiveAssistantClient,
        references: ReferenceLibrarySnapshot,
        text: String,
        currentPartial: String,
        trigger: CompanionAssistantTrigger,
        requestedDeliveryMode: LiveAssistantDeliveryMode,
        basedOnSequence: Int,
        speechStoppedAt: ContinuousClock.Instant,
        usefulnessDeadline: ContinuousClock.Instant,
        recorder: SpeechStopDisplayRecorder
    ) async -> SpeechStopBenchmarkAttempt {
        let requestStartedAt = ContinuousClock.now
        let requestStartedMilliseconds = LiveAssistantTransportClock
            .elapsedMilliseconds(since: speechStoppedAt)
        do {
            let generation = try await client.generate(
                apiKey: apiKey,
                references: references,
                recentTranscript: "",
                currentPartial: currentPartial,
                otherSpeakerText: text,
                sessionContext: "A rendering-engineer interview.",
                purpose: .interview,
                basedOnSequence: basedOnSequence,
                trigger: trigger,
                webSearchMode: .disabled,
                answerMode: .grounded,
                usefulnessDeadline: usefulnessDeadline,
                deliveryMode: requestedDeliveryMode,
                onInstantText: { update in
                    guard !Task.isCancelled else { return }
                    await recorder.record(
                        SpeechStopDisplay(
                            elapsedMilliseconds: LiveAssistantTransportClock
                                .elapsedMilliseconds(
                                    since: speechStoppedAt
                                ),
                            source: "\(trigger.rawValue)_instant_draft",
                            text: update.text
                        )
                    )
                }
            )
            guard !Task.isCancelled else {
                return SpeechStopBenchmarkAttempt.cancelled(
                    trigger: trigger,
                    requestStartedMilliseconds: requestStartedMilliseconds,
                    requestStartedAt: requestStartedAt
                )
            }
            let suggestionText = generation.suggestion.map(spokenText)
            if let suggestionText {
                await recorder.record(
                    SpeechStopDisplay(
                        elapsedMilliseconds: LiveAssistantTransportClock
                            .elapsedMilliseconds(since: speechStoppedAt),
                        source: "\(trigger.rawValue)_\(generation.deliveryMode.rawValue)_complete",
                        text: suggestionText
                    )
                )
            }
            return SpeechStopBenchmarkAttempt(
                trigger: trigger,
                state: generation.suggestion == nil ? .skipped : .shown,
                resolvedDeliveryMode: generation.deliveryMode,
                requestStartedMilliseconds: requestStartedMilliseconds,
                requestMilliseconds: LiveAssistantTransportClock
                    .elapsedMilliseconds(since: requestStartedAt),
                firstRenderableRequestMilliseconds:
                    generation.latencyMilestones
                        .firstRenderableTextMilliseconds,
                outcome: generation.outcome.rawValue,
                suggestionText: suggestionText,
                error: nil
            )
        } catch {
            let liveError = (error as? LiveAssistantFailure)?.cause
                ?? error as? LiveAssistantError
            let state: SpeechStopBenchmarkAttemptState
            if Task.isCancelled || error is CancellationError {
                state = .cancelled
            } else if liveError == .usefulnessDeadlineExceeded {
                state = .timedOut
            } else {
                state = .failed
            }
            return SpeechStopBenchmarkAttempt(
                trigger: trigger,
                state: state,
                resolvedDeliveryMode: nil,
                requestStartedMilliseconds: requestStartedMilliseconds,
                requestMilliseconds: LiveAssistantTransportClock
                    .elapsedMilliseconds(since: requestStartedAt),
                firstRenderableRequestMilliseconds: nil,
                outcome: nil,
                suggestionText: nil,
                error: error.localizedDescription
            )
        }
    }

    private static func normalizedIdentityText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func printTimelineResult(
        _ result: SpeechStopBenchmarkResult
    ) {
        let partial = result.partialAttempt
        let final = result.finalAttempt
        let first = result.firstDisplay
        let firstUsable = result.firstUsableDisplay
        let fields = [
            "SPEECH_STOP_TIMELINE",
            "scenario=\(result.scenario)",
            "repetition=\(result.repetition)",
            "requested=\(result.requestedDeliveryMode.rawValue)",
            "coalesced_final=\(result.coalescedFinal)",
            "hedged_final=\(result.hedgedFinal)",
            "first_render_ms=\(first?.elapsedMilliseconds ?? -1)",
            "first_usable_ms=\(firstUsable?.elapsedMilliseconds ?? -1)",
            "usable_source=\(firstUsable?.source ?? "none")",
            "partial_state=\(partial.state.rawValue)",
            "partial_request_ms=\(partial.requestMilliseconds)",
            "partial_delivery=\(partial.resolvedDeliveryMode?.rawValue ?? "none")",
            "final_state=\(final?.state.rawValue ?? "coalesced")",
            "final_request_ms=\(final?.requestMilliseconds ?? -1)",
            "final_first_renderable_request_ms=\(final?.firstRenderableRequestMilliseconds ?? -1)",
            "final_delivery=\(final?.resolvedDeliveryMode?.rawValue ?? "none")"
        ]
        print(fields.joined(separator: " "))
        if let text = firstUsable?.text {
            print(
                "SPEECH_STOP_FIRST_CUE scenario=\(result.scenario) repetition=\(result.repetition) requested=\(result.requestedDeliveryMode.rawValue) text=\(singleLine(text))"
            )
        }
    }

    private static func printTimelineSummary(
        _ results: [SpeechStopBenchmarkResult]
    ) {
        for scenario in Set(results.map(\.scenario)).sorted() {
            for mode in LiveAssistantDeliveryMode.allCases {
                let matching = results
                    .filter {
                        $0.scenario == scenario
                            && $0.requestedDeliveryMode == mode
                    }
                let values = matching
                    .compactMap {
                        $0.firstUsableDisplay?.elapsedMilliseconds
                    }
                    .sorted()
                let samples = values.map(String.init).joined(separator: ",")
                let fields = [
                    "SPEECH_STOP_CASE_SUMMARY",
                    "scenario=\(scenario)",
                    "requested=\(mode.rawValue)",
                    "usable=\(values.count)/\(matching.count)",
                    "partial_wins=\(matching.filter { $0.firstUsableDisplay?.source.hasPrefix("partialTranscript") == true }.count)",
                    "final_wins=\(matching.filter { $0.firstUsableDisplay?.source.hasPrefix("finalizedTurn") == true }.count)",
                    "samples_ms=\(samples)",
                    "mean_ms=\(mean(values))",
                    "median_ms=\(median(values))"
                ]
                print(fields.joined(separator: " "))
            }
        }

        let pairs = Dictionary(grouping: results) {
            "\($0.scenario)-\($0.repetition)"
        }
        let savings = pairs.values.compactMap { pair -> Int? in
            guard
                let verified = pair.first(where: {
                    $0.requestedDeliveryMode == .verified
                })?.firstUsableDisplay?.elapsedMilliseconds,
                let instant = pair.first(where: {
                    $0.requestedDeliveryMode == .instantText
                })?.firstUsableDisplay?.elapsedMilliseconds
            else {
                return nil
            }
            return verified - instant
        }.sorted()
        let savingsSamples = savings.map(String.init).joined(separator: ",")
        let fields = [
            "SPEECH_STOP_PAIRED_SUMMARY",
            "pairs=\(savings.count)",
            "instant_wins=\(savings.filter { $0 > 0 }.count)",
            "ties=\(savings.filter { $0 == 0 }.count)",
            "verified_wins=\(savings.filter { $0 < 0 }.count)",
            "mean_instant_savings_ms=\(mean(savings))",
            "median_instant_savings_ms=\(median(savings))",
            "samples_ms=\(savingsSamples)"
        ]
        print(fields.joined(separator: " "))
    }

    private static func mean(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return -1 }
        return Int(
            (Double(values.reduce(0, +)) / Double(values.count)).rounded()
        )
    }

    private static func median(_ sortedValues: [Int]) -> Int {
        guard !sortedValues.isEmpty else { return -1 }
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return Int(
                (Double(sortedValues[middle - 1] + sortedValues[middle]) / 2)
                    .rounded()
            )
        }
        return sortedValues[middle]
    }

    private static func singleLine(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private actor InstantTextRecorder {
    private var updates: [LiveAssistantInstantTextUpdate] = []

    func record(_ update: LiveAssistantInstantTextUpdate) {
        updates.append(update)
    }

    func first() -> LiveAssistantInstantTextUpdate? {
        updates.first
    }
}

private struct SpeechStopBenchmarkScenario: Sendable {
    let name: String
    let partialText: String
    let finalText: String
}

private struct SpeechStopBenchmarkResult: Sendable {
    let scenario: String
    let repetition: Int
    let requestedDeliveryMode: LiveAssistantDeliveryMode
    let coalescedFinal: Bool
    let hedgedFinal: Bool
    let partialAttempt: SpeechStopBenchmarkAttempt
    let finalAttempt: SpeechStopBenchmarkAttempt?
    let firstDisplay: SpeechStopDisplay?
    let firstUsableDisplay: SpeechStopDisplay?
}

private enum SpeechStopBenchmarkAttemptState: String, Sendable {
    case shown
    case skipped
    case cancelled
    case timedOut = "timed_out"
    case failed
}

private struct SpeechStopBenchmarkAttempt: Sendable {
    let trigger: CompanionAssistantTrigger
    let state: SpeechStopBenchmarkAttemptState
    let resolvedDeliveryMode: LiveAssistantDeliveryMode?
    let requestStartedMilliseconds: Int
    let requestMilliseconds: Int
    let firstRenderableRequestMilliseconds: Int?
    let outcome: String?
    let suggestionText: String?
    let error: String?

    static func cancelled(
        trigger: CompanionAssistantTrigger,
        requestStartedMilliseconds: Int,
        requestStartedAt: ContinuousClock.Instant
    ) -> SpeechStopBenchmarkAttempt {
        SpeechStopBenchmarkAttempt(
            trigger: trigger,
            state: .cancelled,
            resolvedDeliveryMode: nil,
            requestStartedMilliseconds: requestStartedMilliseconds,
            requestMilliseconds: LiveAssistantTransportClock
                .elapsedMilliseconds(since: requestStartedAt),
            firstRenderableRequestMilliseconds: nil,
            outcome: nil,
            suggestionText: nil,
            error: nil
        )
    }
}

private struct SpeechStopDisplay: Sendable {
    let elapsedMilliseconds: Int
    let source: String
    let text: String
}

private actor SpeechStopDisplayRecorder {
    // The companion renders the first update immediately. Eight words is the
    // shortest phrase that is plausibly readable aloud, rather than a lone
    // streaming token.
    private static let minimumUsableWordCount = 8
    private var firstDisplay: SpeechStopDisplay?
    private var firstUsableDisplay: SpeechStopDisplay?

    func record(_ display: SpeechStopDisplay) {
        if firstDisplay == nil {
            firstDisplay = display
        }
        if
            firstUsableDisplay == nil,
            display.text.split(whereSeparator: \Character.isWhitespace).count
                >= Self.minimumUsableWordCount
        {
            firstUsableDisplay = display
        }
    }

    func first() -> SpeechStopDisplay? {
        firstDisplay
    }

    func firstUsable() -> SpeechStopDisplay? {
        firstUsableDisplay
    }
}

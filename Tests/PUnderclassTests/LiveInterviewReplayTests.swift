import Foundation
import XCTest
@testable import PUnderclass

final class LiveInterviewReplayTests: XCTestCase {
    func testReplayCurrentCompanionInterviewWithProductionAssistant() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_INTERVIEW_REPLAY"] == "1" else {
            throw XCTSkip(
                "Set RUN_LIVE_INTERVIEW_REPLAY=1 to replay a private interview."
            )
        }
        let apiKey = try XCTUnwrap(environment["OPENAI_API_KEY"])
        let outputPath = try XCTUnwrap(
            environment["LIVE_INTERVIEW_REPLAY_OUTPUT"],
            "Set LIVE_INTERVIEW_REPLAY_OUTPUT to a private path outside the repository."
        )
        let snapshotURL = try XCTUnwrap(
            URL(
                string: environment["LIVE_INTERVIEW_REPLAY_SNAPSHOT_URL"]
                    ?? "http://127.0.0.1:4173/v1/snapshot"
            )
        )
        let snapshot = try await Self.snapshot(from: snapshotURL)
        XCTAssertEqual(snapshot.session.purpose, .interview)

        let productionConfiguration = LiveAssistantConfiguration.production
        let reasoningEffort: LiveAssistantReasoningEffort
        if let requestedEffort = environment[
            "LIVE_INTERVIEW_REPLAY_REASONING_EFFORT"
        ] {
            reasoningEffort = try XCTUnwrap(
                LiveAssistantReasoningEffort(rawValue: requestedEffort),
                "Unsupported LIVE_INTERVIEW_REPLAY_REASONING_EFFORT."
            )
        } else {
            reasoningEffort = productionConfiguration.reasoningEffort
        }
        let assistantConfiguration = LiveAssistantConfiguration(
            model: productionConfiguration.model,
            reasoningEffort: reasoningEffort,
            serviceTier: productionConfiguration.serviceTier,
            additionalBehaviorInstructions:
                productionConfiguration.additionalBehaviorInstructions,
            maximumOutputTokens: productionConfiguration.maximumOutputTokens
        )

        let preparationArchive = try ReferencePreparationStore
            .applicationSupport()
            .load()
        let preparedPack = preparationArchive.pack
        let sessionContext = preparationArchive.interviewContext?.text
            ?? preparedPack?.sessionContext
            ?? InterviewContextDraft.basicDescription
        let turns = snapshot.transcript.turns.sorted {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt < $1.startedAt
        }
        let allInterviewerIndices = turns.indices.filter {
            turns[$0].speaker.lowercased() == "other"
        }
        let turnLimit = environment["LIVE_INTERVIEW_REPLAY_TURN_LIMIT"]
            .flatMap(Int.init)
            .map { max(1, $0) }
        let interviewerIndices = turnLimit.map {
            Array(allInterviewerIndices.prefix($0))
        } ?? allInterviewerIndices
        XCTAssertFalse(interviewerIndices.isEmpty)

        let assistantClient = LiveAssistantClient(
            configuration: assistantConfiguration
        )
        let bridgeClient = EarlyInterviewBridgeClient()
        var recentBridgeTexts: [String] = []
        var latestStory: AssistantRehearsalStoryContext?
        var results: [LiveInterviewReplayTurnResult] = []
        let replayStartedAt = Date()

        for (replayIndex, transcriptIndex) in interviewerIndices.enumerated() {
            let turn = turns[transcriptIndex]
            let recentTurns = turns[..<transcriptIndex].suffix(16)
            let recentTranscript = recentTurns.map {
                "\(Self.promptSpeaker($0.speaker)): \($0.text)"
            }.joined(separator: "\n")
            let references = preparedPack?.snapshot(
                for: turn.text,
                folderURL: nil
            )
            let bridgeHistory = recentBridgeTexts
            let story = latestStory
            let turnStartedAt = Date()

            let bridgeTask = Task {
                await Self.bridgeAttempt {
                    try await bridgeClient.generate(
                        apiKey: apiKey,
                        currentPartial: turn.text,
                        recentTranscript: recentTranscript,
                        recentBridges: bridgeHistory,
                        sessionContext: sessionContext,
                        opportunity: .finalizedTurn
                    )
                }
            }
            let assistantTask = Task {
                await Self.assistantAttempt {
                    try await assistantClient.generate(
                        apiKey: apiKey,
                        references: references,
                        recentTranscript: recentTranscript,
                        currentPartial: "",
                        otherSpeakerText: turn.text,
                        sessionContext: sessionContext,
                        purpose: .interview,
                        basedOnSequence: replayIndex + 1,
                        trigger: .finalizedTurn,
                        webSearchMode: .automatic,
                        answerMode: .plausibleRehearsal,
                        previousRehearsalStory: story
                    )
                }
            }

            let bridgeAttempt = await bridgeTask.value
            let assistantAttempt = await assistantTask.value
            if let bridge = bridgeAttempt.generation?.bridge {
                recentBridgeTexts.append(bridge)
                recentBridgeTexts = Array(recentBridgeTexts.suffix(4))
            }
            if
                let suggestion = assistantAttempt.generation?.suggestion,
                let story = AssistantRehearsalStoryContext(
                    suggestion: suggestion
                )
            {
                latestStory = story
            }

            let result = LiveInterviewReplayTurnResult(
                replayIndex: replayIndex + 1,
                transcriptTurnID: turn.id,
                question: turn.text,
                bridge: bridgeAttempt.generation?.bridge,
                bridgeGenerationMilliseconds:
                    bridgeAttempt.generation?.generationMilliseconds,
                bridgeError: bridgeAttempt.error,
                suggestion: assistantAttempt.generation?.suggestion,
                assistantOutcome:
                    assistantAttempt.generation?.outcome.rawValue,
                assistantGenerationMilliseconds:
                    assistantAttempt.generation?.generationMilliseconds,
                assistantModelCalls:
                    assistantAttempt.generation?.usage.requestCount,
                assistantUsage: assistantAttempt.generation?.usage,
                assistantError: assistantAttempt.error,
                referenceDocumentCount: references?.documents.count ?? 0,
                wallMilliseconds: Self.milliseconds(
                    from: turnStartedAt,
                    to: Date()
                )
            )
            results.append(result)
            print(
                "LIVE_INTERVIEW_REPLAY progress=\(replayIndex + 1)/\(interviewerIndices.count) "
                    + "bridge_ms=\(result.bridgeGenerationMilliseconds ?? -1) "
                    + "assistant_ms=\(result.assistantGenerationMilliseconds ?? -1) "
                    + "shown=\(result.suggestion != nil)"
            )
        }

        let report = LiveInterviewReplayReport(
            generatedAt: Date(),
            sourceSession: snapshot.session,
            sourceTranscript: turns,
            originalRetainedSuggestions: snapshot.assistant.suggestionHistory,
            model: assistantConfiguration.model,
            reasoningEffort: assistantConfiguration.reasoningEffort.rawValue,
            bridgeModel: EarlyInterviewBridgeClient.model,
            replayWallMilliseconds: Self.milliseconds(
                from: replayStartedAt,
                to: Date()
            ),
            results: results
        )
        let encoder = CompanionJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print(
            "LIVE_INTERVIEW_REPLAY_COMPLETE turns=\(results.count) "
                + "shown=\(results.filter { $0.suggestion != nil }.count) "
                + "output=\(outputURL.path)"
        )
    }

    private static func snapshot(
        from url: URL
    ) async throws -> CompanionSnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw LiveInterviewReplayError.snapshotUnavailable
        }
        return try CompanionJSON.decoder().decode(
            CompanionSnapshot.self,
            from: data
        )
    }

    private static func bridgeAttempt(
        _ operation: () async throws -> EarlyInterviewBridgeGeneration
    ) async -> LiveInterviewReplayBridgeAttempt {
        do {
            return LiveInterviewReplayBridgeAttempt(
                generation: try await operation(),
                error: nil
            )
        } catch {
            return LiveInterviewReplayBridgeAttempt(
                generation: nil,
                error: error.localizedDescription
            )
        }
    }

    private static func assistantAttempt(
        _ operation: () async throws -> LiveAssistantGeneration
    ) async -> LiveInterviewReplayAssistantAttempt {
        do {
            return LiveInterviewReplayAssistantAttempt(
                generation: try await operation(),
                error: nil
            )
        } catch {
            return LiveInterviewReplayAssistantAttempt(
                generation: nil,
                error: error.localizedDescription
            )
        }
    }

    private static func promptSpeaker(_ value: String) -> String {
        value.lowercased() == "you" ? "You" : "Other"
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }
}

private struct LiveInterviewReplayBridgeAttempt: Sendable {
    let generation: EarlyInterviewBridgeGeneration?
    let error: String?
}

private struct LiveInterviewReplayAssistantAttempt: Sendable {
    let generation: LiveAssistantGeneration?
    let error: String?
}

private struct LiveInterviewReplayTurnResult: Codable, Sendable {
    let replayIndex: Int
    let transcriptTurnID: String
    let question: String
    let bridge: String?
    let bridgeGenerationMilliseconds: Int?
    let bridgeError: String?
    let suggestion: CompanionAssistantSuggestion?
    let assistantOutcome: String?
    let assistantGenerationMilliseconds: Int?
    let assistantModelCalls: Int?
    let assistantUsage: AssistantGenerationUsage?
    let assistantError: String?
    let referenceDocumentCount: Int
    let wallMilliseconds: Int
}

private struct LiveInterviewReplayReport: Codable, Sendable {
    let generatedAt: Date
    let sourceSession: CompanionSessionState
    let sourceTranscript: [CompanionTranscriptTurn]
    let originalRetainedSuggestions: [CompanionAssistantSuggestion]
    let model: String
    let reasoningEffort: String
    let bridgeModel: String
    let replayWallMilliseconds: Int
    let results: [LiveInterviewReplayTurnResult]
}

private enum LiveInterviewReplayError: Error {
    case snapshotUnavailable
}

import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import XCTest
@testable import PUnderclass

final class CompanionTests: XCTestCase {
    func testCompositeCursorRoundTrips() throws {
        let cursor = CompanionCursor(streamID: "stream-a", sequence: 42)
        XCTAssertEqual(cursor.description, "stream-a:42")
        XCTAssertEqual(CompanionCursor(description: cursor.description), cursor)
        XCTAssertNil(CompanionCursor(description: "missing-sequence"))
        XCTAssertNil(CompanionCursor(description: "stream:-1"))
    }

    func testAutomaticEventSourceRetryPrefersLastEventID() {
        XCTAssertEqual(
            CompanionGatewayRoutes.resumeCursor(
                queryCursor: "stream-a:12",
                lastEventID: "stream-a:47"
            ),
            "stream-a:47"
        )
        XCTAssertEqual(
            CompanionGatewayRoutes.resumeCursor(
                queryCursor: "stream-a:12",
                lastEventID: nil
            ),
            "stream-a:12"
        )
    }

    func testEventHubReplaysThenContinuesLiveWithoutAGap() async throws {
        let hub = CompanionEventHub(streamID: "test-stream", bufferCapacity: 10)
        let first = await hub.updateSession(isListening: true, status: "Listening")
        let second = await hub.updateReference(
            CompanionReferenceState(
                configured: true,
                folderName: "References",
                phase: "ready",
                documentCount: 2,
                revision: "abc",
                isWatching: true,
                issueCount: 0
            )
        )
        let stream = await hub.subscribe(after: first.cursor)
        var iterator = stream.makeAsyncIterator()

        let replayed = try await nextEvent(from: &iterator)
        XCTAssertEqual(replayed, second)

        let third = await hub.updateUsage(
            CompanionUsageState(estimatedTranscriptionCostUSD: 0.04)
        )
        let live = try await nextEvent(from: &iterator)
        XCTAssertEqual(live, third)
    }

    func testEventHubRequestsSnapshotWhenReplayWindowExpired() async throws {
        let hub = CompanionEventHub(streamID: "test-stream", bufferCapacity: 2)
        _ = await hub.updateSession(isListening: true, status: "one")
        _ = await hub.updateSession(isListening: true, status: "two")
        _ = await hub.updateSession(isListening: true, status: "three")

        let stream = await hub.subscribe(
            after: CompanionCursor(streamID: "test-stream", sequence: 0)
        )
        var iterator = stream.makeAsyncIterator()
        let reset = try await nextEvent(from: &iterator)

        XCTAssertEqual(reset.name, "stream.reset")
        XCTAssertEqual(
            reset.payload,
            .object(["reason": .string("replayWindowExpired")])
        )
        let finished = await iterator.next()
        XCTAssertNil(finished)
    }

    func testEventHubRequestsSnapshotForPreviousProducer() async throws {
        let hub = CompanionEventHub(streamID: "new-stream")
        let stream = await hub.subscribe(
            after: CompanionCursor(streamID: "old-stream", sequence: 12)
        )
        var iterator = stream.makeAsyncIterator()
        let reset = try await nextEvent(from: &iterator)

        XCTAssertEqual(reset.name, "stream.reset")
        XCTAssertEqual(
            reset.payload,
            .object(["reason": .string("producerRestarted")])
        )
    }

    func testCommandsAreIdempotent() async {
        let hub = CompanionEventHub(streamID: "test-stream")
        let command = CompanionCommandRequest(
            type: .pauseSuggestions,
            suggestionID: nil
        )
        let first = await hub.apply(command: command, idempotencyKey: "same-key")
        let second = await hub.apply(command: command, idempotencyKey: "same-key")
        let snapshot = await hub.snapshot()

        XCTAssertEqual(first, second)
        XCTAssertEqual(snapshot.watermark, 1)
        XCTAssertTrue(snapshot.session.suggestionsPaused)
    }

    func testSyntheticInterviewPreparationIsPublishedToTheCompanion() async {
        let hub = CompanionEventHub(streamID: "test-stream")

        _ = await hub.updateSession(
            isListening: false,
            status: "Generating an interview from 3 references…",
            purpose: .interview,
            source: .syntheticInterview,
            title: "Reference-grounded interview",
            isPreparingSyntheticInterview: true
        )
        let snapshot = await hub.snapshot()

        XCTAssertFalse(snapshot.session.isListening)
        XCTAssertTrue(snapshot.session.isPreparingSyntheticInterview)
        XCTAssertEqual(snapshot.session.purpose, .interview)
        XCTAssertEqual(snapshot.session.source, .syntheticInterview)
        XCTAssertEqual(snapshot.session.title, "Reference-grounded interview")
    }

    func testMeetingSessionPublishesMeetingAssistantBehavior() async {
        let hub = CompanionEventHub(streamID: "test-stream")

        _ = await hub.updateSession(
            isListening: true,
            status: "Listening",
            purpose: .meeting
        )
        let snapshot = await hub.snapshot()

        XCTAssertEqual(snapshot.session.purpose, .meeting)
        XCTAssertEqual(snapshot.session.behaviorName, "Meeting assistant")
        XCTAssertTrue(snapshot.session.behaviorDetail.contains("Ground concise"))
    }

    func testLocalCapturePublishesTranscriptOnlyBehavior() async {
        let hub = CompanionEventHub(streamID: "test-stream")

        _ = await hub.updateSession(
            isListening: true,
            status: "Listening locally with Whisper",
            purpose: .meeting,
            assistantAvailable: false
        )
        let snapshot = await hub.snapshot()

        XCTAssertFalse(snapshot.session.assistantAvailable)
        XCTAssertEqual(snapshot.session.behaviorName, "Local transcript")
        XCTAssertTrue(snapshot.session.behaviorDetail.contains("OpenAI"))
    }

    func testInterviewSessionPublishesPlausibleRehearsalMode() async {
        let hub = CompanionEventHub(streamID: "test-stream")

        _ = await hub.updateSession(
            isListening: true,
            status: "Listening",
            purpose: .interview,
            answerMode: .plausibleRehearsal
        )
        let snapshot = await hub.snapshot()

        XCTAssertEqual(snapshot.session.answerMode, .plausibleRehearsal)
        XCTAssertTrue(snapshot.session.behaviorDetail.contains("plausible"))
    }

    func testInterviewSessionOnlyPublishesEarlyBridgeForPlausibleMode() async {
        let hub = CompanionEventHub(streamID: "test-stream")

        _ = await hub.updateSession(
            isListening: true,
            status: "Listening",
            purpose: .interview,
            answerMode: .grounded,
            earlyBridgeEnabled: true
        )
        var snapshot = await hub.snapshot()
        XCTAssertFalse(snapshot.session.earlyBridgeEnabled)

        _ = await hub.updateSession(
            isListening: true,
            status: "Listening",
            purpose: .interview,
            answerMode: .plausibleRehearsal,
            earlyBridgeEnabled: true
        )
        snapshot = await hub.snapshot()
        XCTAssertTrue(snapshot.session.earlyBridgeEnabled)
        XCTAssertTrue(snapshot.session.behaviorDetail.contains("early bridge"))
    }

    func testEarlyBridgeSurvivesWorkingStateAndFullSuggestionReplacesIt() async
        throws
    {
        let hub = CompanionEventHub(streamID: "test-stream")
        let bridge = CompanionAssistantBridge(
            id: "bridge-1",
            topicID: "other-turn-1",
            sourceText: "How did you verify the bottleneck?",
            text: "I'd first check where the time is going, then narrow it down.",
            generatedAt: Date(timeIntervalSince1970: 100),
            generationMilliseconds: 1_420
        )

        let event = await hub.assistantBridged(bridge)
        let published = try CompanionJSON.decoder().decode(
            CompanionAssistantBridge.self,
            from: CompanionJSON.encoder().encode(event.payload)
        )
        XCTAssertEqual(published, bridge)

        _ = await hub.assistantWorking(basedOnSequence: 4)
        var snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.bridge, bridge)

        _ = await hub.assistantSuggested(
            answerSuggestion(
                id: "answer-1",
                sequence: 5,
                topicID: "other-turn-1"
            )
        )
        snapshot = await hub.snapshot()
        XCTAssertNil(snapshot.assistant.bridge)
        XCTAssertEqual(snapshot.assistant.suggestion?.id, "answer-1")
    }

    func testEarlyBridgeSurvivesAnInconclusivePartialCheck() async {
        let hub = CompanionEventHub(streamID: "test-stream")
        let bridge = CompanionAssistantBridge(
            id: "bridge-1",
            topicID: "other-turn-1",
            sourceText: "How would you isolate the slow pass?",
            text: "I'd first time each pass, then change one cost at a time.",
            generatedAt: Date(timeIntervalSince1970: 100),
            generationMilliseconds: 900
        )

        _ = await hub.assistantBridged(bridge)
        _ = await hub.assistantWorking(
            basedOnSequence: 4,
            trigger: .partialTranscript
        )
        _ = await hub.assistantFinishedWithoutSuggestion(
            basedOnSequence: 4,
            trigger: .partialTranscript
        )

        var snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.bridge, bridge)

        _ = await hub.assistantWorking(
            basedOnSequence: 5,
            trigger: .finalizedTurn
        )
        _ = await hub.assistantFinishedWithoutSuggestion(
            basedOnSequence: 5,
            trigger: .finalizedTurn
        )
        snapshot = await hub.snapshot()
        XCTAssertNil(snapshot.assistant.bridge)
    }

    func testNewInterviewerTurnSupersedesStaleBridgeAndWorkingState() async {
        let hub = CompanionEventHub(streamID: "test-stream")
        _ = await hub.assistantBridged(
            CompanionAssistantBridge(
                id: "bridge-old",
                topicID: "other-turn-old",
                sourceText: "Tell me about an optimization.",
                text: "I'd start with what changed, then how I checked it.",
                generatedAt: Date(timeIntervalSince1970: 100),
                generationMilliseconds: 1_300
            )
        )
        _ = await hub.assistantWorking(basedOnSequence: 4)

        _ = await hub.assistantSupersededForNewTurn()

        let snapshot = await hub.snapshot()
        XCTAssertNil(snapshot.assistant.bridge)
        XCTAssertEqual(snapshot.assistant.phase, .idle)
        XCTAssertNil(snapshot.assistant.evaluatingSequence)
        XCTAssertNil(snapshot.assistant.evaluatingTrigger)
    }

    func testAssistantStateReportsACompletedCheckWithoutGuidance() async {
        let hub = CompanionEventHub(streamID: "test-stream")
        let triggeredAt = Date(timeIntervalSince1970: 100)
        let startedAt = triggeredAt.addingTimeInterval(0.45)
        let completedAt = triggeredAt.addingTimeInterval(1.7)

        _ = await hub.assistantWorking(
            basedOnSequence: 41,
            trigger: .partialTranscript,
            triggeredAt: triggeredAt,
            startedAt: startedAt
        )
        var snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.phase, .working)
        XCTAssertEqual(snapshot.assistant.evaluatingSequence, 41)
        XCTAssertEqual(snapshot.assistant.evaluatingTrigger, .partialTranscript)
        XCTAssertEqual(snapshot.assistant.evaluationTriggeredAt, triggeredAt)
        XCTAssertEqual(snapshot.assistant.evaluationStartedAt, startedAt)

        _ = await hub.assistantFinishedWithoutSuggestion(
            basedOnSequence: 41,
            completedAt: completedAt
        )
        snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.phase, .idle)
        XCTAssertNil(snapshot.assistant.evaluatingSequence)
        XCTAssertEqual(snapshot.assistant.lastEvaluatedSequence, 41)
        XCTAssertEqual(snapshot.assistant.lastEvaluationOutcome, .notAnswerable)
        XCTAssertEqual(snapshot.assistant.lastEvaluationAt, completedAt)
        XCTAssertEqual(snapshot.assistant.lastEvaluationTrigger, .partialTranscript)
        XCTAssertEqual(snapshot.assistant.lastEvaluationLatencyMilliseconds, 1_700)
    }

    func testAssistantStateReportsARepairedGroundingOutcome() async throws {
        let hub = CompanionEventHub(streamID: "test-stream")
        let event = await hub.assistantSuggested(
            answerSuggestion(id: "repaired", sequence: 42),
            outcome: .repairedGrounding
        )

        let snapshot = await hub.snapshot()
        XCTAssertEqual(
            snapshot.assistant.lastEvaluationOutcome,
            .repairedGrounding
        )
        XCTAssertEqual(
            snapshot.assistant.suggestion?.inferenceOutcome,
            .repairedGrounding
        )
        let publishedSuggestion = try CompanionJSON.decoder().decode(
            CompanionAssistantSuggestion.self,
            from: CompanionJSON.encoder().encode(event.payload)
        )
        XCTAssertEqual(
            publishedSuggestion.inferenceOutcome,
            .repairedGrounding
        )
    }

    func testAssistantKeepsNewestFourAnswersAndDismissRevealsPrevious() async throws {
        let hub = CompanionEventHub(streamID: "test-stream")
        var lastEvent: CompanionEvent?
        for index in 1...5 {
            lastEvent = await hub.assistantSuggested(
                answerSuggestion(id: "answer-\(index)", sequence: index)
            )
        }

        var snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.suggestion?.id, "answer-5")
        XCTAssertEqual(snapshot.assistant.suggestion?.topicNumber, 5)
        XCTAssertEqual(
            snapshot.assistant.suggestionHistory.map(\.id),
            ["answer-5", "answer-4", "answer-3", "answer-2"]
        )
        XCTAssertEqual(
            snapshot.assistant.suggestionHistory.map(\.topicNumber),
            [5, 4, 3, 2]
        )
        let event = try XCTUnwrap(lastEvent)
        let publishedSuggestion = try CompanionJSON.decoder().decode(
            CompanionAssistantSuggestion.self,
            from: CompanionJSON.encoder().encode(event.payload)
        )
        XCTAssertEqual(publishedSuggestion.topicNumber, 5)

        _ = await hub.assistantFinishedWithoutSuggestion(basedOnSequence: 6)
        snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.suggestion?.id, "answer-5")
        XCTAssertEqual(snapshot.assistant.suggestionHistory.count, 4)

        _ = await hub.apply(
            command: CompanionCommandRequest(
                type: .dismissSuggestion,
                suggestionID: "answer-5"
            ),
            idempotencyKey: "dismiss-current"
        )
        snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.suggestion?.id, "answer-4")
        XCTAssertEqual(snapshot.assistant.suggestion?.topicNumber, 4)
        XCTAssertEqual(
            snapshot.assistant.suggestionHistory.map(\.id),
            ["answer-4", "answer-3", "answer-2"]
        )

        _ = await hub.clearTranscript()
        _ = await hub.assistantSuggested(
            answerSuggestion(id: "answer-new-session", sequence: 7)
        )
        snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.suggestion?.topicNumber, 1)
    }

    func testAssistantKeepsEarlierCueWhenFinalTurnRevisesSameTopic() async {
        let hub = CompanionEventHub(streamID: "test-stream")
        _ = await hub.assistantSuggested(
            answerSuggestion(
                id: "answer-partial",
                sequence: 1,
                topicID: "other-turn-1"
            )
        )
        _ = await hub.assistantSuggested(
            answerSuggestion(
                id: "answer-final",
                sequence: 2,
                topicID: "other-turn-1"
            )
        )
        _ = await hub.assistantSuggested(
            answerSuggestion(
                id: "answer-next-topic",
                sequence: 3,
                topicID: "other-turn-2"
            )
        )

        let snapshot = await hub.snapshot()
        XCTAssertEqual(
            snapshot.assistant.suggestionHistory.map(\.id),
            ["answer-next-topic", "answer-final", "answer-partial"]
        )
        XCTAssertEqual(
            snapshot.assistant.suggestionHistory.map(\.topicID),
            ["other-turn-2", "other-turn-1", "other-turn-1"]
        )
        XCTAssertEqual(
            snapshot.assistant.suggestionHistory.map(\.topicNumber),
            [2, 1, 1]
        )
    }

    func testAssistantEvaluationPolicyStartsStablePartialsBeforeFinalTurns() {
        XCTAssertEqual(
            AssistantEvaluationPolicy.delayMilliseconds(for: .partialTranscript),
            0
        )
        XCTAssertEqual(
            AssistantEvaluationPolicy.delayMilliseconds(for: .finalizedTurn),
            0
        )
        XCTAssertLessThan(
            AssistantEvaluationPolicy.partialSpeechPauseMilliseconds,
            3_000
        )
        XCTAssertEqual(
            RealtimeTranscriptionClient.assistantPauseSilenceChunkCount * 20,
            AssistantEvaluationPolicy.partialSpeechPauseMilliseconds
        )
        XCTAssertEqual(
            RealtimeTranscriptionClient
                .earlyBridgePauseSilenceChunkCount * 20,
            400
        )
        XCTAssertLessThan(
            RealtimeTranscriptionClient.earlyBridgePauseSilenceChunkCount,
            RealtimeTranscriptionClient.assistantPauseSilenceChunkCount
        )
        XCTAssertTrue(
            AssistantEvaluationPolicy.shouldEvaluate(
                speaker: .other,
                purpose: .interview
            )
        )
        XCTAssertFalse(
            AssistantEvaluationPolicy.shouldEvaluate(
                speaker: .you,
                purpose: .interview
            )
        )
        XCTAssertTrue(
            AssistantEvaluationPolicy.shouldEvaluate(
                speaker: .other,
                purpose: .meeting
            )
        )
        XCTAssertFalse(
            AssistantEvaluationPolicy.shouldEvaluate(
                speaker: .you,
                purpose: .meeting
            )
        )
        XCTAssertTrue(
            EarlyInterviewBridgeEvaluationPolicy.shouldEvaluate(
                speaker: .other,
                purpose: .interview,
                answerMode: .plausibleRehearsal,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            EarlyInterviewBridgeEvaluationPolicy.shouldEvaluate(
                speaker: .other,
                purpose: .interview,
                answerMode: .grounded,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            EarlyInterviewBridgeEvaluationPolicy.shouldEvaluate(
                speaker: .other,
                purpose: .meeting,
                answerMode: .plausibleRehearsal,
                isEnabled: true
            )
        )
        XCTAssertEqual(
            EarlyInterviewBridgeEvaluationPolicy
                .maximumFormingTranscriptAttemptsPerTurn,
            2
        )
        XCTAssertEqual(
            EarlyInterviewBridgeEvaluationPolicy
                .maximumSpeechPauseAttemptsPerTurn,
            3
        )
        XCTAssertEqual(
            EarlyInterviewBridgeEvaluationPolicy.delayMilliseconds(
                for: .formingTranscript,
                attempt: 0
            ),
            600
        )
        XCTAssertEqual(
            EarlyInterviewBridgeEvaluationPolicy.delayMilliseconds(
                for: .formingTranscript,
                attempt: 1
            ),
            200
        )
        XCTAssertEqual(
            EarlyInterviewBridgeEvaluationPolicy.delayMilliseconds(
                for: .speechPause
            ),
            0
        )
        XCTAssertEqual(
            EarlyInterviewBridgeEvaluationPolicy.delayMilliseconds(
                for: .finalizedTurn
            ),
            0
        )
    }

    func testEarlyInterviewBridgeUsesPriorityLunaAndStrictOutput() throws {
        let data = try EarlyInterviewBridgeClient.requestBody(
            currentPartial:
                "How did you verify that you found the right bottleneck?",
            recentTranscript: "You: I changed the upload path.",
            sessionContext: "Rendering systems interview.",
            opportunity: .speechPause
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(root["service_tier"] as? String, "priority")
        XCTAssertEqual(root["store"] as? Bool, false)
        XCTAssertEqual(root["max_output_tokens"] as? Int, 60)
        XCTAssertNil(root["tools"])
        XCTAssertEqual(
            (root["reasoning"] as? [String: String])?["effort"],
            "none"
        )

        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        let developerContent = try XCTUnwrap(
            input[0]["content"] as? [[String: Any]]
        )
        let developerPrompt = try XCTUnwrap(
            developerContent[0]["text"] as? String
        )
        XCTAssertTrue(developerPrompt.contains("actual first sentence"))
        XCTAssertTrue(developerPrompt.contains("Never invent a named project"))
        XCTAssertTrue(developerPrompt.contains("short clauses, contractions"))
        XCTAssertTrue(developerPrompt.contains("Never say what example"))
        XCTAssertFalse(developerPrompt.contains("I'd use one example and"))
        let userContent = try XCTUnwrap(
            input[1]["content"] as? [[String: Any]]
        )
        let userPrompt = try XCTUnwrap(userContent[0]["text"] as? String)
        XCTAssertTrue(userPrompt.contains("Meaningful speech pause"))
        XCTAssertTrue(userPrompt.contains("CURRENT PARTIAL INTERVIEWER SPEECH"))
        XCTAssertTrue(userPrompt.contains("right bottleneck"))

        let text = try XCTUnwrap(root["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["bridge"])
    }

    func testEarlyInterviewBridgeParsesSafeBridgeAndNoShow() throws {
        let shown = try EarlyInterviewBridgeClient.parseResponse(
            try earlyBridgeResponseData(
                bridge:
                    "I'd first check where the time is going, then narrow it down."
            ),
            generationMilliseconds: 1_420
        )
        XCTAssertEqual(
            shown.bridge,
            "I'd first check where the time is going, then narrow it down."
        )
        XCTAssertEqual(shown.generationMilliseconds, 1_420)
        XCTAssertEqual(shown.serviceTier, "priority")
        XCTAssertEqual(shown.usage.inputTokens, 132)
        XCTAssertEqual(shown.usage.outputTokens, 29)

        let hidden = try EarlyInterviewBridgeClient.parseResponse(
            try earlyBridgeResponseData(bridge: ""),
            generationMilliseconds: 900
        )
        XCTAssertNil(hidden.bridge)

        XCTAssertThrowsError(
            try EarlyInterviewBridgeClient.parseResponse(
                try earlyBridgeResponseData(
                    bridge: Array(repeating: "word", count: 21)
                        .joined(separator: " ")
                ),
                generationMilliseconds: 900
            )
        ) { error in
            XCTAssertEqual(error as? LiveAssistantError, .invalidResponse)
        }
    }

    func testSyntheticInterviewGenerationUsesReferencesAndBuildsFiveExchanges() throws {
        let references = referenceSnapshot()
        let requestData = try SyntheticInterviewGeneratorClient.requestBody(
            references: references,
            purpose: .interview
        )
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        XCTAssertEqual(request["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(request["max_output_tokens"] as? Int, 1_600)
        let input = try XCTUnwrap(request["input"] as? [[String: Any]])
        let developerContent = try XCTUnwrap(
            input[0]["content"] as? [[String: Any]]
        )
        let developerPrompt = try XCTUnwrap(
            developerContent[0]["text"] as? String
        )
        XCTAssertTrue(developerPrompt.contains("Resume.md"))
        XCTAssertTrue(
            developerPrompt.contains("must be grounded in this local material")
        )
        XCTAssertTrue(developerPrompt.contains("deeply technical CUDA questions"))
        XCTAssertTrue(developerPrompt.contains("Avoid corporate language"))
        XCTAssertTrue(
            developerPrompt.contains("newest comparably relevant work")
        )
        let userContent = try XCTUnwrap(
            input[1]["content"] as? [[String: Any]]
        )
        XCTAssertEqual(
            userContent[0]["text"] as? String,
            "Generate the five-exchange interview now."
        )
        let text = try XCTUnwrap(request["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let exchanges = try XCTUnwrap(properties["exchanges"] as? [String: Any])
        XCTAssertEqual(exchanges["minItems"] as? Int, 5)
        XCTAssertEqual(exchanges["maxItems"] as? Int, 5)

        let generatedAt = Date(timeIntervalSince1970: 200)
        let generation = try SyntheticInterviewGeneratorClient.parseResponse(
            try syntheticInterviewResponseData(),
            references: references,
            purpose: .interview,
            generatedAt: generatedAt,
            generationMilliseconds: 640
        )
        let scenario = generation.scenario
        XCTAssertEqual(scenario.purpose, .interview)
        XCTAssertEqual(scenario.referenceRevision, references.revision)
        XCTAssertEqual(scenario.referenceDocumentCount, 1)
        XCTAssertEqual(scenario.generatedAt, generatedAt)
        XCTAssertEqual(scenario.finalizationDelay, 3)
        XCTAssertEqual(scenario.turns.count, 10)
        XCTAssertEqual(scenario.turns.map(\.speaker), [
            .other, .you, .other, .you, .other, .you, .other, .you,
            .other, .you
        ])
        XCTAssertGreaterThan(
            scenario.turns[0].pauseAfterSpeech,
            scenario.finalizationDelay
        )
        XCTAssertEqual(generation.usage.inputTokens, 900)
        XCTAssertEqual(generation.generationMilliseconds, 640)
    }

    func testWebSearchScenarioAsksOneCurrentPublicQuestion() {
        let generatedAt = Date(timeIntervalSince1970: 300)
        let scenario = SyntheticInterviewScenario.webSearchTest(
            generatedAt: generatedAt
        )

        XCTAssertEqual(scenario.name, "Live Web Search Test")
        XCTAssertEqual(scenario.purpose, .interview)
        XCTAssertEqual(scenario.referenceDocumentCount, 0)
        XCTAssertEqual(scenario.generatedAt, generatedAt)
        XCTAssertEqual(scenario.turns.count, 1)
        XCTAssertEqual(scenario.turns[0].speaker, .other)
        XCTAssertEqual(
            scenario.turns[0].text,
            SyntheticInterviewScenario.webSearchTestQuestion
        )
        XCTAssertTrue(scenario.turns[0].text.contains("current public sources"))
        XCTAssertGreaterThan(
            scenario.turns[0].pauseAfterSpeech,
            scenario.finalizationDelay
        )
    }

    func testSyntheticMeetingGenerationUsesMeetingPromptAndPurpose() throws {
        let references = referenceSnapshot()
        let requestData = try SyntheticInterviewGeneratorClient.requestBody(
            references: references,
            purpose: .meeting
        )
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        let input = try XCTUnwrap(request["input"] as? [[String: Any]])
        let developerContent = try XCTUnwrap(
            input[0]["content"] as? [[String: Any]]
        )
        let developerPrompt = try XCTUnwrap(
            developerContent[0]["text"] as? String
        )
        XCTAssertTrue(developerPrompt.contains("This is not a job interview"))
        let userContent = try XCTUnwrap(
            input[1]["content"] as? [[String: Any]]
        )
        XCTAssertEqual(
            userContent[0]["text"] as? String,
            "Generate the five-exchange meeting now."
        )
        let text = try XCTUnwrap(request["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(
            format["name"] as? String,
            "reference_grounded_synthetic_meeting"
        )

        let generation = try SyntheticInterviewGeneratorClient.parseResponse(
            try syntheticInterviewResponseData(),
            references: references,
            purpose: .meeting,
            generatedAt: Date(timeIntervalSince1970: 200),
            generationMilliseconds: 640
        )
        XCTAssertEqual(generation.scenario.purpose, .meeting)
        XCTAssertTrue(
            generation.scenario.turns[0].id.contains("generated-meeting-question")
        )
    }

    func testSyntheticInterviewScenarioStoreMatchesReferenceRevision() throws {
        let generation = try SyntheticInterviewGeneratorClient.parseResponse(
            try syntheticInterviewResponseData(),
            references: referenceSnapshot(),
            purpose: .interview,
            generatedAt: Date(timeIntervalSince1970: 200),
            generationMilliseconds: 640
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SyntheticInterviewStore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SyntheticInterviewScenarioStore(
            fileURL: folder.appendingPathComponent("scenario.json")
        )

        try store.save(generation.scenario)

        XCTAssertEqual(
            try store.load(
                referenceRevision: "reference-revision",
                purpose: .interview
            ),
            generation.scenario
        )
        XCTAssertNil(
            try store.load(
                referenceRevision: "changed-revision",
                purpose: .interview
            )
        )
        XCTAssertNil(
            try store.load(
                referenceRevision: "reference-revision",
                purpose: .meeting
            )
        )

        let outdatedScenario = SyntheticInterviewScenario(
            generationVersion: SyntheticInterviewScenario.generationVersion - 1,
            purpose: .interview,
            name: generation.scenario.name,
            referenceRevision: generation.scenario.referenceRevision,
            referenceDocumentCount: generation.scenario.referenceDocumentCount,
            generatedAt: generation.scenario.generatedAt,
            finalizationDelay: generation.scenario.finalizationDelay,
            turns: generation.scenario.turns
        )
        try store.save(outdatedScenario)
        XCTAssertNil(
            try store.load(
                referenceRevision: generation.scenario.referenceRevision,
                purpose: .interview
            )
        )
    }

    func testSyntheticInterviewRejectsUnknownReferencePaths() throws {
        XCTAssertThrowsError(
            try SyntheticInterviewGeneratorClient.parseResponse(
                try syntheticInterviewResponseData(
                    sourcePaths: ["Resume.md", "NotIndexed.md"]
                ),
                references: referenceSnapshot(),
                purpose: .interview,
                generatedAt: Date(timeIntervalSince1970: 200),
                generationMilliseconds: 640
            )
        ) { error in
            XCTAssertEqual(
                error as? SyntheticInterviewGeneratorError,
                .invalidGrounding
            )
        }
    }

    func testExpenseSummaryTracksAssistantCacheAndReasoningUsage() {
        var summary = APIExpenseSummary()
        summary.record(
            AssistantGenerationUsage(
                inputTokens: 2_000,
                cachedInputTokens: 1_200,
                cacheWriteTokens: 400,
                outputTokens: 180,
                reasoningTokens: 32,
                requestCount: 2,
                groundingRepairAttempts: 1,
                groundingRepairSuccesses: 1,
                groundingRepairMilliseconds: 480
            )
        )

        XCTAssertEqual(summary.assistantGenerations, 1)
        XCTAssertEqual(summary.assistantModelCalls, 2)
        XCTAssertEqual(summary.assistantGroundingRepairAttempts, 1)
        XCTAssertEqual(summary.assistantGroundingRepairSuccesses, 1)
        XCTAssertEqual(summary.assistantGroundingRepairMilliseconds, 480)
        XCTAssertEqual(summary.assistantInputTokens, 2_000)
        XCTAssertEqual(summary.assistantCachedInputTokens, 1_200)
        XCTAssertEqual(summary.assistantCacheWriteTokens, 400)
        XCTAssertEqual(summary.assistantOutputTokens, 180)
        XCTAssertEqual(summary.assistantReasoningTokens, 32)
        XCTAssertEqual(summary.totalCostUSD, 0)
    }

    func testLiveAssistantRequestUsesStructuredOutputAndExplicitCacheBoundary() throws {
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "short spoken preamble"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "first-person voice"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "ordinary vocabulary, short clauses"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "match its usual sentence length and level of formality"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "Colloquial does not mean sloppy"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "the CPU spent less time submitting draws"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "Avoid resume language"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.interviewBehaviorInstructions.contains(
                "Specificity is more important"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.plausibleRehearsalInstructions.contains(
                "five non-empty fields"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.plausibleRehearsalInstructions.contains(
                "A component inventory is not a change"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.plausibleRehearsalInstructions.contains(
                "silent plain-language pass"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.plausibleRehearsalInstructions.contains(
                "Name the project or work setting once"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.plausibleRehearsalInstructions.contains(
                "let its field names shape the spoken wording"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.plausibleRehearsalInstructions.contains(
                "Never put provenance, uncertainty, or memory disclaimers"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.meetingBehaviorInstructions.contains(
                "Never fabricate a commitment"
            )
        )
        XCTAssertTrue(
            LiveAssistantClient.meetingBehaviorInstructions.contains(
                "question, request, or decision"
            )
        )
        let plan = AssistantPromptPlan(
            cachedPrefix: "stable behavior and references",
            volatileSuffix: "Other: What did you build?",
            promptCacheKey: "punderclass:test"
        )
        let data = try LiveAssistantClient.requestBody(
            for: plan,
            purpose: .interview
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(root["service_tier"] as? String, "priority")
        XCTAssertEqual(root["store"] as? Bool, false)
        XCTAssertEqual(root["max_output_tokens"] as? Int, 350)
        XCTAssertEqual(root["prompt_cache_key"] as? String, "punderclass:test")
        XCTAssertEqual(root["tool_choice"] as? String, "auto")
        let tools = try XCTUnwrap(root["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(
            tools[0]["type"] as? String,
            LiveAssistantClient.webSearchToolType
        )
        XCTAssertEqual(tools[0]["search_context_size"] as? String, "low")
        XCTAssertEqual(
            root["include"] as? [String],
            ["web_search_call.action.sources"]
        )
        let reasoning = try XCTUnwrap(root["reasoning"] as? [String: String])
        XCTAssertEqual(reasoning["effort"], "medium")

        let cacheOptions = try XCTUnwrap(
            root["prompt_cache_options"] as? [String: String]
        )
        XCTAssertEqual(cacheOptions["mode"], "explicit")
        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        let developerContent = try XCTUnwrap(
            input[0]["content"] as? [[String: Any]]
        )
        XCTAssertEqual(developerContent[0]["text"] as? String, plan.cachedPrefix)
        let breakpoint = try XCTUnwrap(
            developerContent[0]["prompt_cache_breakpoint"] as? [String: String]
        )
        XCTAssertEqual(breakpoint["mode"], "explicit")

        let text = try XCTUnwrap(root["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let grounding = try XCTUnwrap(properties["grounding"] as? [String: Any])
        XCTAssertEqual(
            grounding["enum"] as? [String],
            ["localReferences", "webSearch", "generalKnowledge"]
        )
        let beats = try XCTUnwrap(properties["beats"] as? [String: Any])
        XCTAssertNotNil(properties["preamble"])
        XCTAssertEqual(beats["minItems"] as? Int, 2)
        XCTAssertEqual(beats["maxItems"] as? Int, 3)
        XCTAssertNotNil(properties["usedExtrapolation"])
        XCTAssertNotNil(properties["plausibleAssumptions"])
        XCTAssertNotNil(properties["spokenCueContainsMetaCommentary"])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertTrue(required.contains("spokenCueContainsMetaCommentary"))

        let highReasoningData = try LiveAssistantClient.requestBody(
            for: plan,
            purpose: .interview,
            answerMode: .plausibleRehearsal,
            configuration: LiveAssistantConfiguration(
                model: "gpt-5.6-terra",
                reasoningEffort: .xhigh,
                maximumOutputTokens: 1_200
            )
        )
        let highReasoningRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: highReasoningData)
                as? [String: Any]
        )
        XCTAssertEqual(highReasoningRoot["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(highReasoningRoot["max_output_tokens"] as? Int, 1_200)
        XCTAssertEqual(
            (highReasoningRoot["reasoning"] as? [String: String])?["effort"],
            "xhigh"
        )
        let highReasoningText = try XCTUnwrap(
            highReasoningRoot["text"] as? [String: Any]
        )
        let highReasoningFormat = try XCTUnwrap(
            highReasoningText["format"] as? [String: Any]
        )
        let plausibleSchema = try XCTUnwrap(
            highReasoningFormat["schema"] as? [String: Any]
        )
        let plausibleProperties = try XCTUnwrap(
            plausibleSchema["properties"] as? [String: Any]
        )
        let plausibleBeats = try XCTUnwrap(
            plausibleProperties["beats"] as? [String: Any]
        )
        XCTAssertEqual(plausibleBeats["minItems"] as? Int, 3)
        XCTAssertEqual(plausibleBeats["maxItems"] as? Int, 3)
        XCTAssertNotNil(plausibleProperties["plausibleRehearsalPlan"])

        let plausibleDefaultBudgetData = try LiveAssistantClient.requestBody(
            for: plan,
            purpose: .interview,
            answerMode: .plausibleRehearsal
        )
        let plausibleDefaultBudgetRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plausibleDefaultBudgetData)
                as? [String: Any]
        )
        XCTAssertEqual(
            plausibleDefaultBudgetRoot["max_output_tokens"] as? Int,
            650
        )

        let requiredSearchData = try LiveAssistantClient.requestBody(
            for: plan,
            purpose: .interview,
            webSearchMode: .required
        )
        let requiredSearchRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requiredSearchData)
                as? [String: Any]
        )
        XCTAssertEqual(requiredSearchRoot["tool_choice"] as? String, "required")
        XCTAssertEqual(requiredSearchRoot["max_output_tokens"] as? Int, 800)
        let requiredSearchTools = try XCTUnwrap(
            requiredSearchRoot["tools"] as? [[String: Any]]
        )
        XCTAssertEqual(
            requiredSearchTools[0]["search_context_size"] as? String,
            "high"
        )

        let plausibleRequiredSearchData = try LiveAssistantClient.requestBody(
            for: plan,
            purpose: .interview,
            webSearchMode: .required,
            answerMode: .plausibleRehearsal
        )
        let plausibleRequiredSearchRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plausibleRequiredSearchData)
                as? [String: Any]
        )
        XCTAssertEqual(
            plausibleRequiredSearchRoot["max_output_tokens"] as? Int,
            900
        )

        let meetingData = try LiveAssistantClient.requestBody(
            for: plan,
            purpose: .meeting
        )
        let meetingRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: meetingData) as? [String: Any]
        )
        let meetingText = try XCTUnwrap(
            meetingRoot["text"] as? [String: Any]
        )
        let meetingFormat = try XCTUnwrap(
            meetingText["format"] as? [String: Any]
        )
        XCTAssertEqual(meetingFormat["name"] as? String, "meeting_assistant")
        let meetingSchema = try XCTUnwrap(
            meetingFormat["schema"] as? [String: Any]
        )
        let meetingProperties = try XCTUnwrap(
            meetingSchema["properties"] as? [String: Any]
        )
        XCTAssertNil(meetingProperties["preamble"])
        XCTAssertNil(meetingProperties["spokenCueContainsMetaCommentary"])
        let meetingBeats = try XCTUnwrap(
            meetingProperties["beats"] as? [String: Any]
        )
        XCTAssertEqual(meetingBeats["minItems"] as? Int, 3)
        XCTAssertEqual(meetingBeats["maxItems"] as? Int, 5)
    }

    func testLiveAssistantExtractsHostedWebSearchSources() {
        let root: [String: Any] = [
            "output": [
                [
                    "type": "web_search_call",
                    "action": [
                        "type": "search",
                        "sources": [
                            [
                                "title": "WebKit Features",
                                "url": "https://webkit.org/blog/example/"
                            ],
                            [
                                "title": "Not a web URL",
                                "url": "file:///tmp/private"
                            ]
                        ]
                    ]
                ],
                [
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "annotations": [[
                            "type": "url_citation",
                            "title": "Swift Releases",
                            "url": "https://www.swift.org/blog/"
                        ]]
                    ]]
                ]
            ]
        ]

        XCTAssertEqual(
            LiveAssistantClient.webSources(from: root),
            [
                LiveAssistantWebSource(
                    title: "WebKit Features",
                    url: "https://webkit.org/blog/example/"
                ),
                LiveAssistantWebSource(
                    title: "Swift Releases",
                    url: "https://www.swift.org/blog/"
                )
            ]
        )
    }

    func testLiveAssistantResponseParsesUsageAndRejectsUnknownCitationPaths() throws {
        let output: [String: Any] = [
            "shouldShow": true,
            "grounding": "localReferences",
            "question": "What did you improve?",
            "preamble": "The clearest example is the checkout path.",
            "beats": [
                ["label": "Context", "point": "Checkout latency hurting conversion"],
                ["label": "My move", "point": "Traced path; removed N+1 lookup"],
                ["label": "Proof", "point": "41 percent lower p95 under load"]
            ],
            "citations": [
                ["label": "Project brief", "path": "Projects/Checkout.md"],
                ["label": "Invented", "path": "not-indexed.txt"]
            ],
            "confidence": "high"
        ]
        let outputData = try JSONSerialization.data(withJSONObject: output)
        let outputText = try XCTUnwrap(String(data: outputData, encoding: .utf8))
        let response: [String: Any] = [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": outputText]]
            ]],
            "usage": [
                "input_tokens": 2_000,
                "input_tokens_details": [
                    "cached_tokens": 1_200,
                    "cache_write_tokens": 0
                ],
                "output_tokens": 180,
                "output_tokens_details": ["reasoning_tokens": 32]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let generation = try LiveAssistantClient.parseResponse(
            data,
            allowedReferencePaths: ["Projects/Checkout.md"],
            basedOnSequence: 19,
            generationMilliseconds: 320
        )

        XCTAssertEqual(generation.usage.inputTokens, 2_000)
        XCTAssertEqual(generation.usage.cachedInputTokens, 1_200)
        XCTAssertEqual(generation.usage.reasoningTokens, 32)
        XCTAssertEqual(generation.suggestion?.basedOnSequence, 19)
        XCTAssertEqual(generation.suggestion?.grounding, .localReferences)
        XCTAssertEqual(
            generation.suggestion?.preamble,
            "The clearest example is the checkout path."
        )
        XCTAssertEqual(
            generation.suggestion?.beats,
            [
                CompanionAnswerBeat(
                    label: "Context",
                    point: "Checkout latency hurting conversion"
                ),
                CompanionAnswerBeat(
                    label: "My move",
                    point: "Traced path; removed N+1 lookup"
                ),
                CompanionAnswerBeat(
                    label: "Proof",
                    point: "41 percent lower p95 under load"
                )
            ]
        )
        XCTAssertEqual(
            generation.suggestion?.citations,
            [CompanionCitation(label: "Project brief", path: "Projects/Checkout.md")]
        )

        XCTAssertThrowsError(
            try LiveAssistantClient.parseResponse(
                data,
                allowedReferencePaths: [],
                basedOnSequence: 19,
                generationMilliseconds: 320
            )
        ) { error in
            XCTAssertEqual(error as? LiveAssistantError, .invalidGrounding)
        }

        var generalOutput = output
        generalOutput["grounding"] = "generalKnowledge"
        generalOutput["citations"] = []
        let generalOutputData = try JSONSerialization.data(withJSONObject: generalOutput)
        let generalOutputText = try XCTUnwrap(
            String(data: generalOutputData, encoding: .utf8)
        )
        var generalResponse = response
        generalResponse["output"] = [[
            "type": "message",
            "content": [["type": "output_text", "text": generalOutputText]]
        ]]
        let generalData = try JSONSerialization.data(withJSONObject: generalResponse)
        let fallback = try LiveAssistantClient.parseResponse(
            generalData,
            allowedReferencePaths: [],
            basedOnSequence: 20,
            generationMilliseconds: 280
        )

        XCTAssertEqual(fallback.suggestion?.basedOnSequence, 20)
        XCTAssertEqual(fallback.suggestion?.grounding, .generalKnowledge)
        XCTAssertEqual(fallback.suggestion?.citations, [])
        XCTAssertEqual(fallback.outcome, .suggestion)

        var plausibleOutput = output
        plausibleOutput["usedExtrapolation"] = true
        plausibleOutput["plausibleAssumptions"] = [
            "The checkout project is real; the cache experiment is rehearsed."
        ]
        plausibleOutput["plausibleRehearsalPlan"] = [
            "projectAnchor": "Checkout path",
            "observedSignal": "Repeated inventory lookups raised p95 latency",
            "mechanismChange": "Batched the lookups instead of issuing one per item",
            "discriminatingCheck": "Replayed the same recorded traffic before and after",
            "boundedOutcome": "The repeated-query bottleneck stopped dominating p95"
        ]
        let plausibleOutputData = try JSONSerialization.data(
            withJSONObject: plausibleOutput
        )
        let plausibleOutputText = try XCTUnwrap(
            String(data: plausibleOutputData, encoding: .utf8)
        )
        var plausibleResponse = response
        plausibleResponse["output"] = [[
            "type": "message",
            "content": [["type": "output_text", "text": plausibleOutputText]]
        ]]
        let plausibleData = try JSONSerialization.data(
            withJSONObject: plausibleResponse
        )
        let plausibleGeneration = try LiveAssistantClient.parseResponse(
            plausibleData,
            allowedReferencePaths: ["Projects/Checkout.md"],
            basedOnSequence: 22,
            generationMilliseconds: 300,
            answerMode: .plausibleRehearsal
        )
        XCTAssertEqual(
            plausibleGeneration.suggestion?.answerMode,
            .plausibleRehearsal
        )
        XCTAssertEqual(
            plausibleGeneration.suggestion?.plausibleAssumptions,
            ["The checkout project is real; the cache experiment is rehearsed."]
        )
        XCTAssertEqual(
            plausibleGeneration.suggestion?.plausibleRehearsalPlan?
                .mechanismChange,
            "Batched the lookups instead of issuing one per item"
        )
        var missingPlanOutput = plausibleOutput
        missingPlanOutput.removeValue(forKey: "plausibleRehearsalPlan")
        let missingPlanOutputData = try JSONSerialization.data(
            withJSONObject: missingPlanOutput
        )
        let missingPlanOutputText = try XCTUnwrap(
            String(data: missingPlanOutputData, encoding: .utf8)
        )
        var missingPlanResponse = response
        missingPlanResponse["output"] = [[
            "type": "message",
            "content": [[
                "type": "output_text",
                "text": missingPlanOutputText
            ]]
        ]]
        let missingPlanData = try JSONSerialization.data(
            withJSONObject: missingPlanResponse
        )
        XCTAssertThrowsError(
            try LiveAssistantClient.parseResponse(
                missingPlanData,
                allowedReferencePaths: ["Projects/Checkout.md"],
                basedOnSequence: 22,
                generationMilliseconds: 300,
                answerMode: .plausibleRehearsal
            )
        ) { error in
            XCTAssertEqual(error as? LiveAssistantError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try LiveAssistantClient.parseResponse(
                plausibleData,
                allowedReferencePaths: ["Projects/Checkout.md"],
                basedOnSequence: 22,
                generationMilliseconds: 300,
                answerMode: .grounded
            )
        ) { error in
            XCTAssertEqual(error as? LiveAssistantError, .invalidGrounding)
        }

        var hiddenOutput = generalOutput
        hiddenOutput["shouldShow"] = false
        let hiddenOutputData = try JSONSerialization.data(
            withJSONObject: hiddenOutput
        )
        let hiddenOutputText = try XCTUnwrap(
            String(data: hiddenOutputData, encoding: .utf8)
        )
        var hiddenResponse = response
        hiddenResponse["output"] = [[
            "type": "message",
            "content": [["type": "output_text", "text": hiddenOutputText]]
        ]]
        let hiddenData = try JSONSerialization.data(
            withJSONObject: hiddenResponse
        )
        let hiddenGeneration = try LiveAssistantClient.parseResponse(
            hiddenData,
            allowedReferencePaths: [],
            basedOnSequence: 20,
            generationMilliseconds: 270
        )
        XCTAssertNil(hiddenGeneration.suggestion)
        XCTAssertEqual(hiddenGeneration.outcome, .notAnswerable)

        let supportedWebURL = "https://webkit.org/blog/example/"
        var webOutput = output
        webOutput["grounding"] = "webSearch"
        webOutput["citations"] = [
            ["label": "WebKit Features", "path": supportedWebURL],
            ["label": "Unseen result", "path": "https://example.com/unseen"]
        ]
        let webOutputData = try JSONSerialization.data(withJSONObject: webOutput)
        let webOutputText = try XCTUnwrap(
            String(data: webOutputData, encoding: .utf8)
        )
        var webResponse = response
        webResponse["output"] = [
            [
                "type": "web_search_call",
                "action": [
                    "type": "search",
                    "sources": [[
                        "title": "Official WebKit Features",
                        "url": supportedWebURL
                    ]]
                ]
            ],
            [
                "type": "message",
                "content": [["type": "output_text", "text": webOutputText]]
            ]
        ]
        let webData = try JSONSerialization.data(withJSONObject: webResponse)
        let webGeneration = try LiveAssistantClient.parseResponse(
            webData,
            allowedReferencePaths: [],
            basedOnSequence: 21,
            generationMilliseconds: 410
        )
        XCTAssertEqual(webGeneration.suggestion?.grounding, .webSearch)
        XCTAssertEqual(
            webGeneration.suggestion?.citations,
            [
                CompanionCitation(
                    label: "Official WebKit Features",
                    path: supportedWebURL
                )
            ]
        )
        var unsupportedWebResponse = webResponse
        unsupportedWebResponse["output"] = [[
            "type": "message",
            "content": [["type": "output_text", "text": webOutputText]]
        ]]
        let unsupportedWebData = try JSONSerialization.data(
            withJSONObject: unsupportedWebResponse
        )
        XCTAssertThrowsError(
            try LiveAssistantClient.parseResponse(
                unsupportedWebData,
                allowedReferencePaths: [],
                basedOnSequence: 21,
                generationMilliseconds: 410
            )
        ) { error in
            XCTAssertEqual(error as? LiveAssistantError, .invalidGrounding)
        }

        var tooShortOutput = generalOutput
        let allBeats = try XCTUnwrap(
            output["beats"] as? [[String: String]]
        )
        tooShortOutput["beats"] = Array(allBeats.prefix(1))
        let tooShortData = try JSONSerialization.data(
            withJSONObject: tooShortOutput
        )
        let tooShortText = try XCTUnwrap(
            String(data: tooShortData, encoding: .utf8)
        )
        var tooShortResponse = response
        tooShortResponse["output"] = [[
            "type": "message",
            "content": [["type": "output_text", "text": tooShortText]]
        ]]
        let invalidData = try JSONSerialization.data(
            withJSONObject: tooShortResponse
        )
        XCTAssertThrowsError(
            try LiveAssistantClient.parseResponse(
                invalidData,
                allowedReferencePaths: [],
                basedOnSequence: 21,
                generationMilliseconds: 280
            )
        ) { error in
            XCTAssertEqual(error as? LiveAssistantError, .invalidResponse)
        }
    }

    func testSnapshotAndCommandRoutesUseTheRealProtocolModels() async throws {
        let hub = CompanionEventHub(streamID: "route-stream")
        let assets = CompanionAssetStore(
            rootURL: URL(fileURLWithPath: "Prototypes/LiveAssistant", isDirectory: true)
        )
        let router = CompanionGatewayRoutes.router(hub: hub, assets: assets)
        let app = Application(responder: router.buildResponder())

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/snapshot", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let snapshot = try CompanionJSON.decoder().decode(
                    CompanionSnapshot.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(snapshot.streamID, "route-stream")
                XCTAssertEqual(snapshot.watermark, 0)
            }

            let headerName = try XCTUnwrap(HTTPField.Name("idempotency-key"))
            let body = try CompanionJSON.encoder().encode(
                CompanionCommandRequest(
                    type: .pauseSuggestions,
                    suggestionID: nil
                )
            )
            try await client.execute(
                uri: "/v1/commands",
                method: .post,
                headers: [
                    headerName: "route-command",
                    .contentType: "application/json"
                ],
                body: ByteBuffer(bytes: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let result = try CompanionJSON.decoder().decode(
                    CompanionCommandResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertTrue(result.applied)
                XCTAssertEqual(result.watermark, 1)
            }
        }

        XCTAssertTrue(CompanionGatewayRoutes.isAllowedCompanionAuthority("localhost"))
        XCTAssertTrue(
            CompanionGatewayRoutes.isAllowedCompanionAuthority("127.0.0.1:4173")
        )
        XCTAssertTrue(
            CompanionGatewayRoutes.isAllowedCompanionAuthority("192.168.1.42:52119")
        )
        XCTAssertTrue(
            CompanionGatewayRoutes.isAllowedCompanionAuthority("[fe80::1]:4173")
        )
        XCTAssertFalse(
            CompanionGatewayRoutes.isAllowedCompanionAuthority("attacker.example:4173")
        )
        XCTAssertFalse(CompanionGatewayRoutes.isAllowedCompanionAuthority("localhost:0"))
    }

    func testGatewayEndpointPublishesTheSelectedPortForLANAndLoopback() {
        let endpoint = CompanionGatewayEndpoint(
            port: 52_119,
            lanAddresses: ["192.168.1.42", "10.0.0.8"]
        )

        XCTAssertEqual(endpoint.port, 52_119)
        XCTAssertEqual(endpoint.loopbackURL.absoluteString, "http://127.0.0.1:52119")
        XCTAssertEqual(
            endpoint.lanURLs.map(\.absoluteString),
            ["http://192.168.1.42:52119", "http://10.0.0.8:52119"]
        )
        XCTAssertEqual(
            endpoint.preferredLANURL?.absoluteString,
            "http://192.168.1.42:52119"
        )
    }

    func testGatewayFallsBackToAnAvailablePortWhenPreferredPortIsBusy() async throws {
        let firstGateway = CompanionGateway(preferredPort: 0)
        defer { firstGateway.stop() }
        let firstEndpoint = try await startedEndpoint(for: firstGateway)

        let secondGateway = CompanionGateway(preferredPort: firstEndpoint.port)
        defer { secondGateway.stop() }
        let secondEndpoint = try await startedEndpoint(for: secondGateway)

        XCTAssertNotEqual(secondEndpoint.port, firstEndpoint.port)
        XCTAssertGreaterThan(secondEndpoint.port, 0)
    }

    private func referenceSnapshot() -> ReferenceLibrarySnapshot {
        ReferenceLibrarySnapshot(
            folderURL: URL(
                fileURLWithPath: "/tmp/references",
                isDirectory: true
            ),
            documents: [
                ReferenceDocument(
                    relativePath: "Resume.md",
                    kind: .markdown,
                    content: "Built and measured low-latency audio systems.",
                    sourceByteCount: 45,
                    isTruncated: false
                )
            ],
            revision: "reference-revision",
            indexedAt: Date(timeIntervalSince1970: 100),
            ignoredFileCount: 0,
            issues: []
        )
    }

    private func answerSuggestion(
        id: String,
        sequence: Int,
        topicID: String? = nil
    ) -> CompanionAssistantSuggestion {
        CompanionAssistantSuggestion(
            id: id,
            basedOnSequence: sequence,
            question: "Question \(sequence)?",
            beats: [
                CompanionAnswerBeat(label: "Context", point: "Relevant setting"),
                CompanionAnswerBeat(label: "My move", point: "Specific action"),
                CompanionAnswerBeat(label: "Proof", point: "Measured result")
            ],
            citations: [],
            grounding: .generalKnowledge,
            confidence: .high,
            generatedAt: Date(timeIntervalSince1970: Double(sequence)),
            generationMilliseconds: 250,
            trigger: .partialTranscript,
            triggeredAt: Date(timeIntervalSince1970: Double(sequence)),
            totalLatencyMilliseconds: 1_050,
            topicID: topicID,
            topicNumber: nil
        )
    }

    private func syntheticInterviewResponseData(
        sourcePaths: [String] = ["Resume.md"]
    ) throws -> Data {
        let output: [String: Any] = [
            "title": "Audio systems interview",
            "exchanges": [
                [
                    "question": "What low-latency system did you build?",
                    "response": "I built an audio system and measured its latency end to end.",
                    "sourcePaths": sourcePaths
                ],
                [
                    "question": "How did you validate its performance?",
                    "response": "I separated the pipeline stages and measured each one independently.",
                    "sourcePaths": sourcePaths
                ],
                [
                    "question": "What tradeoff mattered most?",
                    "response": "I balanced response speed against stable, trustworthy output.",
                    "sourcePaths": sourcePaths
                ],
                [
                    "question": "Why can a high-occupancy CUDA kernel still be slow?",
                    "response": "I would inspect memory throughput and warp stalls before treating occupancy as the answer.",
                    "sourcePaths": sourcePaths
                ],
                [
                    "question": "What can go wrong when a CUDA tile gets larger?",
                    "response": "I would check shared-memory use, register spills, resident blocks, and bank conflicts.",
                    "sourcePaths": sourcePaths
                ]
            ]
        ]
        let outputData = try JSONSerialization.data(withJSONObject: output)
        let outputText = try XCTUnwrap(
            String(data: outputData, encoding: .utf8)
        )
        let response: [String: Any] = [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": outputText]]
            ]],
            "usage": [
                "input_tokens": 900,
                "input_tokens_details": [
                    "cached_tokens": 0,
                    "cache_write_tokens": 0
                ],
                "output_tokens": 180,
                "output_tokens_details": ["reasoning_tokens": 20]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func earlyBridgeResponseData(bridge: String) throws -> Data {
        let outputData = try JSONSerialization.data(
            withJSONObject: ["bridge": bridge]
        )
        let outputText = try XCTUnwrap(
            String(data: outputData, encoding: .utf8)
        )
        let response: [String: Any] = [
            "status": "completed",
            "service_tier": "priority",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": outputText]]
            ]],
            "usage": [
                "input_tokens": 132,
                "input_tokens_details": [
                    "cached_tokens": 0,
                    "cache_write_tokens": 0
                ],
                "output_tokens": 29,
                "output_tokens_details": ["reasoning_tokens": 0]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func nextEvent(
        from iterator: inout AsyncStream<CompanionStreamItem>.AsyncIterator
    ) async throws -> CompanionEvent {
        let item = await iterator.next()
        guard case let .event(event) = item else {
            throw XCTSkip("Expected a companion event")
        }
        return event
    }

    private func startedEndpoint(
        for gateway: CompanionGateway
    ) async throws -> CompanionGatewayEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            gateway.start(
                onReady: { continuation.resume(returning: $0) },
                onFailure: {
                    continuation.resume(
                        throwing: NSError(
                            domain: "CompanionGatewayTests",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: $0]
                        )
                    )
                }
            )
        }
    }
}

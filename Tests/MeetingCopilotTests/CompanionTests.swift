import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import XCTest
@testable import MeetingCopilot

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
            source: .syntheticInterview,
            title: "Reference-grounded interview",
            isPreparingSyntheticInterview: true
        )
        let snapshot = await hub.snapshot()

        XCTAssertFalse(snapshot.session.isListening)
        XCTAssertTrue(snapshot.session.isPreparingSyntheticInterview)
        XCTAssertEqual(snapshot.session.source, .syntheticInterview)
        XCTAssertEqual(snapshot.session.title, "Reference-grounded interview")
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
        XCTAssertEqual(snapshot.assistant.lastEvaluationOutcome, .noSuggestion)
        XCTAssertEqual(snapshot.assistant.lastEvaluationAt, completedAt)
        XCTAssertEqual(snapshot.assistant.lastEvaluationTrigger, .partialTranscript)
        XCTAssertEqual(snapshot.assistant.lastEvaluationLatencyMilliseconds, 1_700)
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
        XCTAssertTrue(AssistantEvaluationPolicy.shouldEvaluate(speaker: .other))
        XCTAssertFalse(AssistantEvaluationPolicy.shouldEvaluate(speaker: .you))
    }

    func testSyntheticInterviewGenerationUsesReferencesAndBuildsThreeExchanges() throws {
        let references = referenceSnapshot()
        let requestData = try SyntheticInterviewGeneratorClient.requestBody(
            references: references
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
        let text = try XCTUnwrap(request["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let exchanges = try XCTUnwrap(properties["exchanges"] as? [String: Any])
        XCTAssertEqual(exchanges["minItems"] as? Int, 3)
        XCTAssertEqual(exchanges["maxItems"] as? Int, 3)

        let generatedAt = Date(timeIntervalSince1970: 200)
        let generation = try SyntheticInterviewGeneratorClient.parseResponse(
            try syntheticInterviewResponseData(),
            references: references,
            generatedAt: generatedAt,
            generationMilliseconds: 640
        )
        let scenario = generation.scenario
        XCTAssertEqual(scenario.referenceRevision, references.revision)
        XCTAssertEqual(scenario.referenceDocumentCount, 1)
        XCTAssertEqual(scenario.generatedAt, generatedAt)
        XCTAssertEqual(scenario.finalizationDelay, 3)
        XCTAssertEqual(scenario.turns.count, 6)
        XCTAssertEqual(scenario.turns.map(\.speaker), [
            .other, .you, .other, .you, .other, .you
        ])
        XCTAssertGreaterThan(
            scenario.turns[0].pauseAfterSpeech,
            scenario.finalizationDelay
        )
        XCTAssertEqual(generation.usage.inputTokens, 900)
        XCTAssertEqual(generation.generationMilliseconds, 640)
    }

    func testSyntheticInterviewScenarioStoreMatchesReferenceRevision() throws {
        let generation = try SyntheticInterviewGeneratorClient.parseResponse(
            try syntheticInterviewResponseData(),
            references: referenceSnapshot(),
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
            try store.load(referenceRevision: "reference-revision"),
            generation.scenario
        )
        XCTAssertNil(try store.load(referenceRevision: "changed-revision"))
    }

    func testSyntheticInterviewRejectsUnknownReferencePaths() throws {
        XCTAssertThrowsError(
            try SyntheticInterviewGeneratorClient.parseResponse(
                try syntheticInterviewResponseData(
                    sourcePaths: ["Resume.md", "NotIndexed.md"]
                ),
                references: referenceSnapshot(),
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
                reasoningTokens: 32
            )
        )

        XCTAssertEqual(summary.assistantGenerations, 1)
        XCTAssertEqual(summary.assistantInputTokens, 2_000)
        XCTAssertEqual(summary.assistantCachedInputTokens, 1_200)
        XCTAssertEqual(summary.assistantCacheWriteTokens, 400)
        XCTAssertEqual(summary.assistantOutputTokens, 180)
        XCTAssertEqual(summary.assistantReasoningTokens, 32)
        XCTAssertEqual(summary.totalCostUSD, 0)
    }

    func testWingmanRequestUsesStructuredOutputAndExplicitCacheBoundary() throws {
        XCTAssertTrue(
            InterviewWingmanClient.behaviorInstructions.contains(
                "one coherent first-person answer"
            )
        )
        let plan = AssistantPromptPlan(
            cachedPrefix: "stable behavior and references",
            volatileSuffix: "Other: What did you build?",
            promptCacheKey: "punderclass:test"
        )
        let data = try InterviewWingmanClient.requestBody(for: plan)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(root["store"] as? Bool, false)
        XCTAssertEqual(root["max_output_tokens"] as? Int, 500)
        XCTAssertEqual(root["prompt_cache_key"] as? String, "punderclass:test")
        let reasoning = try XCTUnwrap(root["reasoning"] as? [String: String])
        XCTAssertEqual(reasoning["effort"], "none")

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
            ["localReferences", "generalKnowledge"]
        )
    }

    func testWingmanResponseParsesUsageAndRejectsUnknownCitationPaths() throws {
        let output: [String: Any] = [
            "shouldShow": true,
            "grounding": "localReferences",
            "question": "What did you improve?",
            "answer": "I traced the checkout path, removed an N+1 lookup, and validated a 41 percent p95 reduction under representative load.",
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
        let generation = try InterviewWingmanClient.parseResponse(
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
        XCTAssertTrue(
            generation.suggestion?.answer.contains("41 percent") == true
        )
        XCTAssertEqual(
            generation.suggestion?.citations,
            [CompanionCitation(label: "Project brief", path: "Projects/Checkout.md")]
        )

        let ungrounded = try InterviewWingmanClient.parseResponse(
            data,
            allowedReferencePaths: [],
            basedOnSequence: 19,
            generationMilliseconds: 320
        )
        XCTAssertNil(ungrounded.suggestion)

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
        let fallback = try InterviewWingmanClient.parseResponse(
            generalData,
            allowedReferencePaths: [],
            basedOnSequence: 20,
            generationMilliseconds: 280
        )

        XCTAssertEqual(fallback.suggestion?.basedOnSequence, 20)
        XCTAssertEqual(fallback.suggestion?.grounding, .generalKnowledge)
        XCTAssertEqual(fallback.suggestion?.citations, [])
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

        XCTAssertTrue(CompanionGatewayRoutes.isAllowedLoopbackAuthority("localhost"))
        XCTAssertTrue(
            CompanionGatewayRoutes.isAllowedLoopbackAuthority("127.0.0.1:4173")
        )
        XCTAssertFalse(
            CompanionGatewayRoutes.isAllowedLoopbackAuthority("attacker.example:4173")
        )
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

    private func syntheticInterviewResponseData(
        sourcePaths: [String] = ["Resume.md"]
    ) throws -> Data {
        let output: [String: Any] = [
            "title": "Audio systems interview",
            "exchanges": [
                [
                    "question": "What low-latency system did you build?",
                    "candidateAnswer": "I built an audio system and measured its latency end to end.",
                    "sourcePaths": sourcePaths
                ],
                [
                    "question": "How did you validate its performance?",
                    "candidateAnswer": "I separated the pipeline stages and measured each one independently.",
                    "sourcePaths": sourcePaths
                ],
                [
                    "question": "What tradeoff mattered most?",
                    "candidateAnswer": "I balanced response speed against stable, trustworthy output.",
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

    private func nextEvent(
        from iterator: inout AsyncStream<CompanionStreamItem>.AsyncIterator
    ) async throws -> CompanionEvent {
        let item = await iterator.next()
        guard case let .event(event) = item else {
            throw XCTSkip("Expected a companion event")
        }
        return event
    }
}

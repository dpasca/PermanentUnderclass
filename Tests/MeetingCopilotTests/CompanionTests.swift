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
        XCTAssertEqual(root["prompt_cache_key"] as? String, "punderclass:test")

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
    }

    func testWingmanResponseParsesUsageAndRejectsUnknownCitationPaths() throws {
        let output: [String: Any] = [
            "shouldShow": true,
            "question": "What did you improve?",
            "lead": "Use the checkout example",
            "talkingPoints": [
                ["title": "Stakes", "body": "Latency was hurting conversion."],
                ["title": "Action", "body": "I removed an N+1 lookup."],
                ["title": "Result", "body": "p95 fell by 41%."],
                ["title": "Extra", "body": "This fourth point is intentionally trimmed."]
            ],
            "proof": [["value": "41%", "label": "p95 reduction"]],
            "watchoutTitle": "Be precise about ownership",
            "watchoutBody": "You led diagnosis and rollout.",
            "followup": "How did you validate it?",
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
        XCTAssertEqual(generation.suggestion?.talkingPoints.count, 3)
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

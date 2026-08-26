import Foundation
import XCTest
@testable import PUnderclass

final class LiveAssistantClientRetryTests: XCTestCase {
    func testGenerateStopsAtTheSharedUsefulnessDeadline() async throws {
        let client = LiveAssistantClient { _, _ in
            try await Task.sleep(for: .seconds(1))
            return Data()
        }

        do {
            _ = try await client.generate(
                apiKey: "test-key",
                references: nil,
                recentTranscript: "",
                currentPartial: "",
                otherSpeakerText: "What did you change?",
                purpose: .interview,
                basedOnSequence: 40,
                usefulnessDeadline: ContinuousClock.now + .milliseconds(20)
            )
            XCTFail("Expected the live usefulness deadline to stop generation")
        } catch let error as LiveAssistantError {
            XCTAssertEqual(error, .usefulnessDeadlineExceeded)
        }
    }

    func testGroundingRepairSharesTheOriginalUsefulnessDeadline() async throws {
        let responses = LiveAssistantDelayedRepairQueue(
            firstResponse: try responseData(
                grounding: .localReferences,
                citations: [],
                inputTokens: 85,
                outputTokens: 20
            )
        )
        let client = LiveAssistantClient { apiKey, body in
            try await responses.load(apiKey: apiKey, body: body)
        }

        do {
            _ = try await client.generate(
                apiKey: "test-key",
                references: nil,
                recentTranscript: "",
                currentPartial: "",
                otherSpeakerText: "What did you change?",
                purpose: .interview,
                basedOnSequence: 40,
                usefulnessDeadline: ContinuousClock.now + .milliseconds(30)
            )
            XCTFail("Expected repair to stop at the original deadline")
        } catch let failure as LiveAssistantFailure {
            XCTAssertEqual(failure.cause, .usefulnessDeadlineExceeded)
            XCTAssertEqual(failure.usage.inputTokens, 85)
            XCTAssertEqual(failure.usage.groundingRepairAttempts, 1)
            XCTAssertEqual(failure.usage.groundingRepairSuccesses, 0)
        }
    }

    func testGenerateRepairsSpokenMetaCommentary() async throws {
        let responses = LiveAssistantResponseQueue(
            responses: [
                try responseData(
                    grounding: .generalKnowledge,
                    citations: [],
                    inputTokens: 110,
                    outputTokens: 28,
                    preamble: "I’d be careful not to invent a debugging story I can’t defend.",
                    spokenCueContainsMetaCommentary: true
                ),
                try responseData(
                    grounding: .generalKnowledge,
                    citations: [],
                    inputTokens: 125,
                    outputTokens: 32
                )
            ]
        )
        let client = LiveAssistantClient { apiKey, body in
            try await responses.load(apiKey: apiKey, body: body)
        }

        let generation = try await client.generate(
            apiKey: "test-key",
            references: nil,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: "Walk me through a concrete debugging session where rendering was wrong and how you isolated it.",
            purpose: .interview,
            basedOnSequence: 41
        )

        XCTAssertEqual(generation.outcome, .repairedGrounding)
        XCTAssertEqual(generation.usage.requestCount, 2)
        XCTAssertEqual(
            generation.suggestion?.preamble,
            "I’d start with synchronized CPU and GPU frame timings."
        )
        let requests = await responses.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let retry = try requestParts(from: requests[1].body)
        XCTAssertTrue(retry.userPrompt.contains("meta-commentary"))
        XCTAssertTrue(
            retry.userPrompt.contains(
                "spokenCueContainsMetaCommentary must be false"
            )
        )
    }

    func testGenerateCorrectsMismatchedGroundingInsteadOfDroppingAnswer() async throws {
        let responses = LiveAssistantResponseQueue(
            responses: [
                try responseData(
                    grounding: .localReferences,
                    citations: [],
                    inputTokens: 120,
                    outputTokens: 30
                ),
                try responseData(
                    grounding: .generalKnowledge,
                    citations: [],
                    inputTokens: 140,
                    outputTokens: 35
                )
            ]
        )
        let client = LiveAssistantClient { apiKey, body in
            try await responses.load(apiKey: apiKey, body: body)
        }
        let references = ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/references"),
            documents: [
                ReferenceDocument(
                    relativePath: "Projects/Renderer.md",
                    kind: .markdown,
                    content: "A renderer project used GPU profiling.",
                    sourceByteCount: 38,
                    isTruncated: false
                )
            ],
            revision: "test-revision",
            indexedAt: Date(timeIntervalSince1970: 100),
            ignoredFileCount: 0,
            issues: []
        )

        let generation = try await client.generate(
            apiKey: "test-key",
            references: references,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: "How would you distinguish a CPU bottleneck from a GPU bottleneck?",
            purpose: .interview,
            basedOnSequence: 42
        )

        XCTAssertEqual(generation.suggestion?.grounding, .generalKnowledge)
        XCTAssertEqual(generation.suggestion?.basedOnSequence, 42)
        XCTAssertEqual(generation.outcome, .repairedGrounding)
        XCTAssertEqual(generation.usage.inputTokens, 260)
        XCTAssertEqual(generation.usage.outputTokens, 65)
        XCTAssertEqual(generation.usage.requestCount, 2)
        XCTAssertEqual(generation.usage.groundingRepairAttempts, 1)
        XCTAssertEqual(generation.usage.groundingRepairSuccesses, 1)
        XCTAssertEqual(
            generation.suggestion?.inferenceOutcome,
            .repairedGrounding
        )
        XCTAssertEqual(
            generation.suggestion?.groundingRepairMilliseconds,
            generation.usage.groundingRepairMilliseconds
        )

        let requests = await responses.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.apiKey), ["test-key", "test-key"])
        let first = try requestParts(from: requests[0].body)
        let retry = try requestParts(from: requests[1].body)
        XCTAssertEqual(first.developerPrompt, retry.developerPrompt)
        XCTAssertEqual(first.cacheKey, retry.cacheKey)
        XCTAssertFalse(first.userPrompt.contains("GROUNDING CORRECTION"))
        XCTAssertTrue(retry.userPrompt.contains("GROUNDING CORRECTION"))
        XCTAssertTrue(retry.userPrompt.contains("Reassess shouldShow"))
    }

    func testGroundingCorrectionCanRestoreNotAnswerableDecision() async throws {
        let responses = LiveAssistantResponseQueue(
            responses: [
                try responseData(
                    grounding: .localReferences,
                    citations: [],
                    inputTokens: 90,
                    outputTokens: 20
                ),
                try responseData(
                    shouldShow: false,
                    grounding: .generalKnowledge,
                    citations: [],
                    inputTokens: 100,
                    outputTokens: 15
                )
            ]
        )
        let client = LiveAssistantClient { apiKey, body in
            try await responses.load(apiKey: apiKey, body: body)
        }

        let generation = try await client.generate(
            apiKey: "test-key",
            references: nil,
            recentTranscript: "",
            currentPartial: "Interviewer: And then, if the renderer maybe…",
            otherSpeakerText: "And then, if the renderer maybe…",
            purpose: .interview,
            basedOnSequence: 43,
            trigger: .partialTranscript
        )

        XCTAssertNil(generation.suggestion)
        XCTAssertEqual(generation.outcome, .notAnswerable)
        XCTAssertEqual(generation.usage.requestCount, 2)
        XCTAssertEqual(generation.usage.groundingRepairAttempts, 1)
        XCTAssertEqual(generation.usage.groundingRepairSuccesses, 1)
    }

    func testFailedGroundingRepairCarriesAttemptTelemetry() async throws {
        let responses = LiveAssistantResponseQueue(
            responses: [
                try responseData(
                    grounding: .localReferences,
                    citations: [],
                    inputTokens: 80,
                    outputTokens: 20
                ),
                try responseData(
                    grounding: .localReferences,
                    citations: [],
                    inputTokens: 90,
                    outputTokens: 25
                )
            ]
        )
        let client = LiveAssistantClient { apiKey, body in
            try await responses.load(apiKey: apiKey, body: body)
        }

        do {
            _ = try await client.generate(
                apiKey: "test-key",
                references: nil,
                recentTranscript: "",
                currentPartial: "",
                otherSpeakerText: "What would you profile first?",
                purpose: .interview,
                basedOnSequence: 44
            )
            XCTFail("Expected the second grounding mismatch to fail")
        } catch let failure as LiveAssistantFailure {
            XCTAssertEqual(failure.cause, .invalidGrounding)
            XCTAssertEqual(failure.usage.inputTokens, 170)
            XCTAssertEqual(failure.usage.outputTokens, 45)
            XCTAssertEqual(failure.usage.requestCount, 2)
            XCTAssertEqual(failure.usage.groundingRepairAttempts, 1)
            XCTAssertEqual(failure.usage.groundingRepairSuccesses, 0)
            XCTAssertGreaterThanOrEqual(
                failure.generationMilliseconds,
                failure.usage.groundingRepairMilliseconds
            )
        }
    }

    private func responseData(
        shouldShow: Bool = true,
        grounding: CompanionSuggestionGrounding,
        citations: [[String: String]],
        inputTokens: Int,
        outputTokens: Int,
        preamble: String = "I’d start with synchronized CPU and GPU frame timings.",
        spokenCueContainsMetaCommentary: Bool = false
    ) throws -> Data {
        let output: [String: Any] = [
            "shouldShow": shouldShow,
            "grounding": grounding.rawValue,
            "question": "How would you distinguish a CPU bottleneck from a GPU bottleneck?",
            "preamble": preamble,
            "beats": [
                [
                    "label": "CPU check",
                    "point": "I’d compare main-thread work against submitted GPU timestamps."
                ],
                [
                    "label": "Proof",
                    "point": "Then I’d reduce GPU load and watch which timing actually moves."
                ]
            ],
            "citations": citations,
            "confidence": "high",
            "usedExtrapolation": false,
            "plausibleAssumptions": [],
            "spokenCueContainsMetaCommentary":
                spokenCueContainsMetaCommentary
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
                "input_tokens": inputTokens,
                "input_tokens_details": [
                    "cached_tokens": 100,
                    "cache_write_tokens": 0
                ],
                "output_tokens": outputTokens,
                "output_tokens_details": ["reasoning_tokens": 0]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func requestParts(
        from data: Data
    ) throws -> (developerPrompt: String, userPrompt: String, cacheKey: String) {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        let developerContent = try XCTUnwrap(
            input[0]["content"] as? [[String: Any]]
        )
        let userContent = try XCTUnwrap(
            input[1]["content"] as? [[String: Any]]
        )
        return (
            developerPrompt: try XCTUnwrap(developerContent[0]["text"] as? String),
            userPrompt: try XCTUnwrap(userContent[0]["text"] as? String),
            cacheKey: try XCTUnwrap(root["prompt_cache_key"] as? String)
        )
    }
}

private enum LiveAssistantResponseQueueError: Error {
    case exhausted
}

private actor LiveAssistantResponseQueue {
    struct Request: Sendable {
        let apiKey: String
        let body: Data
    }

    private var responses: [Data]
    private var requests: [Request] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func load(apiKey: String, body: Data) throws -> Data {
        requests.append(Request(apiKey: apiKey, body: body))
        guard !responses.isEmpty else {
            throw LiveAssistantResponseQueueError.exhausted
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [Request] {
        requests
    }
}

private actor LiveAssistantDelayedRepairQueue {
    private let firstResponse: Data
    private var requestCount = 0

    init(firstResponse: Data) {
        self.firstResponse = firstResponse
    }

    func load(apiKey _: String, body _: Data) async throws -> Data {
        requestCount += 1
        if requestCount == 1 {
            return firstResponse
        }
        try await Task.sleep(for: .seconds(1))
        return Data()
    }
}

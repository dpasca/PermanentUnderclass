import Foundation
import XCTest
@testable import PUnderclass

final class LiveAssistantClientRetryTests: XCTestCase {
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
        XCTAssertEqual(generation.usage.inputTokens, 260)
        XCTAssertEqual(generation.usage.outputTokens, 65)

        let requests = await responses.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.apiKey), ["test-key", "test-key"])
        let first = try requestParts(from: requests[0].body)
        let retry = try requestParts(from: requests[1].body)
        XCTAssertEqual(first.developerPrompt, retry.developerPrompt)
        XCTAssertEqual(first.cacheKey, retry.cacheKey)
        XCTAssertFalse(first.userPrompt.contains("GROUNDING CORRECTION"))
        XCTAssertTrue(retry.userPrompt.contains("GROUNDING CORRECTION"))
        XCTAssertTrue(retry.userPrompt.contains("keep shouldShow true"))
    }

    private func responseData(
        grounding: CompanionSuggestionGrounding,
        citations: [[String: String]],
        inputTokens: Int,
        outputTokens: Int
    ) throws -> Data {
        let output: [String: Any] = [
            "shouldShow": true,
            "grounding": grounding.rawValue,
            "question": "How would you distinguish a CPU bottleneck from a GPU bottleneck?",
            "preamble": "I’d start with synchronized CPU and GPU frame timings.",
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

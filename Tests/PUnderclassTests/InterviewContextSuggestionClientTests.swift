import Foundation
import XCTest
@testable import PUnderclass

final class InterviewContextSuggestionClientTests: XCTestCase {
    func testHostedSuggestionFavorsRecentWorkWithoutInventingLanguage()
        async throws
    {
        guard
            ProcessInfo.processInfo.environment[
                "RUN_INTERVIEW_CONTEXT_SUGGESTION_EVAL"
            ] == "1"
        else {
            throw XCTSkip(
                "Set RUN_INTERVIEW_CONTEXT_SUGGESTION_EVAL=1 to run the hosted interview-description eval."
            )
        }
        let apiKey = try XCTUnwrap(
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        )
        let generation = try await InterviewContextSuggestionClient().suggest(
            apiKey: apiKey,
            resumeText: """
            Graphics engineer.

            1999: Investigated fixed-function compatibility for Final Fantasy VIII.

            2024–2026: Led rendering work on a Vulkan visualization product.
            Built render-graph scheduling, explicit synchronization, streaming
            scene buffers, GPU timing captures, and cross-platform developer tools.
            Worked closely with a small product and engineering team.
            """
        )
        let suggestion = try XCTUnwrap(generation.suggestion)

        XCTAssertTrue(
            suggestion.localizedCaseInsensitiveContains("Vulkan")
                || suggestion.localizedCaseInsensitiveContains("GPU")
                || suggestion.localizedCaseInsensitiveContains("rendering")
        )
        XCTAssertFalse(
            suggestion.localizedCaseInsensitiveContains("Final Fantasy")
        )
        XCTAssertFalse(
            suggestion.localizedCaseInsensitiveContains("English")
        )
        XCTAssertFalse(
            suggestion.localizedCaseInsensitiveContains("senior")
        )
        print(
            "INTERVIEW_CONTEXT_SUGGESTION_EVAL milliseconds=\(generation.generationMilliseconds) text=\(suggestion)"
        )
    }

    func testRequestUsesTerraLowReasoningAndStrictStructuredOutput() throws {
        let data = try InterviewContextSuggestionClient.requestBody(
            resumeText: """
            Graphics engineer, 2023–2026. Built a Vulkan renderer, GPU timing tools,
            and cross-platform visualization features with a small product team.
            """
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(root["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(root["store"] as? Bool, false)
        XCTAssertEqual(root["max_output_tokens"] as? Int, 750)
        XCTAssertEqual(
            (root["reasoning"] as? [String: String])?["effort"],
            "low"
        )

        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        let developerContent = try XCTUnwrap(
            input[0]["content"] as? [[String: Any]]
        )
        let instructions = try XCTUnwrap(
            developerContent[0]["text"] as? String
        )
        XCTAssertTrue(instructions.contains("untrusted source data"))
        XCTAssertTrue(instructions.contains("Spoken language is configured separately"))
        XCTAssertTrue(instructions.contains("Never state or infer"))
        XCTAssertFalse(instructions.contains("English-language"))

        let userContent = try XCTUnwrap(
            input[1]["content"] as? [[String: Any]]
        )
        let source = try XCTUnwrap(userContent[0]["text"] as? String)
        XCTAssertTrue(source.contains("Vulkan renderer"))

        let text = try XCTUnwrap(root["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    func testResponseParsesSpecificEditableDescriptionAndUsage() throws {
        let description =
            "A job interview likely to focus on recent graphics and systems engineering work. The interviewer may explore concrete decisions around a Vulkan renderer, GPU timing tools, cross-platform constraints, and collaboration within a small product team."
        let generation = try InterviewContextSuggestionClient.parseResponse(
            try response(canSuggest: true, description: description),
            generationMilliseconds: 418
        )

        XCTAssertEqual(generation.suggestion, description)
        XCTAssertEqual(generation.generationMilliseconds, 418)
        XCTAssertEqual(generation.usage.inputTokens, 240)
        XCTAssertEqual(generation.usage.cachedInputTokens, 20)
        XCTAssertEqual(generation.usage.outputTokens, 54)
        XCTAssertEqual(generation.usage.reasoningTokens, 12)
    }

    func testResponseCanKeepTheVisibleBasicDescription() throws {
        let generation = try InterviewContextSuggestionClient.parseResponse(
            try response(canSuggest: false, description: ""),
            generationMilliseconds: 100
        )

        XCTAssertNil(generation.suggestion)
    }

    func testResponseRejectsClaimedSuggestionWithoutUsefulDescription() throws {
        XCTAssertThrowsError(
            try InterviewContextSuggestionClient.parseResponse(
                try response(canSuggest: true, description: "A job interview."),
                generationMilliseconds: 100
            )
        ) { error in
            XCTAssertEqual(
                error as? InterviewContextSuggestionError,
                .invalidResponse
            )
        }
    }

    private func response(
        canSuggest: Bool,
        description: String
    ) throws -> Data {
        let outputData = try JSONSerialization.data(withJSONObject: [
            "canSuggest": canSuggest,
            "description": description
        ])
        let outputText = try XCTUnwrap(
            String(data: outputData, encoding: .utf8)
        )
        return try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [[
                    "type": "output_text",
                    "text": outputText
                ]]
            ]],
            "usage": [
                "input_tokens": 240,
                "input_tokens_details": [
                    "cached_tokens": 20
                ],
                "output_tokens": 54,
                "output_tokens_details": [
                    "reasoning_tokens": 12
                ]
            ]
        ])
    }
}

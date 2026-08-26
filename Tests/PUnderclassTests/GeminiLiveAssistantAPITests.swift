import Foundation
import XCTest
@testable import PUnderclass

final class GeminiLiveAssistantAPITests: XCTestCase {
    func testHostedGemini37FlashMediumThinkingAndSearchSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_GEMINI_LIVE_ASSISTANT_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set RUN_GEMINI_LIVE_ASSISTANT_SMOKE=1 to run the hosted Gemini smoke test."
            )
        }
        let apiKey = try XCTUnwrap(environment["GEMINI_API_KEY"])
        let generation = try await LiveAssistantClient.gemini().generate(
            apiKey: apiKey,
            references: nil,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: "Can you check Google's current documentation "
                + "and tell me whether Gemini 3.7 Flash supports high "
                + "thinking, structured output, and Google Search grounding?",
            sessionContext: "A model-selection meeting in August 2026.",
            purpose: .meeting,
            basedOnSequence: 1,
            webSearchMode: .required
        )

        let suggestion = try XCTUnwrap(generation.suggestion)
        XCTAssertEqual(suggestion.grounding, .webSearch)
        XCTAssertFalse(suggestion.citations.isEmpty)
        XCTAssertFalse(
            suggestion.googleSearchSuggestionsHTML?.isEmpty ?? true
        )
        XCTAssertGreaterThan(generation.usage.inputTokens, 0)
        XCTAssertGreaterThan(generation.usage.outputTokens, 0)
        XCTAssertNotNil(generation.latencyMilestones.firstEventMilliseconds)
        XCTAssertNotNil(
            generation.latencyMilestones.firstTextDeltaMilliseconds
        )
        print(
            "GEMINI_SMOKE model=gemini-3.7-flash thinking=medium first_event_ms=\(generation.latencyMilestones.firstEventMilliseconds ?? -1) first_text_ms=\(generation.latencyMilestones.firstTextDeltaMilliseconds ?? -1) generation_ms=\(generation.generationMilliseconds) input_tokens=\(generation.usage.inputTokens) cached_tokens=\(generation.usage.cachedInputTokens) output_tokens=\(generation.usage.outputTokens) thought_tokens=\(generation.usage.reasoningTokens) citations=\(suggestion.citations.count)"
        )
    }

    func testHostedGemini37FlashMediumThinkingUsesResumeWithoutSearch() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_GEMINI_LIVE_ASSISTANT_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set RUN_GEMINI_LIVE_ASSISTANT_SMOKE=1 to run the hosted Gemini smoke test."
            )
        }
        let apiKey = try XCTUnwrap(environment["GEMINI_API_KEY"])
        let resumeText = """
        Davide built a Metal renderer at Example Studio. To reduce CPU submission overhead, he batched draw calls by material and used indirect command buffers. On a fixed replay, CPU frame submission fell from 7 ms to 3 ms with matching rendered output.
        """
        let references = ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/gemini-resume-smoke"),
            documents: [
                ReferenceDocument(
                    relativePath: "resume.md",
                    kind: .markdown,
                    content: resumeText,
                    sourceByteCount: resumeText.utf8.count,
                    isTruncated: false
                )
            ],
            revision: "gemini-resume-smoke",
            indexedAt: Date(),
            ignoredFileCount: 0,
            issues: []
        )
        let generation = try await LiveAssistantClient.gemini().generate(
            apiKey: apiKey,
            references: references,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: "Tell me about a time you reduced CPU rendering overhead.",
            sessionContext: "A rendering-engineer interview.",
            purpose: .interview,
            basedOnSequence: 1,
            webSearchMode: .disabled
        )

        let suggestion = try XCTUnwrap(generation.suggestion)
        XCTAssertEqual(suggestion.grounding, .localReferences)
        XCTAssertEqual(suggestion.citations.map(\.path), ["resume.md"])
        XCTAssertNil(suggestion.googleSearchSuggestionsHTML)
        XCTAssertGreaterThan(generation.usage.inputTokens, 0)
        XCTAssertGreaterThan(generation.usage.outputTokens, 0)
        XCTAssertNotNil(generation.latencyMilestones.firstEventMilliseconds)
        XCTAssertNotNil(
            generation.latencyMilestones.firstTextDeltaMilliseconds
        )
        print(
            "GEMINI_NO_SEARCH_SMOKE model=gemini-3.7-flash thinking=medium first_event_ms=\(generation.latencyMilestones.firstEventMilliseconds ?? -1) first_text_ms=\(generation.latencyMilestones.firstTextDeltaMilliseconds ?? -1) generation_ms=\(generation.generationMilliseconds) input_tokens=\(generation.usage.inputTokens) cached_tokens=\(generation.usage.cachedInputTokens) output_tokens=\(generation.usage.outputTokens) thought_tokens=\(generation.usage.reasoningTokens) grounding=\(suggestion.grounding.rawValue) citations=\(suggestion.citations.count)"
        )
    }

    func testRequestUsesGemini37FlashWithMediumThinkingAndStructuredOutput()
        throws
    {
        let plan = AssistantPromptPlan(
            cachedPrefix: "Stable instructions and reference material",
            volatileSuffix: "Interviewer: What tradeoff did you make?",
            promptCacheKey: "punderclass:test"
        )

        let data = try GeminiLiveAssistantAPI.requestBody(
            for: plan,
            purpose: .interview
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(root["model"] as? String, "gemini-3.7-flash")
        XCTAssertEqual(root["store"] as? Bool, false)
        XCTAssertEqual(root["stream"] as? Bool, true)
        XCTAssertEqual(
            root["system_instruction"] as? String,
            plan.cachedPrefix
        )
        XCTAssertEqual(root["input"] as? String, plan.volatileSuffix)
        XCTAssertNil(root["temperature"])
        XCTAssertNil(root["top_p"])
        XCTAssertNil(root["top_k"])

        XCTAssertNil(root["tools"])

        let generationConfig = try XCTUnwrap(
            root["generation_config"] as? [String: Any]
        )
        XCTAssertEqual(generationConfig["thinking_level"] as? String, "medium")
        XCTAssertEqual(generationConfig["max_output_tokens"] as? Int, 2_048)
        XCTAssertNil(generationConfig["tool_choice"])

        let responseFormat = try XCTUnwrap(
            root["response_format"] as? [String: Any]
        )
        XCTAssertEqual(responseFormat["type"] as? String, "text")
        XCTAssertEqual(
            responseFormat["mime_type"] as? String,
            "application/json"
        )
        let schema = try XCTUnwrap(
            responseFormat["schema"] as? [String: Any]
        )
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(
            schema["properties"] as? [String: Any]
        )
        XCTAssertNotNil(properties["preamble"])
        XCTAssertNotNil(properties["beats"])
        XCTAssertNotNil(properties["citations"])
    }

    func testAutomaticMeetingSearchUsesGoogleSearchTool() throws {
        let plan = AssistantPromptPlan(
            cachedPrefix: "Stable instructions",
            volatileSuffix: "Other: What is the current release?",
            promptCacheKey: "punderclass:test"
        )

        let data = try GeminiLiveAssistantAPI.requestBody(
            for: plan,
            purpose: .meeting
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let tools = try XCTUnwrap(root["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "google_search")
        let generationConfig = try XCTUnwrap(
            root["generation_config"] as? [String: Any]
        )
        XCTAssertEqual(generationConfig["tool_choice"] as? String, "auto")
    }

    func testRequiredSearchUsesAnyToolChoiceAndLargerThinkingBudget() throws {
        let plan = AssistantPromptPlan(
            cachedPrefix: "Stable instructions",
            volatileSuffix: "Other: Verify the current release.",
            promptCacheKey: "punderclass:test"
        )

        let data = try GeminiLiveAssistantAPI.requestBody(
            for: plan,
            purpose: .meeting,
            webSearchMode: .required
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let generationConfig = try XCTUnwrap(
            root["generation_config"] as? [String: Any]
        )
        XCTAssertEqual(generationConfig["tool_choice"] as? String, "any")
        XCTAssertEqual(generationConfig["max_output_tokens"] as? Int, 4_096)

        let responseFormat = try XCTUnwrap(
            root["response_format"] as? [String: Any]
        )
        let schema = try XCTUnwrap(
            responseFormat["schema"] as? [String: Any]
        )
        let properties = try XCTUnwrap(
            schema["properties"] as? [String: Any]
        )
        XCTAssertNil(properties["preamble"])
        let beats = try XCTUnwrap(properties["beats"] as? [String: Any])
        XCTAssertEqual(beats["minItems"] as? Int, 3)
        XCTAssertEqual(beats["maxItems"] as? Int, 5)
    }

    func testResponseNormalizationPreservesUsageAndSearchGrounding() throws {
        let sourceURL = "https://example.com/releases/3.7"
        let assistantOutput: [String: Any] = [
            "shouldShow": true,
            "grounding": "webSearch",
            "question": "What changed in the current release?",
            "preamble": "The current release focuses on lower response latency.",
            "beats": [
                [
                    "label": "Change",
                    "point": "It shortens the model's time to a useful answer."
                ],
                [
                    "label": "Tradeoff",
                    "point": "High thinking can still use more output tokens."
                ]
            ],
            "citations": [
                ["label": "Release notes", "path": sourceURL]
            ],
            "confidence": "high",
            "usedExtrapolation": false,
            "plausibleAssumptions": [],
            "spokenCueContainsMetaCommentary": false
        ]
        let outputData = try JSONSerialization.data(
            withJSONObject: assistantOutput
        )
        let outputText = try XCTUnwrap(
            String(data: outputData, encoding: .utf8)
        )
        let response: [String: Any] = [
            "status": "completed",
            "steps": [
                [
                    "type": "google_search_call",
                    "id": "search-1",
                    "arguments": ["queries": ["Gemini 3.7 release"]]
                ],
                [
                    "type": "model_output",
                    "content": [[
                        "type": "text",
                        "text": "I should search before answering."
                    ]]
                ],
                [
                    "type": "google_search_result",
                    "call_id": "search-1",
                    "result": [[
                        "title": "Gemini 3.7 release notes",
                        "url": sourceURL,
                        "snippet": "Release information",
                        "search_suggestions":
                            "<a href='https://google.com/search'>"
                            + "Gemini release search</a>"
                    ]]
                ],
                [
                    "type": "model_output",
                    "content": [[
                        "type": "text",
                        "text": outputText,
                        "annotations": [[
                            "type": "url_citation",
                            "title": "Gemini 3.7 release notes",
                            "url": sourceURL,
                            "start_index": 0,
                            "end_index": 10
                        ]]
                    ]]
                ]
            ],
            "usage": [
                "total_input_tokens": 1_800,
                "total_cached_tokens": 1_100,
                "total_output_tokens": 145,
                "total_thought_tokens": 220
            ]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response)

        let normalized = try GeminiLiveAssistantAPI.normalizedResponse(
            responseData
        )
        let generation = try LiveAssistantClient.parseResponse(
            normalized,
            allowedReferencePaths: [],
            basedOnSequence: 71,
            generationMilliseconds: 410
        )

        XCTAssertEqual(generation.usage.inputTokens, 1_800)
        XCTAssertEqual(generation.usage.cachedInputTokens, 1_100)
        XCTAssertEqual(generation.usage.outputTokens, 145)
        XCTAssertEqual(generation.usage.reasoningTokens, 220)
        XCTAssertEqual(generation.suggestion?.basedOnSequence, 71)
        XCTAssertEqual(generation.suggestion?.grounding, .webSearch)
        XCTAssertEqual(
            generation.suggestion?.citations,
            [
                CompanionCitation(
                    label: "Gemini 3.7 release notes",
                    path: sourceURL
                )
            ]
        )
    }

    func testStructuredSearchAcceptsOnlyGoogleGroundingRedirects()
        throws
    {
        let groundingURL =
            "https://vertexaisearch.cloud.google.com/"
            + "grounding-api-redirect/provider-result"
        let searchSuggestions =
            "<style>body{margin:0}</style>"
            + "<a href='https://google.com/search?q=gemini'>"
            + "Gemini search</a>"
        let assistantOutput: [String: Any] = [
            "shouldShow": true,
            "grounding": "webSearch",
            "question": "Does the model support high thinking?",
            "beats": [
                [
                    "label": "Support",
                    "point": "The current model page lists high thinking."
                ],
                [
                    "label": "Format",
                    "point": "Gemini 3 supports structured output with tools."
                ],
                [
                    "label": "Search",
                    "point": "Google Search grounding is available in Interactions."
                ]
            ],
            "citations": [[
                "label": "Gemini model page",
                "path": groundingURL
            ]],
            "confidence": "high",
            "usedExtrapolation": false,
            "plausibleAssumptions": []
        ]
        let responseData = try structuredSearchResponse(
            assistantOutput: assistantOutput,
            searchSuggestions: searchSuggestions
        )

        let normalized = try GeminiLiveAssistantAPI.normalizedResponse(
            responseData
        )
        let generation = try LiveAssistantClient.parseResponse(
            normalized,
            allowedReferencePaths: [],
            basedOnSequence: 72,
            generationMilliseconds: 390,
            purpose: .meeting
        )

        XCTAssertEqual(
            generation.suggestion?.citations,
            [CompanionCitation(label: "Gemini model page", path: groundingURL)]
        )
        XCTAssertEqual(
            generation.suggestion?.googleSearchSuggestionsHTML,
            [searchSuggestions]
        )
    }

    func testStructuredSearchRejectsModelAuthoredArbitraryURL() throws {
        let assistantOutput: [String: Any] = [
            "shouldShow": true,
            "grounding": "webSearch",
            "question": "Does the model support high thinking?",
            "beats": [
                [
                    "label": "Support",
                    "point": "The current model page lists high thinking."
                ],
                [
                    "label": "Format",
                    "point": "Gemini 3 supports structured output with tools."
                ],
                [
                    "label": "Search",
                    "point": "Google Search grounding is available in Interactions."
                ]
            ],
            "citations": [[
                "label": "Unverified source",
                "path": "https://untrusted.example/model-authored"
            ]],
            "confidence": "high",
            "usedExtrapolation": false,
            "plausibleAssumptions": []
        ]
        let normalized = try GeminiLiveAssistantAPI.normalizedResponse(
            structuredSearchResponse(
                assistantOutput: assistantOutput,
                searchSuggestions:
                    "<a href='https://google.com/search'>Search</a>"
            )
        )

        XCTAssertThrowsError(
            try LiveAssistantClient.parseResponse(
                normalized,
                allowedReferencePaths: [],
                basedOnSequence: 73,
                generationMilliseconds: 390,
                purpose: .meeting
            )
        ) { error in
            XCTAssertEqual(error as? LiveAssistantError, .invalidGrounding)
        }
    }

    func testGeminiClientReportsDefaultAndCustomConfiguration() {
        let client = LiveAssistantClient.gemini()

        XCTAssertEqual(client.configuredModel, "gemini-3.7-flash")
        XCTAssertEqual(client.configuredReasoningEffort, .medium)

        let highClient = LiveAssistantClient.gemini(
            configuration: LiveAssistantConfiguration(
                model: "gemini-3.7-flash",
                reasoningEffort: .high,
                maximumOutputTokens: 4_096
            )
        )
        XCTAssertEqual(highClient.configuredModel, "gemini-3.7-flash")
        XCTAssertEqual(highClient.configuredReasoningEffort, .high)
    }

    func testAssistantProviderPreferenceDefaultsSafelyAndRestoresGemini() {
        let suiteName = "GeminiLiveAssistantAPITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            MeetingController.storedLiveAssistantProvider(defaults: defaults),
            .openAI
        )

        defaults.set(
            LiveAssistantProvider.gemini.rawValue,
            forKey: MeetingController.liveAssistantProviderDefaultsKey
        )
        XCTAssertEqual(
            MeetingController.storedLiveAssistantProvider(defaults: defaults),
            .gemini
        )
    }

    private func structuredSearchResponse(
        assistantOutput: [String: Any],
        searchSuggestions: String
    ) throws -> Data {
        let outputData = try JSONSerialization.data(
            withJSONObject: assistantOutput
        )
        let outputText = try XCTUnwrap(
            String(data: outputData, encoding: .utf8)
        )
        let response: [String: Any] = [
            "status": "completed",
            "steps": [
                [
                    "type": "google_search_call",
                    "id": "search-structured",
                    "arguments": ["queries": ["Gemini high thinking"]]
                ],
                [
                    "type": "google_search_result",
                    "call_id": "search-structured",
                    "result": [["search_suggestions": searchSuggestions]]
                ],
                [
                    "type": "model_output",
                    "content": [["type": "text", "text": outputText]]
                ]
            ],
            "usage": [
                "total_input_tokens": 1_200,
                "total_cached_tokens": 0,
                "total_output_tokens": 130,
                "total_thought_tokens": 180
            ]
        ]
        return try JSONSerialization.data(withJSONObject: response)
    }
}

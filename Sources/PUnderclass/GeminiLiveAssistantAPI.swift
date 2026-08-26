import Foundation

/// Direct Gemini Interactions API transport for the shared live-assistant
/// prompt, schema validation, grounding checks, and retry policy.
enum GeminiLiveAssistantAPI {
    static let endpoint = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/interactions"
    )!
    static let webSearchToolType = "google_search"

    static func requestBody(
        for plan: AssistantPromptPlan,
        purpose: CapturePurpose,
        webSearchMode: LiveAssistantWebSearchMode? = nil,
        answerMode: AssistantAnswerMode = .grounded,
        configuration: LiveAssistantConfiguration = .gemini37Flash
    ) throws -> Data {
        let resolvedWebSearchMode = webSearchMode
            ?? LiveAssistantWebSearchMode.defaultMode(for: purpose)
        let defaultMaximumOutputTokens: Int
        if resolvedWebSearchMode == .required
            || answerMode == .plausibleRehearsal
        {
            defaultMaximumOutputTokens = 4_096
        } else {
            defaultMaximumOutputTokens = 2_048
        }

        var generationConfiguration: [String: Any] = [
            "thinking_level": configuration.reasoningEffort.rawValue,
            "max_output_tokens": configuration.maximumOutputTokens
                ?? defaultMaximumOutputTokens
        ]
        var request: [String: Any] = [
            "model": configuration.model,
            "store": false,
            "system_instruction": plan.cachedPrefix,
            "input": plan.volatileSuffix,
            "generation_config": generationConfiguration,
            "response_format": [
                "type": "text",
                "mime_type": "application/json",
                "schema": LiveAssistantClient.outputSchema(
                    for: purpose,
                    answerMode: answerMode
                )
            ]
        ]
        if resolvedWebSearchMode != .disabled {
            generationConfiguration["tool_choice"] =
                resolvedWebSearchMode == .required ? "any" : "auto"
            request["generation_config"] = generationConfiguration
            request["tools"] = [["type": webSearchToolType]]
        }
        return try JSONSerialization.data(
            withJSONObject: request,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func responseData(
        session: URLSession,
        apiKey: String,
        body: Data
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveAssistantError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LiveAssistantError.requestFailed(errorMessage(from: data))
        }
        return data
    }

    /// Converts Gemini's interaction timeline into the internal Responses-style
    /// envelope consumed by the provider-independent assistant validator.
    static func normalizedResponse(_ data: Data) throws -> Data {
        guard
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw LiveAssistantError.invalidResponse
        }

        guard let status = root["status"] as? String else {
            throw LiveAssistantError.invalidResponse
        }
        if status == "incomplete" || status == "cancelled" {
            return try normalizedIncompleteResponse(
                root: root,
                status: status
            )
        }
        guard status == "completed" else {
            throw LiveAssistantError.requestFailed(
                interactionFailureMessage(from: root, status: status)
            )
        }

        let steps = root["steps"] as? [[String: Any]] ?? []
        let searchCallIDs = Set(
            steps.compactMap { step -> String? in
                guard step["type"] as? String == "google_search_call" else {
                    return nil
                }
                return step["id"] as? String
            }
        )
        var finalOutputText = ""
        var finalAnnotations: [[String: Any]] = []
        var webSources: [[String: Any]] = []
        var searchSuggestionsHTML: [String] = []
        var completedSearchCallIDs: Set<String> = []
        for step in steps {
            switch step["type"] as? String {
            case "model_output":
                var stepTexts: [String] = []
                var stepAnnotations: [[String: Any]] = []
                for content in step["content"] as? [[String: Any]] ?? []
                    where content["type"] as? String == "text"
                {
                    if let text = content["text"] as? String {
                        stepTexts.append(text)
                    }
                    for annotation in content["annotations"]
                        as? [[String: Any]] ?? []
                        where annotation["type"] as? String == "url_citation"
                    {
                        stepAnnotations.append(annotation)
                        webSources.append(annotation)
                    }
                }
                if !stepTexts.isEmpty {
                    // Interactions can contain several model steps around tool
                    // calls. Only the last model output is the final answer.
                    finalOutputText = stepTexts.joined()
                    finalAnnotations = stepAnnotations
                }
            case "google_search_result":
                let completedSuccessfully: Bool
                if
                    step["is_error"] as? Bool != true,
                    let callID = step["call_id"] as? String,
                    searchCallIDs.contains(callID)
                {
                    completedSuccessfully = true
                } else {
                    completedSuccessfully = false
                }
                if
                    completedSuccessfully,
                    let callID = step["call_id"] as? String
                {
                    completedSearchCallIDs.insert(callID)
                }
                guard completedSuccessfully else { continue }
                for result in step["result"] as? [[String: Any]] ?? [] {
                    if result["url"] as? String != nil {
                        webSources.append(result)
                    }
                    if
                        let html = result["search_suggestions"] as? String,
                        !html.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty,
                        !searchSuggestionsHTML.contains(html)
                    {
                        searchSuggestionsHTML.append(html)
                    }
                }
            default:
                continue
            }
        }

        guard !finalOutputText.isEmpty else {
            throw LiveAssistantError.invalidResponse
        }

        // Gemini currently omits text annotations when Google Search is
        // combined with JSON structured output. In that response shape, the
        // schema's citations contain Google-issued grounding redirects. Trust
        // those links only when the interaction timeline proves that a
        // matching server-side Google Search completed successfully.
        if !completedSearchCallIDs.isEmpty {
            webSources.append(
                contentsOf: structuredGroundingSources(
                    from: finalOutputText
                )
            )
        }

        var output: [[String: Any]] = []
        if !webSources.isEmpty {
            output.append([
                "type": "web_search_call",
                "action": ["sources": webSources]
            ])
        }
        var content: [String: Any] = [
            "type": "output_text",
            "text": finalOutputText
        ]
        if !finalAnnotations.isEmpty {
            content["annotations"] = finalAnnotations
        }
        output.append([
            "type": "message",
            "content": [content]
        ])

        let usage = root["usage"] as? [String: Any] ?? [:]
        var normalized: [String: Any] = [
            "status": "completed",
            "output": output,
            "usage": [
                "input_tokens": integer(usage["total_input_tokens"]),
                "input_tokens_details": [
                    "cached_tokens": integer(usage["total_cached_tokens"]),
                    "cache_write_tokens": 0
                ],
                "output_tokens": integer(usage["total_output_tokens"]),
                "output_tokens_details": [
                    "reasoning_tokens": integer(
                        usage["total_thought_tokens"]
                    )
                ]
            ]
        ]
        if !searchSuggestionsHTML.isEmpty {
            normalized["google_search_suggestions_html"] =
                searchSuggestionsHTML
        }
        if !completedSearchCallIDs.isEmpty {
            normalized["google_search_attribution_required"] = true
        }
        return try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func normalizedIncompleteResponse(
        root: [String: Any],
        status: String
    ) throws -> Data {
        let normalized: [String: Any] = [
            "status": "incomplete",
            "incomplete_details": [
                "reason": interactionFailureMessage(
                    from: root,
                    status: status
                )
            ]
        ]
        return try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func interactionFailureMessage(
        from root: [String: Any],
        status: String
    ) -> String {
        if
            let errors = root["errors"] as? [[String: Any]],
            let message = errors.compactMap({ $0["message"] as? String })
                .first(where: { !$0.isEmpty })
        {
            return message
        }
        if
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        {
            return message
        }
        return "Gemini interaction ended with status \(status)"
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return "HTTP response could not be read"
        }
        return message
    }

    private static func structuredGroundingSources(
        from outputText: String
    ) -> [[String: Any]] {
        guard
            let data = outputText.data(using: .utf8),
            let output = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return []
        }
        return (output["citations"] as? [[String: Any]] ?? []).compactMap {
            citation in
            guard
                let rawURL = citation["path"] as? String,
                isGoogleGroundingRedirect(rawURL)
            else {
                return nil
            }
            let label = (citation["label"] as? String ?? "Google Search source")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                "title": label.isEmpty ? "Google Search source" : label,
                "url": rawURL
            ]
        }
    }

    private static func isGoogleGroundingRedirect(
        _ rawURL: String
    ) -> Bool {
        guard
            let components = URLComponents(string: rawURL),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased()
                == "vertexaisearch.cloud.google.com",
            components.user == nil,
            components.password == nil,
            components.port == nil || components.port == 443,
            components.path.hasPrefix("/grounding-api-redirect/")
        else {
            return false
        }
        return true
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}

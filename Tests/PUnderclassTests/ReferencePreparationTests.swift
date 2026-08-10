import Foundation
import XCTest
@testable import PUnderclass

final class ReferencePreparationTests: XCTestCase {
    func testHostedPreparationBuildsRecentRoleSpecificCards() async throws {
        guard
            ProcessInfo.processInfo.environment[
                "RUN_REFERENCE_PREPARATION_EVAL"
            ] == "1"
        else {
            throw XCTSkip(
                "Set RUN_REFERENCE_PREPARATION_EVAL=1 to run the hosted preparation eval."
            )
        }
        let apiKey = try XCTUnwrap(
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        )
        let references = ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/hosted-preparation-eval"),
            documents: [
                ReferenceDocument(
                    relativePath: "Career/Profile.md",
                    kind: .markdown,
                    content: """
                    # Final Fantasy VIII compatibility work (1999)
                    Worked on an early fixed-function 3D compatibility path. Investigated DirectX-era state translation and visual differences on early consumer GPUs.

                    # Modern streaming renderer (2024–2026)
                    Led rendering work on a current Vulkan-based visualization product. Built render-graph scheduling, explicit synchronization, streaming scene buffers, and GPU-timestamp capture around upload, compute, and draw passes. The source does not record a particular optimization incident, diagnostic comparison, change, or result.
                    """,
                    sourceByteCount: 650,
                    isTruncated: false
                )
            ],
            revision: "hosted-local-r1",
            indexedAt: Date(),
            ignoredFileCount: 0,
            issues: []
        )

        let generation = try await ReferencePreparationClient().prepare(
            apiKey: apiKey,
            references: references,
            purpose: .interview,
            sessionContext:
                "Senior graphics engineer interview focused on modern rendering, performance debugging, Vulkan, and GPU systems.",
            localReferenceRevision: references.revision,
            webSourceRevision: "no-web-sources"
        )
        let recent = generation.pack.cards.filter {
            ($0.latestYear ?? 0) >= 2024
        }
        XCTAssertFalse(recent.isEmpty)
        XCTAssertTrue(
            recent.contains { !$0.concreteDetails.isEmpty && $0.roleRelevance >= 4 }
        )
        let chosen = PreparedReferenceSelector().select(
            from: generation.pack.cards,
            question:
                "Tell me about a concrete rendering optimization and how you verified it.",
            maximumCards: 1
        )
        XCTAssertGreaterThanOrEqual(chosen.first?.latestYear ?? 0, 2024)
        let question =
            "Tell me about a concrete rendering optimization and how you verified it."
        let preparedReferences = try XCTUnwrap(
            generation.pack.snapshot(
                for: question,
                folderURL: references.folderURL
            )
        )
        let answer = try await LiveAssistantClient().generate(
            apiKey: apiKey,
            references: preparedReferences,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: question,
            sessionContext:
                "Senior graphics engineer interview focused on modern rendering and GPU systems.",
            purpose: .interview,
            basedOnSequence: 1,
            answerMode: .plausibleRehearsal
        )
        let suggestion = try XCTUnwrap(answer.suggestion)
        let spokenCue = ([suggestion.preamble ?? ""]
            + suggestion.beats.map(\.point))
            .joined(separator: " ")
        XCTAssertTrue(
            suggestion.plausibleRehearsalPlan?.projectAnchor
                .localizedCaseInsensitiveContains("streaming") == true
                || spokenCue.localizedCaseInsensitiveContains("streaming")
        )
        XCTAssertFalse(
            spokenCue.localizedCaseInsensitiveContains("Final Fantasy")
        )
        XCTAssertFalse(suggestion.plausibleAssumptions.isEmpty)
        let plan = try XCTUnwrap(suggestion.plausibleRehearsalPlan)
        XCTAssertFalse(plan.observedSignal.isEmpty)
        XCTAssertFalse(plan.mechanismChange.isEmpty)
        XCTAssertFalse(plan.discriminatingCheck.isEmpty)
        XCTAssertFalse(plan.boundedOutcome.isEmpty)
        print(
            "REFERENCE_PREPARATION_EVAL preparation_ms=\(generation.generationMilliseconds) answer_ms=\(answer.generationMilliseconds) cards=\(generation.pack.cards.count) input_tokens=\(generation.usage.inputTokens) output_tokens=\(generation.usage.outputTokens) selected=\(chosen.first?.projectAnchor ?? "none")"
        )
        print("REFERENCE_PREPARATION_CUE \(spokenCue)")
    }

    func testJinaReaderNeedsNoKeyAndUsesBoundedMarkdownRequest() throws {
        let sourceURL = try XCTUnwrap(
            URL(string: "https://example.com/profile?view=full")
        )
        let request = try ReferenceWebContentClient.jinaRequest(for: sourceURL)

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://r.jina.ai/https://example.com/profile?view=full"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Respond-With"),
            "markdown"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Retain-Images"),
            "none"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Max-Tokens"),
            "12000"
        )
    }

    func testExaFallbackUsesContentsEndpointShapeAndParsesResult() throws {
        let requestData = try ReferenceWebContentClient.exaRequestBody(
            urls: ["https://example.com/profile"]
        )
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        XCTAssertEqual(
            request["urls"] as? [String],
            ["https://example.com/profile"]
        )
        XCTAssertEqual(request["text"] as? Bool, true)
        XCTAssertEqual(request["maxAgeHours"] as? Int, 24)

        let response = try JSONSerialization.data(withJSONObject: [
            "results": [[
                "title": "Example profile",
                "url": "https://example.com/profile/",
                "text": String(repeating: "Project details. ", count: 12)
            ]],
            "statuses": [[
                "id": "https://example.com/profile",
                "status": "success"
            ]]
        ])
        let fetchedAt = Date(timeIntervalSince1970: 123)
        let parsed = try ReferenceWebContentClient.parseExaResponse(
            response,
            requestedURL: "https://example.com/profile",
            fetchedAt: fetchedAt
        )
        XCTAssertEqual(parsed.provider, .exa)
        XCTAssertEqual(parsed.title, "Example profile")
        XCTAssertEqual(parsed.fetchedAt, fetchedAt)
        XCTAssertEqual(parsed.resolvedURL, "https://example.com/profile/")
    }

    func testPreparationRequestUsesTerraMediumAndStrictStructuredOutput()
        throws
    {
        let references = referenceSnapshot()
        let data = try ReferencePreparationClient.requestBody(
            references: references,
            purpose: .interview,
            sessionContext: "Senior graphics role working on modern renderers.",
            preparedAt: Date(timeIntervalSince1970: 100)
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(
            (root["reasoning"] as? [String: String])?["effort"],
            "medium"
        )
        XCTAssertEqual(root["store"] as? Bool, false)

        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        let prompt = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(prompt.contains("Senior graphics role"))
        XCTAssertTrue(prompt.contains("Projects/ModernRenderer.md"))
        XCTAssertTrue(prompt.contains("Recency matters"))

        let text = try XCTUnwrap(root["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    func testPreparationParsesGroundedCardsAndPreservesReviewChoice() throws {
        let references = referenceSnapshot()
        let candidate = outputCard(
            project: "Modern Renderer",
            period: "2024–2026",
            year: 2026,
            paths: ["Projects/ModernRenderer.md"]
        )
        let id = ReferencePreparationDigest.cardID(
            projectAnchor: "Modern Renderer",
            period: "2024–2026",
            sourcePaths: ["Projects/ModernRenderer.md"]
        )
        let previous = PreparedReferenceCard(
            id: id,
            projectAnchor: "Modern Renderer",
            period: "2024–2026",
            latestYear: 2026,
            role: "Graphics engineer",
            summary: "Previous summary",
            concreteDetails: ["Previous detail"],
            interviewUses: ["rendering architecture"],
            sourcePaths: ["Projects/ModernRenderer.md"],
            roleRelevance: 5,
            isEnabled: false
        )

        let generation = try ReferencePreparationClient.parseResponse(
            try openAIResponse(cards: [candidate]),
            references: references,
            purpose: .interview,
            sessionContext: "Modern graphics role",
            localReferenceRevision: "local-r1",
            webSourceRevision: "web-r1",
            previousCards: [previous],
            preparedAt: Date(timeIntervalSince1970: 200),
            generationMilliseconds: 1_234
        )

        XCTAssertEqual(generation.pack.cards.count, 1)
        XCTAssertEqual(generation.pack.cards[0].id, id)
        XCTAssertFalse(generation.pack.cards[0].isEnabled)
        XCTAssertEqual(generation.pack.localReferenceRevision, "local-r1")
        XCTAssertEqual(generation.pack.webSourceRevision, "web-r1")
        XCTAssertEqual(generation.usage.inputTokens, 800)
        XCTAssertEqual(generation.generationMilliseconds, 1_234)
    }

    func testPreparationRejectsInventedSourcePath() throws {
        let references = referenceSnapshot()
        let candidate = outputCard(
            project: "Unknown project",
            period: "2026",
            year: 2026,
            paths: ["not-supplied.example"]
        )

        XCTAssertThrowsError(
            try ReferencePreparationClient.parseResponse(
                try openAIResponse(cards: [candidate]),
                references: references,
                purpose: .interview,
                sessionContext: "Graphics role",
                localReferenceRevision: "local-r1",
                webSourceRevision: "web-r1",
                previousCards: [],
                preparedAt: Date(),
                generationMilliseconds: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? ReferencePreparationError,
                .invalidGrounding
            )
        }
    }

    func testPreparationRejectsCardWithoutInterviewUses() throws {
        let references = referenceSnapshot()
        var candidate = outputCard(
            project: "Modern Renderer",
            period: "2024–2026",
            year: 2026,
            paths: ["Projects/ModernRenderer.md"]
        )
        candidate["interviewUses"] = ["  "]

        XCTAssertThrowsError(
            try ReferencePreparationClient.parseResponse(
                try openAIResponse(cards: [candidate]),
                references: references,
                purpose: .interview,
                sessionContext: "Graphics role",
                localReferenceRevision: "local-r1",
                webSourceRevision: "web-r1",
                previousCards: [],
                preparedAt: Date(),
                generationMilliseconds: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? ReferencePreparationError,
                .invalidGrounding
            )
        }
    }

    func testSemanticSelectionPrefersRecentComparableWorkButKeepsUniqueOldWork() {
        let recent = card(
            id: "recent",
            project: "Current renderer",
            year: 2025
        )
        let old = card(
            id: "old",
            project: "Legacy graphics title",
            year: 1999
        )

        let comparableSelector = PreparedReferenceSelector(
            currentYear: 2026,
            semanticDistance: { _, text in
                text.contains("Legacy") ? 0.30 : 0.34
            }
        )
        XCTAssertEqual(
            comparableSelector.select(
                from: [old, recent],
                question: "Tell me about a rendering optimization.",
                maximumCards: 1
            ).map(\.id),
            ["recent"]
        )

        let uniqueSelector = PreparedReferenceSelector(
            currentYear: 2026,
            semanticDistance: { _, text in
                text.contains("Legacy") ? 0.05 : 0.65
            }
        )
        XCTAssertEqual(
            uniqueSelector.select(
                from: [old, recent],
                question: "Tell me about a fixed-function compatibility bug.",
                maximumCards: 1
            ).map(\.id),
            ["old"]
        )
    }

    func testPreparedSnapshotIncludesOnlyEnabledSelectedCardsWithProvenance()
        throws
    {
        var disabled = card(id: "disabled", project: "Disabled", year: 2026)
        disabled.isEnabled = false
        let included = card(id: "included", project: "Included", year: 2025)
        let pack = PreparedReferencePack(
            purpose: .interview,
            localReferenceRevision: "local",
            webSourceRevision: "web",
            sessionContext: "Graphics role",
            preparedAt: Date(timeIntervalSince1970: 300),
            cards: [disabled, included]
        )
        let selector = PreparedReferenceSelector(
            semanticDistance: { _, _ in 0.2 }
        )
        let snapshot = try XCTUnwrap(
            pack.snapshot(
                for: "Rendering question",
                folderURL: nil,
                maximumCards: 8,
                selector: selector
            )
        )

        XCTAssertEqual(snapshot.documents.map(\.relativePath), ["included.md"])
        XCTAssertTrue(snapshot.documents[0].content.contains("Included"))
        XCTAssertFalse(snapshot.documents[0].content.contains("Disabled"))
    }

    func testPreparationStoreRoundTripsSourcesPackAndReviewState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let store = ReferencePreparationStore(
            fileURL: root.appendingPathComponent("ReferencePreparation.json")
        )
        var source = ReferenceWebSource(
            url: try XCTUnwrap(URL(string: "https://example.com/profile")),
            id: "source-1"
        )
        source.status = .ready
        source.provider = .jinaReader
        source.content = String(repeating: "Details ", count: 20)
        var state = ReferencePreparationState()
        state.webSources = [source]
        state.pack = PreparedReferencePack(
            purpose: .interview,
            localReferenceRevision: "local",
            webSourceRevision: "web",
            sessionContext: "Graphics role",
            preparedAt: Date(timeIntervalSince1970: 400),
            cards: [card(id: "card-1", project: "Project", year: 2025)]
        )
        state.phase = .ready

        try store.save(ReferencePreparationArchive(state: state))
        let restored = ReferencePreparationState(archive: try store.load())

        XCTAssertEqual(restored.webSources, state.webSources)
        XCTAssertEqual(restored.pack, state.pack)
        XCTAssertEqual(restored.phase, .ready)
    }

    private func referenceSnapshot() -> ReferenceLibrarySnapshot {
        ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/references"),
            documents: [
                ReferenceDocument(
                    relativePath: "Projects/ModernRenderer.md",
                    kind: .markdown,
                    content:
                        "Built a modern renderer in 2024 through 2026 with explicit synchronization and GPU timing captures.",
                    sourceByteCount: 98,
                    isTruncated: false
                )
            ],
            revision: "combined-r1",
            indexedAt: Date(timeIntervalSince1970: 50),
            ignoredFileCount: 0,
            issues: []
        )
    }

    private func card(
        id: String,
        project: String,
        year: Int
    ) -> PreparedReferenceCard {
        PreparedReferenceCard(
            id: id,
            projectAnchor: project,
            period: String(year),
            latestYear: year,
            role: "Graphics engineer",
            summary: "Worked on a rendering system.",
            concreteDetails: ["Used GPU timing captures to inspect frame cost."],
            interviewUses: ["rendering optimization and debugging"],
            sourcePaths: ["\(id).md"],
            roleRelevance: 5,
            isEnabled: true
        )
    }

    private func outputCard(
        project: String,
        period: String,
        year: Int,
        paths: [String]
    ) -> [String: Any] {
        [
            "projectAnchor": project,
            "period": period,
            "latestYear": year,
            "role": "Graphics engineer",
            "summary": "Built a renderer with explicit synchronization.",
            "concreteDetails": [
                "Captured CPU and GPU timings around frame submission."
            ],
            "interviewUses": ["rendering architecture", "performance debugging"],
            "sourcePaths": paths,
            "roleRelevance": 5
        ]
    }

    private func openAIResponse(cards: [[String: Any]]) throws -> Data {
        let outputData = try JSONSerialization.data(
            withJSONObject: ["cards": cards],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
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
                "input_tokens": 800,
                "input_tokens_details": ["cached_tokens": 0],
                "output_tokens": 240,
                "output_tokens_details": ["reasoning_tokens": 80]
            ]
        ])
    }
}

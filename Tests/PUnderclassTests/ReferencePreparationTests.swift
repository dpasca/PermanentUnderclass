import Foundation
import XCTest
@testable import PUnderclass

final class ReferencePreparationTests: XCTestCase {
    func testPrivatePreparedArchiveRetrievalTiming() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_PRIVATE_PREPARED_RETRIEVAL_EVAL"] == "1" else {
            throw XCTSkip(
                "Set RUN_PRIVATE_PREPARED_RETRIEVAL_EVAL=1 and REFERENCE_PREPARATION_ARCHIVE_PATH to run the private retrieval timing eval."
            )
        }
        let archivePath = try XCTUnwrap(
            environment["REFERENCE_PREPARATION_ARCHIVE_PATH"]
        )
        let archive = try JSONDecoder().decode(
            ReferencePreparationArchive.self,
            from: Data(contentsOf: URL(fileURLWithPath: archivePath))
        )
        let sourceCards = try XCTUnwrap(archive.pack?.cards)
        XCTAssertFalse(sourceCards.isEmpty)

        let embeddingStarted = DispatchTime.now().uptimeNanoseconds
        let cards = sourceCards.map { card in
            PreparedReferenceCard(
                id: card.id,
                projectAnchor: card.projectAnchor,
                period: card.period,
                latestYear: card.latestYear,
                role: card.role,
                summary: card.summary,
                concreteDetails: card.concreteDetails,
                interviewUses: card.interviewUses,
                sourcePaths: card.sourcePaths,
                roleRelevance: card.roleRelevance,
                semanticVector: PreparedReferenceEmbedding.vector(
                    for: card.semanticText
                ),
                isEnabled: card.isEnabled
            )
        }
        let embeddingMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - embeddingStarted
        ) / 1_000_000

        let questions = [
            "Tell me about a concrete rendering optimization and how you verified it.",
            "Walk me through a recent project that best represents your current work.",
            "Tell me about a DirectX graphics compatibility problem you solved."
        ]
        let selector = PreparedReferenceSelector()
        for question in questions {
            var samples: [Double] = []
            var selected: [PreparedReferenceCard] = []
            for _ in 0..<25 {
                let started = DispatchTime.now().uptimeNanoseconds
                selected = selector.select(
                    from: cards,
                    question: question,
                    maximumCards: 8
                )
                samples.append(
                    Double(DispatchTime.now().uptimeNanoseconds - started)
                        / 1_000_000
                )
            }
            XCTAssertFalse(selected.isEmpty)
            samples.sort()
            let selectedSummary = selected.map {
                "\($0.projectAnchor) [\($0.latestYear.map(String.init) ?? "unknown")]"
            }.joined(separator: " | ")
            let questionVector = PreparedReferenceEmbedding.vector(
                for: question
            )
            let semanticSummary = cards.compactMap { card -> (String, Double)? in
                guard
                    let questionVector,
                    let cardVector = card.semanticVector,
                    let distance = PreparedReferenceEmbedding.cosineDistance(
                        questionVector,
                        cardVector
                    )
                else {
                    return nil
                }
                return (card.projectAnchor, distance)
            }.sorted { $0.1 < $1.1 }.map {
                "\($0.0)=\(String(format: "%.3f", $0.1))"
            }.joined(separator: " | ")
            print(
                "PRIVATE_PREPARED_RETRIEVAL question=\(question) median_ms=\(String(format: "%.3f", samples[samples.count / 2])) max_ms=\(String(format: "%.3f", samples.last ?? 0)) selected=\(selectedSummary) semantic=\(semanticSummary)"
            )
        }
        print(
            "PRIVATE_PREPARED_EMBEDDING cards=\(cards.count) total_ms=\(String(format: "%.1f", embeddingMilliseconds))"
        )
    }

    func testPrivateSourceResolutionAndPreparationTiming() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_PRIVATE_SOURCE_PREPARATION_EVAL"] == "1" else {
            throw XCTSkip(
                "Set RUN_PRIVATE_SOURCE_PREPARATION_EVAL=1 plus the private folder, resume, and archive paths to run this hosted eval."
            )
        }
        let apiKey = try XCTUnwrap(environment["OPENAI_API_KEY"])
        let folderPath = try XCTUnwrap(
            environment["REFERENCE_PREPARATION_PRIVATE_FOLDER"]
        )
        let resumePath = try XCTUnwrap(
            environment["REFERENCE_PREPARATION_PRIVATE_RESUME"]
        )
        let archivePath = try XCTUnwrap(
            environment["REFERENCE_PREPARATION_ARCHIVE_PATH"]
        )
        let local = try ReferenceLibraryScanner().scan(
            folderURL: URL(fileURLWithPath: folderPath, isDirectory: true)
        )
        let resumeURL = URL(fileURLWithPath: resumePath)
        let resumeCitationPath = "Selected Resume/\(resumeURL.lastPathComponent)"
        let resume = try ReferenceLibraryScanner().loadDocument(
            fileURL: resumeURL,
            relativePath: resumeCitationPath
        )
        let archive = try JSONDecoder().decode(
            ReferencePreparationArchive.self,
            from: Data(contentsOf: URL(fileURLWithPath: archivePath))
        )
        let combined = try ReferencePreparationClient.combinedReferences(
            localReferences: local,
            explicitResume: resume,
            webSources: archive.webSources
        )
        let resumeSource = ReferenceResumeSource(
            filePath: resumeURL.path,
            citationPath: resumeCitationPath,
            contentDigest: ReferencePreparationDigest.hash([resume.content]),
            sourceByteCount: resume.sourceByteCount
        )
        let sessionContext = environment[
            "REFERENCE_PREPARATION_PRIVATE_CONTEXT"
        ] ?? "Senior GPU and graphics engineering interview focused on modern CUDA, rendering, performance debugging, and systems work."

        let generation = try await ReferencePreparationClient().prepare(
            apiKey: apiKey,
            references: combined,
            purpose: .interview,
            sessionContext: sessionContext,
            localReferenceRevision: ReferencePreparationDigest.localSourceRevision(
                folderRevision: local.revision,
                resumeSource: resumeSource
            ),
            webSourceRevision: ReferencePreparationDigest.webSourceRevision(
                archive.webSources
            ),
            explicitResumePath: resumeCitationPath
        )
        let manifest = try XCTUnwrap(generation.pack.sourceManifest)
        XCTAssertEqual(manifest.canonicalResumePath, resumeCitationPath)
        XCTAssertFalse(manifest.requiresReview)
        XCTAssertTrue(
            generation.pack.cards.allSatisfy {
                $0.sourcePaths.allSatisfy(
                    manifest.factualSourcePaths.contains
                )
            }
        )

        let sourceSummary = manifest.sources.map {
            "\($0.path)=\($0.kind.rawValue)/\($0.use.rawValue)"
        }.joined(separator: " | ")
        print(
            "PRIVATE_SOURCE_PREPARATION preparation_ms=\(generation.generationMilliseconds) documents=\(combined.documents.count) cards=\(generation.pack.cards.count) sources=\(sourceSummary)"
        )
        for question in [
            "Tell me about a concrete rendering optimization and how you verified it.",
            "Walk me through a recent project that best represents your current work.",
            "Tell me about a DirectX graphics compatibility problem you solved."
        ] {
            let selected = PreparedReferenceSelector().select(
                from: generation.pack.cards,
                question: question,
                maximumCards: 8
            )
            print(
                "PRIVATE_SOURCE_SELECTION question=\(question) selected=\(selected.map { "\($0.projectAnchor) [\($0.latestYear.map(String.init) ?? "unknown")]" }.joined(separator: " | "))"
            )
        }
    }

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
                    relativePath: "Selected Resume/current-resume.md",
                    kind: .markdown,
                    content: """
                    # Current resume, updated 2026

                    ## Final Fantasy VIII compatibility work (1999)
                    Worked on an early fixed-function 3D compatibility path. Investigated DirectX-era state translation and visual differences on early consumer GPUs.

                    ## Modern streaming renderer (2024–2026)
                    Led rendering work on a current Vulkan-based visualization product. Built render-graph scheduling, explicit synchronization, streaming scene buffers, and GPU-timestamp capture around upload, compute, and draw passes. The source does not record a particular optimization incident, diagnostic comparison, change, or result.
                    """,
                    sourceByteCount: 650,
                    isTruncated: false
                ),
                ReferenceDocument(
                    relativePath: "Archive/resume-draft-2022.md",
                    kind: .markdown,
                    content: """
                    # Resume draft, last updated 2022
                    Graphics programmer. Final Fantasy VIII compatibility work (1999): investigated early DirectX state translation and visual differences on consumer GPUs.
                    """,
                    sourceByteCount: 180,
                    isTruncated: false
                ),
                ReferenceDocument(
                    relativePath: "Interview/sample-answers.md",
                    kind: .markdown,
                    content: """
                    # Interview rehearsal notes
                    Hypothetical example only: say that upload batching improved frame time by 42 percent after a profiler comparison. This is a practice answer, not a record of work performed.
                    """,
                    sourceByteCount: 190,
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
            webSourceRevision: "no-web-sources",
            explicitResumePath: "Selected Resume/current-resume.md"
        )
        XCTAssertEqual(
            generation.pack.sourceManifest?.canonicalResumePath,
            "Selected Resume/current-resume.md"
        )
        XCTAssertFalse(
            generation.pack.sourceManifest?.requiresReview ?? true
        )
        XCTAssertEqual(
            generation.pack.sourceManifest?.sources.first(where: {
                $0.path == "Interview/sample-answers.md"
            })?.use,
            .contextOnly
        )
        XCTAssertFalse(
            generation.pack.cards.contains {
                $0.sourcePaths.contains("Interview/sample-answers.md")
                    || $0.sourcePaths.contains("Archive/resume-draft-2022.md")
            }
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
            explicitResumePath: "Projects/ModernRenderer.md",
            preparedAt: Date(timeIntervalSince1970: 100)
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(root["max_output_tokens"] as? Int, 12_000)
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
        XCTAssertTrue(prompt.contains("isExplicitResume"))
        XCTAssertTrue(prompt.contains("contextOnly"))

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
        XCTAssertEqual(
            generation.pack.sourceManifest?.sources.first?.use,
            .factualSupplement
        )
        XCTAssertNotNil(generation.pack.cards[0].semanticVector)
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

    func testPreparationDeconflictsResumeDraftsAndPreparationNotes() throws {
        let references = ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/deconflict"),
            documents: [
                document(
                    path: "Selected Resume/current.pdf",
                    content: "Current resume covering work through 2026."
                ),
                document(
                    path: "Archive/alternate-resume.md",
                    content: "An older resume draft covering work through 2022."
                ),
                document(
                    path: "Interview/answers.md",
                    content: "Ideas and hypothetical examples for an interview."
                )
            ],
            revision: "deconflict-r1",
            indexedAt: Date(),
            ignoredFileCount: 0,
            issues: []
        )
        let manifest: [String: Any] = [
            "canonicalResumePath": "Selected Resume/current.pdf",
            "requiresReview": false,
            "resolutionSummary":
                "The explicitly selected current resume is authoritative; the older draft and notes are context only.",
            "sources": [[
                "path": "Selected Resume/current.pdf",
                "title": "Current resume",
                "kind": "resume",
                "use": "primaryResume",
                "confidence": 0.99,
                "rationale": "It is the explicitly selected complete resume.",
                "conflictsWith": ["Archive/alternate-resume.md"],
                "conflictSummary": "The alternate draft ends in 2022."
            ], [
                "path": "Archive/alternate-resume.md",
                "title": "Older resume draft",
                "kind": "resume",
                "use": "contextOnly",
                "confidence": 0.97,
                "rationale": "It is an older, incomplete resume version.",
                "conflictsWith": ["Selected Resume/current.pdf"],
                "conflictSummary": "It omits the candidate's later work."
            ], [
                "path": "Interview/answers.md",
                "title": "Interview answer notes",
                "kind": "interviewPreparation",
                "use": "contextOnly",
                "confidence": 0.98,
                "rationale": "It contains rehearsal material, not career evidence.",
                "conflictsWith": [],
                "conflictSummary": ""
            ]]
        ]
        let candidate = outputCard(
            project: "Current project",
            period: "2024–2026",
            year: 2026,
            paths: ["Selected Resume/current.pdf"]
        )

        let generation = try ReferencePreparationClient.parseResponse(
            try openAIResponse(cards: [candidate], sourceManifest: manifest),
            references: references,
            purpose: .interview,
            sessionContext: "Graphics role",
            localReferenceRevision: "local-r1",
            webSourceRevision: "web-r1",
            explicitResumePath: "Selected Resume/current.pdf",
            previousCards: [],
            preparedAt: Date(),
            generationMilliseconds: 10
        )

        XCTAssertEqual(
            generation.pack.sourceManifest?.canonicalResumePath,
            "Selected Resume/current.pdf"
        )
        XCTAssertEqual(
            generation.pack.sourceManifest?.sources.first(where: {
                $0.path == "Interview/answers.md"
            })?.use,
            .contextOnly
        )
        XCTAssertEqual(
            generation.pack.cards.flatMap(\.sourcePaths),
            ["Selected Resume/current.pdf"]
        )
    }

    func testPreparationRejectsCandidateFactsFromContextOnlySource() throws {
        let references = referenceSnapshot()
        let manifest: [String: Any] = [
            "canonicalResumePath": NSNull(),
            "requiresReview": false,
            "resolutionSummary": "Only interview preparation was supplied.",
            "sources": [[
                "path": "Projects/ModernRenderer.md",
                "title": "Interview notes",
                "kind": "interviewPreparation",
                "use": "contextOnly",
                "confidence": 0.95,
                "rationale": "The text is rehearsal material.",
                "conflictsWith": [],
                "conflictSummary": ""
            ]]
        ]

        XCTAssertThrowsError(
            try ReferencePreparationClient.parseResponse(
                try openAIResponse(
                    cards: [outputCard(
                        project: "Modern Renderer",
                        period: "2024–2026",
                        year: 2026,
                        paths: ["Projects/ModernRenderer.md"]
                    )],
                    sourceManifest: manifest
                ),
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

    func testPreparationAllowsResolvedContextWithNoCandidateFacts() throws {
        let references = referenceSnapshot()
        let manifest: [String: Any] = [
            "canonicalResumePath": NSNull(),
            "requiresReview": false,
            "resolutionSummary": "Only a job description was supplied.",
            "sources": [[
                "path": "Projects/ModernRenderer.md",
                "title": "Role description",
                "kind": "jobDescription",
                "use": "contextOnly",
                "confidence": 0.98,
                "rationale": "It describes the target role, not the candidate.",
                "conflictsWith": [],
                "conflictSummary": ""
            ]]
        ]

        let generation = try ReferencePreparationClient.parseResponse(
            try openAIResponse(cards: [], sourceManifest: manifest),
            references: references,
            purpose: .interview,
            sessionContext: "Graphics role",
            localReferenceRevision: "local-r1",
            webSourceRevision: "web-r1",
            previousCards: [],
            preparedAt: Date(),
            generationMilliseconds: 10
        )

        XCTAssertTrue(generation.pack.cards.isEmpty)
        XCTAssertTrue(
            generation.pack.sourceManifest?.factualSourcePaths.isEmpty == true
        )
    }

    func testLegacyPreparedPackIsStaleUntilRebuiltWithSourceResolution() {
        let pack = PreparedReferencePack(
            preparationVersion: 1,
            purpose: .interview,
            localReferenceRevision: "local",
            webSourceRevision: ReferencePreparationDigest.webSourceRevision([]),
            sessionContext: "Graphics role",
            preparedAt: Date(),
            cards: [card(id: "card", project: "Project", year: 2025)]
        )

        XCTAssertFalse(
            pack.isCurrent(
                purpose: .interview,
                localReferenceRevision: "local",
                webSources: [],
                sessionContext: "Graphics role"
            )
        )

        let unclassifiedCurrentVersion = PreparedReferencePack(
            purpose: .interview,
            localReferenceRevision: "local",
            webSourceRevision: ReferencePreparationDigest.webSourceRevision([]),
            sessionContext: "Graphics role",
            preparedAt: Date(),
            cards: [card(id: "card", project: "Project", year: 2025)]
        )
        XCTAssertFalse(
            unclassifiedCurrentVersion.isCurrent(
                purpose: .interview,
                localReferenceRevision: "local",
                webSources: [],
                sessionContext: "Graphics role"
            )
        )
    }

    func testExplicitResumeIsIncludedFirstAndDuplicateFolderCopyIsRemoved()
        throws
    {
        let resume = document(
            path: "Selected Resume/current.md",
            content: "Current resume through 2026."
        )
        let local = ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/references"),
            documents: [
                document(
                    path: "generated/resume-snapshot.md",
                    content: resume.content
                ),
                document(
                    path: "notes/interview.md",
                    content: "Interview preparation notes."
                )
            ],
            revision: "local-r1",
            indexedAt: Date(),
            ignoredFileCount: 0,
            issues: []
        )

        let combined = try ReferencePreparationClient.combinedReferences(
            localReferences: local,
            explicitResume: resume,
            webSources: []
        )

        XCTAssertEqual(
            combined.documents.first?.relativePath,
            "Selected Resume/current.md"
        )
        XCTAssertEqual(
            combined.documents.filter { $0.content == resume.content }.count,
            1
        )
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

    func testSelectionReservesRawRelevanceAndRecentContextWithoutLegacyLeakage() {
        let legacy = card(
            id: "legacy",
            project: "Legacy compatibility project",
            year: 2000
        )
        let recent = (0..<8).map { index in
            card(
                id: "recent-\(index)",
                project: "Recent project \(index)",
                year: 2024 + (index % 3)
            )
        }
        let selector = PreparedReferenceSelector(
            currentYear: 2026,
            semanticDistance: { question, text in
                if text.contains("Legacy") {
                    return question.contains("compatibility") ? 0.10 : 0.90
                }
                let id = Int(text.split(separator: " ").last ?? "0") ?? 0
                return 0.11 + Double(id) * 0.01
            }
        )

        let explicit = selector.select(
            from: recent + [legacy],
            question: "Tell me about a compatibility problem.",
            maximumCards: 8
        )
        XCTAssertTrue(explicit.contains { $0.id == legacy.id })

        let generic = selector.select(
            from: recent + [legacy],
            question: "Tell me about a recent optimization.",
            maximumCards: 8
        )
        XCTAssertFalse(generic.contains { $0.id == legacy.id })
        XCTAssertGreaterThanOrEqual(
            generic.filter { ($0.latestYear ?? 0) >= 2024 }.count,
            7
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

    func testPreparedPackRevisionChangesWhenCardEvidenceChanges() {
        let original = card(id: "card", project: "Project", year: 2025)
        let changed = PreparedReferenceCard(
            id: original.id,
            projectAnchor: original.projectAnchor,
            period: original.period,
            latestYear: original.latestYear,
            role: original.role,
            summary: "A materially different prepared summary.",
            concreteDetails: original.concreteDetails,
            interviewUses: original.interviewUses,
            sourcePaths: original.sourcePaths,
            roleRelevance: original.roleRelevance,
            isEnabled: true
        )
        let originalPack = PreparedReferencePack(
            purpose: .interview,
            localReferenceRevision: "local",
            webSourceRevision: "web",
            sessionContext: "context",
            preparedAt: Date(),
            cards: [original]
        )
        let changedPack = PreparedReferencePack(
            purpose: .interview,
            localReferenceRevision: "local",
            webSourceRevision: "web",
            sessionContext: "context",
            preparedAt: Date(),
            cards: [changed]
        )

        XCTAssertNotEqual(originalPack.revision, changedPack.revision)
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
        source.contentDigest = ReferencePreparationDigest.hash([source.content])
        var state = ReferencePreparationState()
        state.resumeSource = ReferenceResumeSource(
            filePath: "/tmp/current-resume.pdf",
            citationPath: "Selected Resume/current-resume.pdf",
            contentDigest: "resume-digest",
            sourceByteCount: 1_024
        )
        state.webSources = [source]
        state.interviewContext = InterviewContextDraft(
            text: "A graphics engineering interview focused on recent renderer work.",
            origin: .resumeSuggestion,
            sourceResumeDigest: "resume-digest"
        )
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

        XCTAssertEqual(restored.resumeSource, state.resumeSource)
        XCTAssertEqual(restored.webSources, state.webSources)
        XCTAssertEqual(restored.interviewContext, state.interviewContext)
        XCTAssertEqual(restored.pack, state.pack)
        XCTAssertEqual(restored.phase, .ready)
    }

    func testLegacyPreparationArchiveUsesVisibleBasicInterviewDescription()
        throws
    {
        let data = try JSONSerialization.data(withJSONObject: [
            "webSources": []
        ])
        let archive = try JSONDecoder().decode(
            ReferencePreparationArchive.self,
            from: data
        )
        let restored = ReferencePreparationState(archive: archive)

        XCTAssertEqual(
            restored.interviewContext,
            InterviewContextDraft(
                text: "A job interview.",
                origin: .basic
            )
        )
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

    private func document(path: String, content: String) -> ReferenceDocument {
        ReferenceDocument(
            relativePath: path,
            kind: .markdown,
            content: content,
            sourceByteCount: content.utf8.count,
            isTruncated: false
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

    private func openAIResponse(
        cards: [[String: Any]],
        sourceManifest: [String: Any]? = nil
    ) throws -> Data {
        let manifest = sourceManifest ?? [
            "canonicalResumePath": NSNull(),
            "requiresReview": false,
            "resolutionSummary":
                "No resume was supplied; the project document is a factual supplement.",
            "sources": [[
                "path": "Projects/ModernRenderer.md",
                "title": "Modern Renderer",
                "kind": "projectPage",
                "use": "factualSupplement",
                "confidence": 0.96,
                "rationale":
                    "The document directly describes the candidate's renderer work.",
                "conflictsWith": [],
                "conflictSummary": ""
            ]]
        ]
        let outputData = try JSONSerialization.data(
            withJSONObject: [
                "sourceManifest": manifest,
                "cards": cards
            ],
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

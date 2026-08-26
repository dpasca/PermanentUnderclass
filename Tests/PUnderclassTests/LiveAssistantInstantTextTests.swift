import Foundation
import XCTest
@testable import PUnderclass

final class LiveAssistantInstantTextTests: XCTestCase {
    func testHostedInstantTextVersusVerifiedCue() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_ASSISTANT_INSTANT_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set RUN_LIVE_ASSISTANT_INSTANT_SMOKE=1 to run the hosted instant-text comparison."
            )
        }
        let apiKey = try XCTUnwrap(environment["OPENAI_API_KEY"])
        let client = LiveAssistantClient()
        let references = Self.references()
        let question = "Tell me about a time you reduced CPU rendering overhead, and how you verified the change."
        let recorder = InstantTextRecorder()

        let instant = try await client.generate(
            apiKey: apiKey,
            references: references,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: question,
            sessionContext: "A rendering-engineer interview.",
            purpose: .interview,
            basedOnSequence: 1,
            trigger: .finalizedTurn,
            webSearchMode: .disabled,
            answerMode: .grounded,
            deliveryMode: .instantText,
            onInstantText: { update in
                await recorder.record(update)
            }
        )
        let recordedFirstUpdate = await recorder.first()
        let firstUpdate = try XCTUnwrap(recordedFirstUpdate)
        let instantSuggestion = try XCTUnwrap(instant.suggestion)
        XCTAssertEqual(instant.deliveryMode, .instantText)
        XCTAssertEqual(instantSuggestion.deliveryMode, .instantText)
        XCTAssertFalse(firstUpdate.text.isEmpty)
        XCTAssertEqual(
            firstUpdate.firstRenderableTextMilliseconds,
            instant.latencyMilestones.firstRenderableTextMilliseconds
        )

        let verified = try await client.generate(
            apiKey: apiKey,
            references: references,
            recentTranscript: "",
            currentPartial: "",
            otherSpeakerText: question,
            sessionContext: "A rendering-engineer interview.",
            purpose: .interview,
            basedOnSequence: 2,
            trigger: .finalizedTurn,
            webSearchMode: .disabled,
            answerMode: .grounded,
            deliveryMode: .verified
        )
        let verifiedSuggestion = try XCTUnwrap(verified.suggestion)
        XCTAssertEqual(verified.deliveryMode, .verified)
        XCTAssertEqual(verifiedSuggestion.grounding, .localReferences)

        print(
            "INSTANT_TEXT_COMPARISON instant_first_renderable_ms=\(instant.latencyMilestones.firstRenderableTextMilliseconds ?? -1) instant_complete_ms=\(instant.generationMilliseconds) verified_first_delta_ms=\(verified.latencyMilestones.firstTextDeltaMilliseconds ?? -1) verified_complete_ms=\(verified.generationMilliseconds)"
        )
        print(
            "INSTANT_TEXT_CUE \(instantSuggestion.preamble ?? "")"
        )
        print(
            "VERIFIED_CUE \(Self.spokenText(verifiedSuggestion))"
        )
    }

    private static func references() -> ReferenceLibrarySnapshot {
        let resume = """
        Davide built a Metal renderer at Example Studio. To reduce CPU submission overhead, he batched draw calls by material and used indirect command buffers. On a fixed replay, CPU frame submission fell from 7 ms to 3 ms with matching rendered output.
        """
        return ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/instant-text-smoke"),
            documents: [
                ReferenceDocument(
                    relativePath: "resume.md",
                    kind: .markdown,
                    content: resume,
                    sourceByteCount: resume.utf8.count,
                    isTruncated: false
                )
            ],
            revision: "instant-text-smoke",
            indexedAt: Date(),
            ignoredFileCount: 0,
            issues: []
        )
    }

    private static func spokenText(
        _ suggestion: CompanionAssistantSuggestion
    ) -> String {
        ([suggestion.preamble] + suggestion.beats.map(\.point))
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

private actor InstantTextRecorder {
    private var updates: [LiveAssistantInstantTextUpdate] = []

    func record(_ update: LiveAssistantInstantTextUpdate) {
        updates.append(update)
    }

    func first() -> LiveAssistantInstantTextUpdate? {
        updates.first
    }
}

import Foundation
import XCTest
@testable import PUnderclass

final class InterviewSessionArchiveTests: XCTestCase {
    func testArchivePreservesRefinedTranscriptAndEveryDisplayedSuggestion()
        throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = InterviewSessionArchiveStore(directoryURL: directoryURL)
        let sessionID = UUID()
        var archive = InterviewSessionArchive(
            id: sessionID,
            source: .liveCapture,
            startedAt: Date(timeIntervalSince1970: 100),
            answerMode: .plausibleRehearsal,
            earlyBridgeEnabled: true,
            sessionContext: "Rendering role",
            referenceRevision: "revision-1"
        )

        archive.upsertTranscriptTurn(
            CompanionTranscriptTurn(
                id: "turn-1",
                speaker: "interviewer",
                text: "Tell me about a bottleneck.",
                startedAt: Date(timeIntervalSince1970: 101),
                endedAt: Date(timeIntervalSince1970: 102),
                isRefined: false
            ),
            updatedAt: Date(timeIntervalSince1970: 102)
        )
        archive.upsertTranscriptTurn(
            CompanionTranscriptTurn(
                id: "turn-1",
                speaker: "interviewer",
                text: "Tell me about a performance bottleneck.",
                startedAt: Date(timeIntervalSince1970: 101),
                endedAt: Date(timeIntervalSince1970: 102),
                isRefined: true
            ),
            updatedAt: Date(timeIntervalSince1970: 103)
        )
        archive.appendBridge(
            CompanionAssistantBridge(
                id: "bridge-1",
                topicID: "turn-1",
                sourceText: "Tell me about a performance bottleneck.",
                text: "Let me choose the clearest example for a moment.",
                generatedAt: Date(timeIntervalSince1970: 104),
                generationMilliseconds: 320
            ),
            updatedAt: Date(timeIntervalSince1970: 104)
        )
        archive.appendSuggestion(
            suggestion(id: "partial-cue", generatedAt: 105),
            updatedAt: Date(timeIntervalSince1970: 105)
        )
        archive.appendSuggestion(
            suggestion(id: "final-cue", generatedAt: 106),
            updatedAt: Date(timeIntervalSince1970: 106)
        )
        archive.finish(at: Date(timeIntervalSince1970: 107))

        let url = try store.save(archive)
        let loaded = try store.load(from: url)

        XCTAssertEqual(loaded, archive)
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.transcript.count, 1)
        XCTAssertEqual(
            loaded.transcript[0].text,
            "Tell me about a performance bottleneck."
        )
        XCTAssertTrue(loaded.transcript[0].isRefined)
        XCTAssertEqual(loaded.earlyBridges.map(\.id), ["bridge-1"])
        XCTAssertEqual(
            loaded.suggestions.map(\.id),
            ["partial-cue", "final-cue"]
        )
        XCTAssertEqual(
            try store.mostRecentArchiveURL()?.lastPathComponent,
            url.lastPathComponent
        )
    }

    private func suggestion(
        id: String,
        generatedAt: TimeInterval
    ) -> CompanionAssistantSuggestion {
        CompanionAssistantSuggestion(
            id: id,
            basedOnSequence: Int(generatedAt),
            question: "Tell me about a performance bottleneck.",
            preamble: "On one renderer, upload stalls became repeatable.",
            beats: [
                CompanionAnswerBeat(
                    label: "Signal",
                    point: "Frame captures put the wait at the upload boundary."
                ),
                CompanionAnswerBeat(
                    label: "Change",
                    point: "I moved reuse ahead of allocation on that path."
                ),
                CompanionAnswerBeat(
                    label: "Check",
                    point: "The same replay stopped stalling at that boundary."
                )
            ],
            citations: [],
            grounding: .generalKnowledge,
            confidence: .medium,
            generatedAt: Date(timeIntervalSince1970: generatedAt),
            generationMilliseconds: 780,
            trigger: id == "partial-cue" ? .partialTranscript : .finalizedTurn,
            triggeredAt: Date(timeIntervalSince1970: generatedAt - 1),
            totalLatencyMilliseconds: 1_200,
            topicID: "turn-1",
            inferenceOutcome: .suggestion,
            answerMode: .plausibleRehearsal,
            plausibleAssumptions: ["The upload incident is a rehearsal detail."],
            plausibleRehearsalPlan: CompanionPlausibleRehearsalPlan(
                projectAnchor: "Renderer upload path",
                observedSignal: "A repeatable wait at the upload boundary",
                mechanismChange: "Reused allocations earlier",
                discriminatingCheck: "Compared the same replay at the boundary",
                boundedOutcome: "The boundary stopped producing the stall"
            )
        )
    }
}

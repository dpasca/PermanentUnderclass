import XCTest
@testable import PUnderclass

final class InterviewPreparationReadinessTests: XCTestCase {
    func testExplicitResumeIsTheFirstRequiredSource() {
        XCTAssertEqual(
            resolve(hasExplicitResume: false),
            .needsResume
        )
    }

    func testSelectedResumeWithoutCurrentPackNeedsPreparation() {
        XCTAssertEqual(
            resolve(hasExplicitResume: true),
            .needsEvidence
        )
    }

    func testCurrentPackWithConflictNeedsReview() {
        XCTAssertEqual(
            resolve(
                hasExplicitResume: true,
                hasPack: true,
                isPackCurrent: true,
                requiresSourceReview: true,
                enabledCardCount: 4
            ),
            .needsSourceReview
        )
    }

    func testCurrentPackWithoutEnabledEvidenceIsNotReady() {
        XCTAssertEqual(
            resolve(
                hasExplicitResume: true,
                hasPack: true,
                isPackCurrent: true
            ),
            .needsUsableEvidence
        )
    }

    func testCurrentResolvedPackIsReady() {
        XCTAssertEqual(
            resolve(
                hasExplicitResume: true,
                hasPack: true,
                isPackCurrent: true,
                enabledCardCount: 6
            ),
            .ready(cardCount: 6)
        )
    }

    func testUnavailableAndActiveStatesTakePriority() {
        XCTAssertEqual(
            resolve(isAssistantAvailable: false),
            .unavailable
        )
        XCTAssertEqual(
            resolve(hasActiveSession: true, hasExplicitResume: true),
            .activeSession
        )
        XCTAssertEqual(
            resolve(
                hasActiveSession: true,
                isPreparing: true,
                hasExplicitResume: true
            ),
            .preparing
        )
    }

    private func resolve(
        isAssistantAvailable: Bool = true,
        hasActiveSession: Bool = false,
        isPreparing: Bool = false,
        hasExplicitResume: Bool = false,
        hasPack: Bool = false,
        isPackCurrent: Bool = false,
        requiresSourceReview: Bool = false,
        enabledCardCount: Int = 0
    ) -> InterviewPreparationReadiness {
        .resolve(
            isAssistantAvailable: isAssistantAvailable,
            hasActiveSession: hasActiveSession,
            isPreparing: isPreparing,
            hasExplicitResume: hasExplicitResume,
            hasPack: hasPack,
            isPackCurrent: isPackCurrent,
            requiresSourceReview: requiresSourceReview,
            enabledCardCount: enabledCardCount
        )
    }
}

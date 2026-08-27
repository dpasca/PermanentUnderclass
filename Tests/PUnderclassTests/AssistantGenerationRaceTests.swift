import XCTest
@testable import PUnderclass

final class AssistantGenerationRaceTests: XCTestCase {
    func testPrimarySuggestionWinsAndCancelsTheHedge() {
        let primaryID = UUID()
        let hedgeID = UUID()
        var state = AssistantGenerationArbitrationState()

        XCTAssertTrue(state.startPrimary(primaryID).isEmpty)
        XCTAssertTrue(state.startHedge(hedgeID))

        let claim = state.claimSuggestion(from: primaryID)
        XCTAssertTrue(claim.isAccepted)
        XCTAssertEqual(claim.requestIDsToCancel, [hedgeID])
        XCTAssertTrue(state.contains(primaryID))
        XCTAssertFalse(state.contains(hedgeID))
        XCTAssertTrue(state.hasPublishedSuggestion)
        XCTAssertFalse(state.claimSuggestion(from: hedgeID).isAccepted)

        state.requestEnded(primaryID)
        XCTAssertFalse(state.hasActiveRequest)
        XCTAssertTrue(state.hasPublishedSuggestion)
    }

    func testHedgeSuggestionWinsAndCancelsThePrimary() {
        let primaryID = UUID()
        let hedgeID = UUID()
        var state = AssistantGenerationArbitrationState()

        _ = state.startPrimary(primaryID)
        XCTAssertTrue(state.startHedge(hedgeID))

        let claim = state.claimSuggestion(from: hedgeID)
        XCTAssertTrue(claim.isAccepted)
        XCTAssertEqual(claim.requestIDsToCancel, [primaryID])
        XCTAssertFalse(state.contains(primaryID))
        XCTAssertTrue(state.contains(hedgeID))
        XCTAssertFalse(state.claimSuggestion(from: primaryID).isAccepted)
    }

    func testNoSuggestionWaitsForTheOtherContender() {
        let primaryID = UUID()
        let hedgeID = UUID()
        var state = AssistantGenerationArbitrationState()

        _ = state.startPrimary(primaryID)
        XCTAssertTrue(state.startHedge(hedgeID))

        XCTAssertFalse(
            state.finishWithoutSuggestion(requestID: primaryID)
        )
        XCTAssertTrue(state.hasActiveRequest)
        XCTAssertTrue(
            state.finishWithoutSuggestion(requestID: hedgeID)
        )
        XCTAssertFalse(state.hasActiveRequest)
        XCTAssertFalse(state.hasPublishedSuggestion)
    }

    func testFinalizedInstantTextHedgesOnlyAnActivePartial() {
        let primaryID = UUID()
        let hedgeID = UUID()
        var state = AssistantGenerationArbitrationState()
        _ = state.startPrimary(primaryID)

        XCTAssertTrue(
            AssistantGenerationHedgePolicy.shouldStartFinalizedTurnHedge(
                trigger: .finalizedTurn,
                resolvedDeliveryMode: .instantText,
                isSameTurn: true,
                primaryTrigger: .partialTranscript,
                arbitration: state
            )
        )
        XCTAssertFalse(
            AssistantGenerationHedgePolicy.shouldStartFinalizedTurnHedge(
                trigger: .finalizedTurn,
                resolvedDeliveryMode: .verified,
                isSameTurn: true,
                primaryTrigger: .partialTranscript,
                arbitration: state
            )
        )

        XCTAssertTrue(state.startHedge(hedgeID))
        XCTAssertFalse(
            AssistantGenerationHedgePolicy.shouldStartFinalizedTurnHedge(
                trigger: .finalizedTurn,
                resolvedDeliveryMode: .instantText,
                isSameTurn: true,
                primaryTrigger: .partialTranscript,
                arbitration: state
            )
        )
    }
}

import Foundation

struct AssistantGenerationClaim: Equatable, Sendable {
    let isAccepted: Bool
    let requestIDsToCancel: Set<UUID>

    static let rejected = AssistantGenerationClaim(
        isAccepted: false,
        requestIDsToCancel: []
    )
}

struct AssistantGenerationArbitrationState: Equatable, Sendable {
    private(set) var primaryRequestID: UUID?
    private(set) var hedgeRequestID: UUID?
    private(set) var winnerRequestID: UUID?

    var hasActivePrimary: Bool {
        primaryRequestID != nil
    }

    var hasActiveRequest: Bool {
        primaryRequestID != nil || hedgeRequestID != nil
    }

    var hasPublishedSuggestion: Bool {
        winnerRequestID != nil
    }

    func contains(_ requestID: UUID) -> Bool {
        primaryRequestID == requestID || hedgeRequestID == requestID
    }

    mutating func startPrimary(_ requestID: UUID) -> Set<UUID> {
        let requestIDsToCancel = activeRequestIDs
        primaryRequestID = requestID
        hedgeRequestID = nil
        winnerRequestID = nil
        return requestIDsToCancel
    }

    mutating func startHedge(_ requestID: UUID) -> Bool {
        guard
            primaryRequestID != nil,
            hedgeRequestID == nil,
            winnerRequestID == nil
        else {
            return false
        }
        hedgeRequestID = requestID
        return true
    }

    mutating func claimSuggestion(
        from requestID: UUID
    ) -> AssistantGenerationClaim {
        guard winnerRequestID == nil, contains(requestID) else {
            return .rejected
        }
        winnerRequestID = requestID
        let requestIDsToCancel = activeRequestIDs.subtracting([requestID])
        primaryRequestID = primaryRequestID == requestID ? requestID : nil
        hedgeRequestID = hedgeRequestID == requestID ? requestID : nil
        return AssistantGenerationClaim(
            isAccepted: true,
            requestIDsToCancel: requestIDsToCancel
        )
    }

    mutating func finishWithoutSuggestion(
        requestID: UUID
    ) -> Bool {
        guard winnerRequestID == nil, remove(requestID) else { return false }
        return !hasActiveRequest
    }

    mutating func requestEnded(_ requestID: UUID) {
        _ = remove(requestID)
    }

    mutating func reset() -> Set<UUID> {
        let requestIDsToCancel = activeRequestIDs
        primaryRequestID = nil
        hedgeRequestID = nil
        winnerRequestID = nil
        return requestIDsToCancel
    }

    private var activeRequestIDs: Set<UUID> {
        Set([primaryRequestID, hedgeRequestID].compactMap { $0 })
    }

    private mutating func remove(_ requestID: UUID) -> Bool {
        var removed = false
        if primaryRequestID == requestID {
            primaryRequestID = nil
            removed = true
        }
        if hedgeRequestID == requestID {
            hedgeRequestID = nil
            removed = true
        }
        return removed
    }
}

enum AssistantGenerationHedgePolicy {
    static func shouldStartFinalizedTurnHedge(
        trigger: CompanionAssistantTrigger,
        resolvedDeliveryMode: LiveAssistantDeliveryMode,
        isSameTurn: Bool,
        primaryTrigger: CompanionAssistantTrigger?,
        arbitration: AssistantGenerationArbitrationState
    ) -> Bool {
        trigger == .finalizedTurn
            && resolvedDeliveryMode == .instantText
            && isSameTurn
            && primaryTrigger == .partialTranscript
            && arbitration.hasActivePrimary
            && arbitration.hedgeRequestID == nil
            && !arbitration.hasPublishedSuggestion
    }
}

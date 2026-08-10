import Foundation

/// Reassembles the transcript of a streamed dictation. Committing segments
/// while the user is still speaking means several items can be transcribing at
/// once and completions arrive out of order, so text is keyed by item and
/// emitted in commit order.
struct DictationStreamAssembly: Equatable {
    private(set) var order: [String] = []
    private var finalized: [String: String] = [:]
    private var deltas: [String: String] = [:]

    mutating func registerCommitted(itemID: String) {
        guard !order.contains(itemID) else { return }
        order.append(itemID)
    }

    mutating func appendDelta(itemID: String, delta: String) {
        registerCommitted(itemID: itemID)
        guard finalized[itemID] == nil else { return }
        deltas[itemID, default: ""] += delta
    }

    mutating func finalize(itemID: String, text: String) {
        registerCommitted(itemID: itemID)
        finalized[itemID] = text
        deltas[itemID] = nil
    }

    /// Best available text: finalized segments, plus the in-flight deltas of
    /// segments that have not completed yet.
    var text: String {
        order
            .map { finalized[$0] ?? deltas[$0] ?? "" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func isComplete(expectedSegments: Int) -> Bool {
        guard order.count >= expectedSegments else { return false }
        return order.allSatisfy { finalized[$0] != nil }
    }
}

/// Decides when a streamed dictation should close the current segment. A brief
/// hesitation is not a sentence boundary, so ordinary segments require
/// sustained silence. Longer segments may use a shorter quiet boundary to keep
/// release latency bounded, but are never cut while the user is speaking.
enum DictationSegmentCommitPolicy {
    static let minimumSegmentSeconds: Double = 8
    static let longSegmentSeconds: Double = 60
    static let sustainedSilenceSeconds: Double = 1.5
    static let briefSilenceSeconds: Double = 0.35
    /// The realtime API rejects a commit with less than 100 ms buffered.
    static let minimumCommitSeconds: Double = 0.2

    static func shouldCommit(
        segmentSeconds: Double,
        hasSustainedSilence: Bool,
        hasBriefSilence: Bool
    ) -> Bool {
        guard segmentSeconds >= minimumCommitSeconds else { return false }
        guard segmentSeconds >= minimumSegmentSeconds else { return false }
        if hasSustainedSilence { return true }
        return segmentSeconds >= longSegmentSeconds && hasBriefSilence
    }

    static func canCommit(segmentSeconds: Double) -> Bool {
        segmentSeconds >= minimumCommitSeconds
    }
}

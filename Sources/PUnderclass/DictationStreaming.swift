import Foundation

/// Reassembles the transcript events for a streamed dictation. Text is keyed by
/// item so deltas can be replaced by the corresponding final transcript.
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

/// Validates the single release-time commit. The realtime API rejects commits
/// with less than 100 ms of buffered audio, so use a small safety margin.
enum DictationStreamCommitPolicy {
    static let minimumCommitSeconds: Double = 0.2

    static func canCommit(audioSeconds: Double) -> Bool {
        audioSeconds >= minimumCommitSeconds
    }
}

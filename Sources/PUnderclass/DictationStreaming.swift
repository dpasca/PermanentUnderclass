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

struct DictationStreamTailCompletion: Equatable {
    let audioToForward: Data
    let forwardedPastRetainedEndByteCount: Int

    var canUseStream: Bool {
        forwardedPastRetainedEndByteCount == 0
    }
}

/// Keeps the newest capture audio local until release-time speech boundaries
/// are known. Most of a long recording still uploads continuously, while the
/// pause between the last spoken word and the shortcut release can be dropped.
final class DictationStreamTailBuffer: @unchecked Sendable {
    static let defaultHoldbackByteCount =
        QuickDictationStreamPolicy.captureBytesPerSecond * 2

    private let holdbackByteCount: Int
    private let lock = NSLock()
    private var storage = Data()
    private var readOffset = 0
    private var sourceByteCount = 0
    private var forwardedByteCount = 0

    init(holdbackByteCount: Int = defaultHoldbackByteCount) {
        self.holdbackByteCount = max(0, holdbackByteCount)
    }

    func append(_ audio: Data) -> Data {
        guard !audio.isEmpty else { return Data() }
        lock.lock()
        defer { lock.unlock() }
        storage.append(audio)
        sourceByteCount += audio.count

        let bufferedByteCount = storage.count - readOffset
        let readyByteCount = max(0, bufferedByteCount - holdbackByteCount)
        guard readyByteCount > 0 else { return Data() }

        let endOffset = readOffset + readyByteCount
        let ready = Data(storage[readOffset..<endOffset])
        readOffset = endOffset
        forwardedByteCount += readyByteCount
        compactIfNeeded()
        return ready
    }

    func finish(
        retaining sourceRange: Range<Int>
    ) -> DictationStreamTailCompletion {
        lock.lock()
        defer { lock.unlock() }
        let retainedEnd = min(sourceByteCount, sourceRange.upperBound)
        let forwardedPastEnd = max(0, forwardedByteCount - retainedEnd)
        let pendingSourceStart = forwardedByteCount
        let retainedPendingStart = max(
            pendingSourceStart,
            sourceRange.lowerBound
        )
        let retainedPendingEnd = max(
            retainedPendingStart,
            retainedEnd
        )

        let audioToForward: Data
        if retainedPendingStart < retainedPendingEnd {
            let lowerOffset = readOffset
                + retainedPendingStart - pendingSourceStart
            let upperOffset = readOffset
                + retainedPendingEnd - pendingSourceStart
            audioToForward = Data(storage[lowerOffset..<upperOffset])
        } else {
            audioToForward = Data()
        }

        discardUnlocked()
        return DictationStreamTailCompletion(
            audioToForward: audioToForward,
            forwardedPastRetainedEndByteCount: forwardedPastEnd
        )
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        discardUnlocked()
    }

    private func discardUnlocked() {
        storage.removeAll(keepingCapacity: false)
        readOffset = 0
        sourceByteCount = 0
        forwardedByteCount = 0
    }

    private func compactIfNeeded() {
        guard
            readOffset >= max(holdbackByteCount, 64 * 1_024),
            readOffset * 2 >= storage.count
        else {
            return
        }
        storage.removeSubrange(0..<readOffset)
        readOffset = 0
    }
}

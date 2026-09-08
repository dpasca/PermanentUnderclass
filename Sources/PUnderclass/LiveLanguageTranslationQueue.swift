import Foundation

struct LiveLanguageTranslationRequest: Equatable {
    let turnID: String
    let text: String
    let trigger: CompanionAssistantTrigger
    let speaker: SpeakerTag
    let purpose: CapturePurpose
    let observedAt: Date
}

/// The model chooses linguistic boundaries. Exact prefix checks only reconcile
/// transcript identity: completed translations stay immutable unless ASR revises
/// their source. No sentence/keyword heuristics are used to segment speech.
struct LiveLanguageTranslationProgress {
    let source: String
    let completed: [CompanionLanguageAssistance.Passage]
    let remainder: String
    let revisesCompletedPassage: Bool

    init(source: String, previous: CompanionLanguageAssistance?) {
        self.source = source
        var remaining = source[...]
        var retained: [CompanionLanguageAssistance.Passage] = []
        var revised = false
        for passage in previous?.passages ?? [] {
            guard passage.isComplete else { break }
            guard !passage.source.isEmpty, remaining.hasPrefix(passage.source) else {
                revised = true
                break
            }
            retained.append(passage)
            remaining = remaining.dropFirst(passage.source.count)
        }
        completed = retained
        remainder = String(remaining)
        revisesCompletedPassage = revised
    }

    // Recheck the full turn when only a final reply is still needed.
    var target: String { remainder.isEmpty ? source : remainder }

    var context: String {
        guard !completed.isEmpty else { return "" }
        return "Earlier translated speech in this turn (context only):\n"
            + completed.map { "\($0.source)\n\($0.translation)" }.joined(separator: "\n")
    }

    func merging(_ result: CompanionLanguageAssistance, finalized: Bool) -> CompanionLanguageAssistance {
        var passages = completed
        if !remainder.isEmpty {
            let proposed = result.passages ?? []
            let aligned = !proposed.isEmpty
                && proposed.map(\.source).joined() == remainder
                && proposed.allSatisfy {
                    !$0.source.isEmpty && !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                && proposed.dropLast().allSatisfy(\.isComplete)
            // An unaligned model result is still useful as a draft, but must
            // never advance the committed source cursor or lose spoken words.
            var additions = aligned ? proposed : [.init(
                source: remainder, translation: result.translation, isComplete: false)]
            if finalized && aligned {
                additions = additions.map { .init(source: $0.source, translation: $0.translation, isComplete: true) }
            }
            if revisesCompletedPassage { additions[0].wasRevised = true }
            passages += additions
        }
        return CompanionLanguageAssistance(
            sourceLanguage: result.sourceLanguage,
            translation: passages.map(\.translation).joined(separator: "\n\n"),
            reply: result.reply,
            passages: passages
        )
    }
}

/// Coalesce changing text without cancelling a translation already in flight.
/// Completed turns remain queued even when the next turn has begun.
struct LiveLanguageTranslationQueue {
    private var pending: [LiveLanguageTranslationRequest] = []
    private var finalizedTurnIDs: Set<String> = []

    mutating func enqueue(_ request: LiveLanguageTranslationRequest) {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if request.trigger == .partialTranscript {
            guard !finalizedTurnIDs.contains(request.turnID) else { return }
        } else {
            finalizedTurnIDs.insert(request.turnID)
        }
        if let index = pending.firstIndex(where: { $0.turnID == request.turnID }) {
            pending[index] = request
        } else {
            pending.append(request)
        }
    }

    mutating func takeNext() -> LiveLanguageTranslationRequest? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    mutating func reset() {
        pending.removeAll()
        finalizedTurnIDs.removeAll()
    }
}

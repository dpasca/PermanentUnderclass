import AVFoundation
import Foundation

struct SyntheticInterviewTurn: Equatable {
    let id: String
    let speaker: SpeakerTag
    let text: String
    let pauseAfterSpeech: TimeInterval
}

struct SyntheticInterviewScenario: Equatable {
    static let launchArgument = "--synthetic-interview"

    let name: String
    let finalizationDelay: TimeInterval
    let turns: [SyntheticInterviewTurn]

    static let latencyProbe = SyntheticInterviewScenario(
        name: "Synthetic latency interview",
        finalizationDelay: 3,
        turns: [
            SyntheticInterviewTurn(
                id: "opening-question",
                speaker: .other,
                text: "Thanks for joining. To start, what kind of product and engineering work have you been focused on recently?",
                pauseAfterSpeech: 3.6
            ),
            SyntheticInterviewTurn(
                id: "opening-answer",
                speaker: .you,
                text: "Recently I have been building a low latency interview assistant for macOS. It captures both sides of a conversation, transcribes them, and turns useful moments into concise guidance.",
                pauseAfterSpeech: 3.4
            ),
            SyntheticInterviewTurn(
                id: "latency-question",
                speaker: .other,
                text: "Tell me about a time you found and fixed a serious latency problem. What did you personally own, and how did you prove the improvement was real?",
                pauseAfterSpeech: 5
            ),
            SyntheticInterviewTurn(
                id: "latency-answer",
                speaker: .you,
                text: "The strongest example is the live assistant itself. I first separated the capture, transcription, and model timing so I could see which stage was slow. Then I changed the assistant to react to stable partial speech instead of waiting only for a finalized turn, and I added an automated replay so the same timing could be measured after every change.",
                pauseAfterSpeech: 3.6
            ),
            SyntheticInterviewTurn(
                id: "tradeoff-question",
                speaker: .other,
                text: "How did you keep the faster system from becoming noisy or expensive when someone paused in the middle of a sentence?",
                pauseAfterSpeech: 5
            ),
            SyntheticInterviewTurn(
                id: "tradeoff-answer",
                speaker: .you,
                text: "I kept the decision model based. An audio pause schedules the current partial once, and exact partial and final duplicates are coalesced, but there is no keyword gate deciding what matters. The structured model still decides whether a suggestion is useful, and final turns remain a reliable fallback.",
                pauseAfterSpeech: 3
            )
        ]
    )
}

struct SyntheticInterviewState: Equatable {
    var isRunning = false
    var title = "Synthetic interview ready"
    var detail = "Built-in voices replay a fixed interview while the host injects its known transcript."
    var currentTurn = 0
    var totalTurns = SyntheticInterviewScenario.latencyProbe.turns.count

    var progress: Double {
        guard totalTurns > 0 else { return 0 }
        return Double(currentTurn) / Double(totalTurns)
    }
}

enum SyntheticSpeechError: LocalizedError {
    case alreadySpeaking

    var errorDescription: String? {
        switch self {
        case .alreadySpeaking:
            "The synthetic speech player is already speaking."
        }
    }
}

final class SyntheticSpeechPlayer: NSObject, AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    typealias PartialHandler = (String) -> Void

    private let synthesizer = AVSpeechSynthesizer()
    private var activeText = ""
    private var partialHandler: PartialHandler?
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String,
        speaker: SpeakerTag,
        onPartial: @escaping PartialHandler
    ) async throws {
        guard continuation == nil else { throw SyntheticSpeechError.alreadySpeaking }
        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activeText = text
                partialHandler = onPartial
                self.continuation = continuation

                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(
                    language: speaker == .you ? "en-US" : "en-GB"
                )
                utterance.rate = speaker == .you ? 0.48 : 0.5
                utterance.pitchMultiplier = speaker == .you ? 0.96 : 1.04
                utterance.preUtteranceDelay = 0.12
                synthesizer.speak(utterance)
            }
        } onCancel: { [weak self] in
            DispatchQueue.main.async {
                self?.stop()
            }
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        } else {
            finish(throwing: CancellationError())
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let text = activeText as NSString
        let end = min(text.length, NSMaxRange(characterRange))
        guard end > 0 else { return }
        partialHandler?(text.substring(to: end))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        partialHandler?(activeText)
        finish()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish(throwing: CancellationError())
    }

    private func finish(throwing error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        partialHandler = nil
        activeText = ""
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

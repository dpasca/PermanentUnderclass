import Foundation

struct AssistantEvaluationIdentity: Equatable {
    let turnID: String
    let text: String
}

enum AssistantEvaluationPolicy {
    static let partialSpeechPauseMilliseconds = 800

    static func shouldEvaluate(
        speaker: SpeakerTag,
        purpose: CapturePurpose
    ) -> Bool {
        switch purpose {
        case .meeting, .interview:
            speaker == .other
        }
    }

    static func delayMilliseconds(
        for _: CompanionAssistantTrigger
    ) -> Int {
        0
    }
}

enum LiveAssistantUsefulnessPolicy {
    // A cue that arrives later than this is usually behind the candidate's
    // spoken answer. Measure from the end of the interviewer's speech, not
    // from the eventual model-call start.
    static let maximumInterviewLatencyMilliseconds = 6_000

    static func remainingInterviewLatencyMilliseconds(
        observedAt: Date,
        now: Date
    ) -> Int {
        let elapsed = max(0, Int(now.timeIntervalSince(observedAt) * 1_000))
        return max(0, maximumInterviewLatencyMilliseconds - elapsed)
    }

    static func isInterviewCueUseful(
        observedAt: Date,
        completedAt: Date
    ) -> Bool {
        completedAt.timeIntervalSince(observedAt) * 1_000
            < Double(maximumInterviewLatencyMilliseconds)
    }
}

enum EarlyInterviewBridgeEvaluationPolicy {
    enum Opportunity: String {
        case formingTranscript = "forming_transcript"
        case speechPause = "speech_pause"
        case finalizedTurn = "finalized_turn"
    }

    static let maximumFormingTranscriptAttemptsPerTurn = 2
    static let maximumSpeechPauseAttemptsPerTurn = 3

    static func shouldEvaluate(
        speaker: SpeakerTag,
        purpose: CapturePurpose,
        answerMode: AssistantAnswerMode,
        isEnabled: Bool
    ) -> Bool {
        isEnabled
            && speaker == .other
            && purpose == .interview
            && answerMode == .plausibleRehearsal
    }

    static func delayMilliseconds(
        for opportunity: Opportunity,
        attempt: Int = 0
    ) -> Int {
        switch opportunity {
        case .formingTranscript:
            attempt == 0 ? 600 : 200
        case .speechPause, .finalizedTurn:
            0
        }
    }
}

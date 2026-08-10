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

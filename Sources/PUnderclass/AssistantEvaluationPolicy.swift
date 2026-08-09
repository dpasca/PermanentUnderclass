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
    static let maximumAttemptsPerTurn = 2

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

    static func delayMilliseconds(forAttempt attempt: Int) -> Int {
        attempt == 0 ? 600 : 200
    }
}

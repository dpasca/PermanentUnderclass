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

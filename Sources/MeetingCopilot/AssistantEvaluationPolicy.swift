import Foundation

struct AssistantEvaluationIdentity: Equatable {
    let turnID: String
    let text: String
}

enum AssistantEvaluationPolicy {
    static let partialSpeechPauseMilliseconds = 800

    static func delayMilliseconds(
        for _: CompanionAssistantTrigger
    ) -> Int {
        0
    }
}

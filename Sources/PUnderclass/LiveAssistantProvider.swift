import Foundation

enum LiveAssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .gemini:
            "Google Gemini"
        }
    }

    var model: String {
        switch self {
        case .openAI:
            LiveAssistantConfiguration.production.model
        case .gemini:
            LiveAssistantConfiguration.gemini37Flash.model
        }
    }

    var reasoningDescription: String {
        switch self {
        case .openAI:
            "medium reasoning"
        case .gemini:
            "high thinking"
        }
    }

    var keyName: String {
        switch self {
        case .openAI:
            "OpenAI API key"
        case .gemini:
            "Gemini API key"
        }
    }
}

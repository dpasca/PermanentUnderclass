import Foundation

struct LiveAssistantInstantTextUpdate: Equatable, Sendable {
    let text: String
    let elapsedMilliseconds: Int
    let firstRenderableTextMilliseconds: Int
}

enum LiveAssistantInstantTextDecision: Equatable, Sendable {
    case skip
    case show(String)
}

actor LiveAssistantInstantTextAccumulator {
    private var streamedOutput = ""
    private(set) var firstRenderableTextMilliseconds: Int?

    func consume(
        delta: String,
        elapsedMilliseconds: Int
    ) -> LiveAssistantInstantTextUpdate? {
        streamedOutput += delta
        guard
            let visibleText = Self.visibleText(from: streamedOutput),
            !visibleText.isEmpty
        else {
            return nil
        }
        if firstRenderableTextMilliseconds == nil {
            firstRenderableTextMilliseconds = max(0, elapsedMilliseconds)
        }
        return LiveAssistantInstantTextUpdate(
            text: visibleText,
            elapsedMilliseconds: max(0, elapsedMilliseconds),
            firstRenderableTextMilliseconds:
                firstRenderableTextMilliseconds ?? max(0, elapsedMilliseconds)
        )
    }

    func completedDecision(
        finalOutput: String
    ) throws -> LiveAssistantInstantTextDecision {
        let trimmed = finalOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed == "SKIP" {
            return .skip
        }
        guard
            let visibleText = Self.visibleText(from: finalOutput),
            !visibleText.isEmpty
        else {
            throw LiveAssistantError.invalidResponse
        }
        return .show(visibleText)
    }

    private static func visibleText(from output: String) -> String? {
        let content: Substring
        if output.hasPrefix("SHOW\r\n") {
            content = output.dropFirst("SHOW\r\n".count)
        } else if output.hasPrefix("SHOW\n") {
            content = output.dropFirst("SHOW\n".count)
        } else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

/// Selects a privacy-safe, synthetic application state for documentation
/// screenshots. This mode must never load a user's saved content or credentials.
enum DocumentationDemoMode: String, CaseIterable {
    case quickDictation = "quick-dictation"
    case meeting
    case interview

    private static let argumentPrefix = "--documentation-demo="

    static func requested(
        in arguments: [String] = CommandLine.arguments
    ) -> DocumentationDemoMode? {
        for argument in arguments where argument.hasPrefix(argumentPrefix) {
            let rawValue = String(argument.dropFirst(argumentPrefix.count))
            return DocumentationDemoMode(rawValue: rawValue)
        }
        return nil
    }
}

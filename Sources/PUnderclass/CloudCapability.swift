import Foundation

/// A hosted capability that an OpenAI key adds. Meeting and Interview capture
/// themselves are local-capable; these cases describe only their cloud tier.
enum CloudFeature: String, CaseIterable, Identifiable {
    case meetingCapture
    case answerMirror
    case mockMeeting
    case mockInterview
    /// Not a locked feature but an upgrade: dictation already works locally.
    case bestAccuracyDictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetingCapture:
            "Meeting live enhancements"
        case .answerMirror:
            "Interview live enhancements"
        case .mockMeeting:
            "Generated meeting replay"
        case .mockInterview:
            "Generated interview replay"
        case .bestAccuracyDictation:
            "Best-accuracy dictation"
        }
    }

    /// Why this cannot be done on the Mac. Phrased for someone who has never
    /// heard of an API key.
    var cloudReason: String {
        switch self {
        case .meetingCapture:
            "Local meeting transcripts work without a key. A key adds word-by-word live text, Meeting Assistant cues, and web-backed help."
        case .answerMirror:
            "Local interview transcripts work without a key. A key adds word-by-word live text, Answer Mirror suggestions, and web-backed help."
        case .mockMeeting:
            "Replay questions and grounded meeting responses are written by language models that run on OpenAI's servers."
        case .mockInterview:
            "Replay questions and comparison answers are written by language models that run on OpenAI's servers."
        case .bestAccuracyDictation:
            "Dictation already works offline. An API key adds OpenAI's higher-accuracy model as an option."
        }
    }

    /// Whether the app is still fully usable without it.
    var isOptionalUpgrade: Bool {
        switch self {
        case .meetingCapture, .answerMirror, .bestAccuracyDictation:
            true
        case .mockMeeting, .mockInterview:
            false
        }
    }

    var availableWithoutKeyDescription: String? {
        switch self {
        case .meetingCapture:
            "Local two-speaker meeting transcripts still work"
        case .answerMirror:
            "Local two-speaker interview transcripts still work"
        case .bestAccuracyDictation:
            "Local dictation already works"
        case .mockMeeting, .mockInterview:
            nil
        }
    }
}

enum FeatureAccess: Equatable {
    case available
    /// No API key has been saved yet.
    case needsAPIKey
    /// A key exists, but the user asked for nothing to leave the Mac.
    case blockedByPrivacyLock

    var isAvailable: Bool { self == .available }
}

/// Decides what works right now. The app is local-first: with no key at all,
/// dictation and two-track capture are fully functional and only the hosted
/// enhancements are locked, so nothing has to be configured before use.
struct CloudCapability: Equatable {
    let hasAPIKey: Bool
    /// Set by someone who has a key but wants a hard guarantee that no audio
    /// or text leaves the machine.
    let privacyLockEnabled: Bool

    init(hasAPIKey: Bool, privacyLockEnabled: Bool = false) {
        self.hasAPIKey = hasAPIKey
        self.privacyLockEnabled = privacyLockEnabled
    }

    var isCloudEnabled: Bool {
        hasAPIKey && !privacyLockEnabled
    }

    func access(to feature: CloudFeature) -> FeatureAccess {
        if privacyLockEnabled { return .blockedByPrivacyLock }
        return hasAPIKey ? .available : .needsAPIKey
    }

    func isAvailable(_ feature: CloudFeature) -> Bool {
        access(to: feature).isAvailable
    }

    /// Short sentence for a locked feature's card, or nil when it is usable.
    func lockMessage(for feature: CloudFeature) -> String? {
        switch access(to: feature) {
        case .available:
            return nil
        case .needsAPIKey:
            return feature.cloudReason
        case .blockedByPrivacyLock:
            let localRemainder = feature.availableWithoutKeyDescription.map {
                " \($0)."
            } ?? ""
            return "\(feature.title) is turned off because you asked for everything to stay on this Mac.\(localRemainder)"
        }
    }

    func actionTitle(for feature: CloudFeature) -> String? {
        switch access(to: feature) {
        case .available:
            return nil
        case .needsAPIKey:
            return "Set Up OpenAI…"
        case .blockedByPrivacyLock:
            return "Open Privacy Settings…"
        }
    }

    /// The engine to actually use, given what the user picked. A cloud choice
    /// left over from before a key was removed must not break dictation.
    func resolvedEngine(
        preferring preference: TranscriptRefinementEngine
    ) -> TranscriptRefinementEngine {
        guard preference.isCloud, !isCloudEnabled else { return preference }
        return .localWhisper
    }
}

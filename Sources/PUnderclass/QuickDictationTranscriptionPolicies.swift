import Foundation

struct DictationTranscriberCallbacks {
    let onState: (SocketState) -> Void
    let onRefined: (_ transcriptID: String, _ text: String) -> Void
    let onFailure: (_ transcriptID: String, _ message: String) -> Void
    let onUsage: (OpenAITranscriptionUsageRecord) -> Void
    let onCommitted: (_ transcriptID: String) -> Void
    let onStreamPartial: (_ streamID: String, _ text: String) -> Void
    let onStreamCompleted: (_ streamID: String, _ text: String) -> Void
    let onStreamFailed: (_ streamID: String, _ message: String) -> Void
    let onUploadProgress: (
        _ transcriptID: String,
        _ sentBytes: Int,
        _ totalBytes: Int
    ) -> Void

    init(
        onState: @escaping (SocketState) -> Void,
        onRefined: @escaping (_ transcriptID: String, _ text: String) -> Void,
        onFailure: @escaping (_ transcriptID: String, _ message: String) -> Void,
        onUsage: @escaping (OpenAITranscriptionUsageRecord) -> Void = { _ in },
        onCommitted: @escaping (_ transcriptID: String) -> Void = { _ in },
        onStreamPartial: @escaping (
            _ streamID: String,
            _ text: String
        ) -> Void = { _, _ in },
        onStreamCompleted: @escaping (
            _ streamID: String,
            _ text: String
        ) -> Void = { _, _ in },
        onStreamFailed: @escaping (
            _ streamID: String,
            _ message: String
        ) -> Void = { _, _ in },
        onUploadProgress: @escaping (
            _ transcriptID: String,
            _ sentBytes: Int,
            _ totalBytes: Int
        ) -> Void = { _, _, _ in }
    ) {
        self.onState = onState
        self.onRefined = onRefined
        self.onFailure = onFailure
        self.onUsage = onUsage
        self.onCommitted = onCommitted
        self.onStreamPartial = onStreamPartial
        self.onStreamCompleted = onStreamCompleted
        self.onStreamFailed = onStreamFailed
        self.onUploadProgress = onUploadProgress
    }
}

enum QuickDictationTranscriberFactory {
    static func make(
        engine: TranscriptRefinementEngine,
        apiKey: String,
        label: String = "QuickDictation",
        callbacks: DictationTranscriberCallbacks
    ) -> TranscriptRefining {
        switch engine {
        case .localWhisper:
            WhisperRefinementClient(
                onState: callbacks.onState,
                onRefined: callbacks.onRefined,
                onFailure: callbacks.onFailure
            )
        case .localParakeet:
            ParakeetRefinementClient(
                onState: callbacks.onState,
                onRefined: callbacks.onRefined,
                onFailure: callbacks.onFailure
            )
        case .openAITranscribe:
            RealtimeRefinementClient(
                apiKey: apiKey,
                label: label,
                onState: callbacks.onState,
                onRefined: callbacks.onRefined,
                onFailure: callbacks.onFailure,
                onUsage: callbacks.onUsage,
                onCommitted: callbacks.onCommitted,
                onStreamPartial: callbacks.onStreamPartial,
                onStreamCompleted: callbacks.onStreamCompleted,
                onStreamFailed: callbacks.onStreamFailed,
                onUploadProgress: callbacks.onUploadProgress
            )
        }
    }
}

/// Keeps an enabled cloud dictation service ready across the Realtime API's
/// expected session rollover and transient transport failures.
struct QuickDictationReconnectPolicy {
    private static let failureDelays: [TimeInterval] = [1, 2, 5, 15, 30]
    private(set) var consecutiveFailures = 0

    mutating func reconnectDelay(
        after state: SocketState,
        engine: TranscriptRefinementEngine
    ) -> TimeInterval? {
        if case .connected = state {
            consecutiveFailures = 0
        }
        guard engine == .openAITranscribe else { return nil }

        switch state {
        case .idle:
            return 0
        case .connecting, .connected:
            return nil
        case .failed:
            let delay = Self.failureDelays[
                min(consecutiveFailures, Self.failureDelays.count - 1)
            ]
            consecutiveFailures += 1
            return delay
        }
    }

    mutating func reset() {
        consecutiveFailures = 0
    }
}

enum QuickDictationFallbackPolicy {
    /// The watchdog starts only after the complete final recording has been
    /// uploaded to OpenAI. Recording and upload duration are deliberately not
    /// bounded, so long dictations continue while audio is still flowing.
    static let responseWatchdogSeconds: TimeInterval = 30
}

enum QuickDictationContextPolicy {
    static let cleanupInstruction = """
        Quick Dictation output requirements: Preserve the speaker's meaning and wording. \
        Omit hesitation fillers, abandoned false starts, and immediate accidental repetitions. \
        Do not summarize, answer, or add information. Preserve technical terms, code identifiers, \
        and the language or languages spoken. Use conservative punctuation supported by the \
        wording and intonation. Do not treat a pause alone as the end of a sentence.
        """

    static func context(
        from base: TranscriptionContext,
        cleanDictation: Bool,
        delay: TranscriptionDelay,
        languages: [String]? = nil
    ) -> TranscriptionContext {
        return TranscriptionContext(
            prompt: base.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: base.keywords,
            languages: languages ?? base.languages,
            delay: delay,
            outputStyle: cleanDictation ? .cleanDictation : .verbatim
        )
    }
}

enum QuickDictationTranscriberAvailability {
    static func isReady(
        primaryReady: Bool,
        engine: TranscriptRefinementEngine,
        fallbackState: SocketState
    ) -> Bool {
        if primaryReady {
            return true
        }
        guard engine == .openAITranscribe else { return false }
        if case .connected = fallbackState {
            return true
        }
        return false
    }
}

enum QuickDictationStartPolicy {
    static func startsWhilePreparing(
        isFinalTranscriberReady: Bool,
        engine: TranscriptRefinementEngine,
        transcriberState: SocketState
    ) -> Bool {
        guard !isFinalTranscriberReady, !engine.isCloud else { return false }
        if case .connecting = transcriberState {
            return true
        }
        return false
    }
}

struct QuickDictationWorkState<Target> {
    private var targetsByTranscriptionID: [String: Target] = [:]

    var pendingTranscriptionIDs: Set<String> {
        Set(targetsByTranscriptionID.keys)
    }

    var hasPendingTranscriptions: Bool {
        !targetsByTranscriptionID.isEmpty
    }

    mutating func submit(transcriptID: String, target: Target) {
        targetsByTranscriptionID[transcriptID] = target
    }

    func value(for transcriptID: String) -> Target? {
        targetsByTranscriptionID[transcriptID]
    }

    @discardableResult
    mutating func complete(transcriptID: String) -> Target? {
        targetsByTranscriptionID.removeValue(forKey: transcriptID)
    }

    mutating func reset() {
        targetsByTranscriptionID.removeAll()
    }

    func phase(
        isRunning: Bool,
        isRecording: Bool,
        isModelReady: Bool,
        engine: TranscriptRefinementEngine
    ) -> DictationPhase {
        if isRecording {
            return isModelReady
                ? .recording
                : .recordingWhilePreparing(engine)
        }
        if hasPendingTranscriptions {
            return isModelReady
                ? .transcribing
                : .waitingForModel(engine)
        }
        if !isRunning {
            return .off
        }
        if !isModelReady {
            return .preparing(engine)
        }
        return .ready
    }
}

enum QuickDictationStreamEventRouting {
    static func acceptsCompletion(
        streamID: String,
        pendingTranscriptionIDs: Set<String>
    ) -> Bool {
        pendingTranscriptionIDs.contains(streamID)
    }

    static func acceptsFailure(
        streamID: String,
        activeStreamID: String?,
        pendingTranscriptionIDs: Set<String>
    ) -> Bool {
        activeStreamID == streamID
            || pendingTranscriptionIDs.contains(streamID)
    }
}

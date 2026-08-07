import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import OSLog

enum ModifierHoldSignal: Equatable {
    case pressed
    case released
    case cancelled
}

struct ModifierHoldState {
    private(set) var isHeld = false

    mutating func update(flags: CGEventFlags) -> ModifierHoldSignal? {
        let isExactChord = Self.isExactChord(flags)

        if isExactChord, !isHeld {
            isHeld = true
            return .pressed
        }
        if !isExactChord, isHeld {
            isHeld = false
            return .released
        }
        return nil
    }

    mutating func synchronize(flags: CGEventFlags) {
        isHeld = Self.isExactChord(flags)
    }

    mutating func cancelForKeyDown() -> ModifierHoldSignal? {
        guard isHeld else { return nil }
        isHeld = false
        return .cancelled
    }

    mutating func reset() {
        isHeld = false
    }

    private static func isExactChord(_ flags: CGEventFlags) -> Bool {
        let hasRequiredModifiers = flags.contains(.maskCommand)
            && flags.contains(.maskAlternate)
        let hasDisallowedModifiers = flags.contains(.maskControl)
            || flags.contains(.maskShift)
            || flags.contains(.maskSecondaryFn)
        return hasRequiredModifiers && !hasDisallowedModifiers
    }
}

final class ModifierHoldMonitor {
    typealias SignalHandler = (
        _ signal: ModifierHoldSignal,
        _ focusedApplication: NSRunningApplication?
    ) -> Void

    static let diagnosticEventTag: Int64 = 0x4D_43_44_54
    static let pasteEventTag: Int64 = 0x4D_43_50_53
    private static let logger = Logger(
        subsystem: "com.permanentunderclass.meetingcopilot",
        category: "QuickDictationHotkey"
    )
    private let signalHandler: SignalHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installedRunLoop: CFRunLoop?
    private var retainedSelf: Unmanaged<ModifierHoldMonitor>?
    private var state = ModifierHoldState()
    private var isDiagnosticHold = false

    init(signalHandler: @escaping SignalHandler) {
        self.signalHandler = signalHandler
    }

    static func shouldCancelForKeyDown(
        eventTag: Int64,
        isDiagnosticHold: Bool
    ) -> Bool {
        !isDiagnosticHold && eventTag != pasteEventTag
    }

    func start() throws {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            throw MeetingCopilotError.audio(
                "Accessibility permission is required for the global dictation shortcut."
            )
        }

        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierHoldMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            retainedSelf = nil
            throw MeetingCopilotError.audio(
                "The global dictation shortcut could not be installed. Check Accessibility permission."
            )
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        eventTap = tap
        runLoopSource = source
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.synchronize(flags: CGEventSource.flagsState(.combinedSessionState))
        Self.logger.notice("event_tap_installed")
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource, let installedRunLoop {
            CFRunLoopRemoveSource(installedRunLoop, runLoopSource, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        state.reset()
        isDiagnosticHold = false
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.logger.error("event_tap_disabled type=\(type.rawValue, privacy: .public)")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            state.synchronize(flags: CGEventSource.flagsState(.combinedSessionState))
            return Unmanaged.passUnretained(event)
        }

        let signal: ModifierHoldSignal?
        switch type {
        case .flagsChanged:
            signal = state.update(flags: event.flags)
            if signal == .pressed {
                isDiagnosticHold = event.getIntegerValueField(.eventSourceUserData)
                    == Self.diagnosticEventTag
            } else if signal == .released {
                isDiagnosticHold = false
            }
        case .keyDown:
            let eventTag = event.getIntegerValueField(.eventSourceUserData)
            signal = Self.shouldCancelForKeyDown(
                eventTag: eventTag,
                isDiagnosticHold: isDiagnosticHold
            ) ? state.cancelForKeyDown() : nil
            if signal == .cancelled {
                isDiagnosticHold = false
            }
        default:
            signal = nil
        }
        if let signal {
            // Capture the receiving app in the event-tap turn itself. The
            // handler runs on the next main-queue turn, by which time another
            // process may already have taken focus.
            let focusedApplication = signal == .pressed
                ? NSWorkspace.shared.frontmostApplication
                : nil
            Self.logger.notice(
                "shortcut_signal=\(String(describing: signal), privacy: .public) flags=\(event.flags.rawValue, privacy: .public)"
            )
            DispatchQueue.main.async { [signalHandler, focusedApplication] in
                signalHandler(signal, focusedApplication)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }
}

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
        punctuation, and the language or languages spoken.
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
            return .recording
        }
        if hasPendingTranscriptions {
            return .transcribing
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

private struct QuickDictationPendingTranscription {
    let pasteTarget: QuickDictationPasteTarget?
    let recovery: QuickDictationRecoveryEntry
    let request: RealtimeRefinementRequest
}

final class HoldToDictateService {
    typealias PhaseHandler = (DictationPhase) -> Void
    typealias PermissionHandler = (DictationPermissionState) -> Void
    typealias RecordingHandler = (Bool) -> Void
    typealias MicrophoneHandler = (String) -> Void
    typealias TelemetryHandler = (TrackTelemetry) -> Void
    typealias PartialHandler = (String) -> Void
    typealias ResultHandler = (String) -> Bool
    typealias UsageHandler = (OpenAITranscriptionUsageRecord) -> Void
    typealias ProgressHandler = (DictationTranscriptionProgress?) -> Void
    typealias DeliveryHandler = (QuickDictationDeliveryOutcome) -> Void
    typealias RecoveriesHandler = ([QuickDictationRecoveryEntry]) -> Void
    typealias ContextProvider = () throws -> TranscriptionContext

    private static let logger = Logger(
        subsystem: "com.permanentunderclass.meetingcopilot",
        category: "QuickDictationCapture"
    )
    private let canRecord: () -> Bool
    private let expectedLanguages: () -> [String]
    private let contextProvider: ContextProvider
    private let shouldProduceLivePreview: () -> Bool
    private let shouldCleanDictation: () -> Bool
    private let phaseHandler: PhaseHandler
    private let permissionHandler: PermissionHandler
    private let recordingHandler: RecordingHandler
    private let microphoneHandler: MicrophoneHandler
    private let telemetryHandler: TelemetryHandler
    private let partialHandler: PartialHandler
    private let resultHandler: ResultHandler
    private let usageHandler: UsageHandler
    private let progressHandler: ProgressHandler
    private let deliveryHandler: DeliveryHandler
    private let recoveriesHandler: RecoveriesHandler
    private let recoveryStore: QuickDictationRecoveryStore
    private let transcribesAfterRecording: Bool
    private let transcriptionEngine: TranscriptRefinementEngine
    private let apiKey: String

    private lazy var monitor = ModifierHoldMonitor { [weak self] signal, application in
        self?.handle(signal, initialApplication: application)
    }
    private var microphoneCapture: CaptureSessionMicrophoneCapture?
    private var pipeline: AudioTrackPipeline?
    private var audioBuffer: LockedAudioBuffer?
    private var recordingID: UUID?
    private var recordingTarget: QuickDictationPasteTarget?
    private var transcriber: TranscriptRefining?
    private var fallbackTranscriber: TranscriptRefining?
    private var fallbackTranscriberState: SocketState = .idle
    private var fallbackTranscriptionIDs: Set<String> = []
    private var primaryFailureMessages: [String: String] = [:]
    private var fallbackFailureMessages: [String: String] = [:]
    private var fallbackWatchdogWorkItems: [String: DispatchWorkItem] = [:]
    private var activeRecoveryIDs: Set<UUID> = []
    private var workState = QuickDictationWorkState<QuickDictationPendingTranscription>()
    private var transcriptionStartUptimes: [String: UInt64] = [:]
    private let pasteInjector = PasteInjector()
    private var activeLivePreviewID: String?
    private var livePreviewWorkItem: DispatchWorkItem?
    private var lastLivePreviewByteCount = 0
    private var activeStreamID: String?
    private var streamDidFail = false
    private var streamSegmentWorkItem: DispatchWorkItem?
    private var streamCommittedByteCount = 0
    private var generation = UUID()
    private var transcriberState: SocketState = .idle
    private var reconnectPolicy = QuickDictationReconnectPolicy()
    private var reconnectWorkItem: DispatchWorkItem?
    private var isModelReady = false
    private var wantsEnabled = false
    private(set) var isRunning = false

    init(
        canRecord: @escaping () -> Bool,
        expectedLanguages: @escaping () -> [String],
        transcriptionContext: ContextProvider? = nil,
        shouldProduceLivePreview: @escaping () -> Bool = { true },
        shouldCleanDictation: @escaping () -> Bool = { true },
        onPhase: @escaping PhaseHandler,
        onPermissions: @escaping PermissionHandler,
        onRecording: @escaping RecordingHandler,
        onMicrophone: @escaping MicrophoneHandler = { _ in },
        onTelemetry: @escaping TelemetryHandler,
        onPartial: @escaping PartialHandler = { _ in },
        onResult: @escaping ResultHandler,
        onUsage: @escaping UsageHandler = { _ in },
        onProgress: @escaping ProgressHandler = { _ in },
        onDelivery: @escaping DeliveryHandler = { _ in },
        onRecoveries: @escaping RecoveriesHandler = { _ in },
        recoveryStore: QuickDictationRecoveryStore = .applicationSupport(),
        transcriptionEngine: TranscriptRefinementEngine = .localWhisper,
        apiKey: String = "",
        transcribesAfterRecording: Bool = true
    ) {
        self.canRecord = canRecord
        self.expectedLanguages = expectedLanguages
        contextProvider = transcriptionContext ?? {
            TranscriptionContext(
                prompt: "",
                keywords: [],
                languages: expectedLanguages(),
                delay: .medium
            )
        }
        self.shouldProduceLivePreview = shouldProduceLivePreview
        self.shouldCleanDictation = shouldCleanDictation
        phaseHandler = onPhase
        permissionHandler = onPermissions
        recordingHandler = onRecording
        microphoneHandler = onMicrophone
        telemetryHandler = onTelemetry
        partialHandler = onPartial
        resultHandler = onResult
        usageHandler = onUsage
        progressHandler = onProgress
        deliveryHandler = onDelivery
        recoveriesHandler = onRecoveries
        self.recoveryStore = recoveryStore
        self.transcriptionEngine = transcriptionEngine
        self.apiKey = apiKey
        self.transcribesAfterRecording = transcribesAfterRecording
    }

    @discardableResult
    func enable(requestAccess: Bool) -> Bool {
        wantsEnabled = true
        if isRunning { return true }

        var permissions = Self.currentPermissions()
        permissionHandler(permissions)
        if !permissions.allGranted, requestAccess {
            permissions = Self.requestPermissions { [weak self] in
                guard let self, self.wantsEnabled else { return }
                let updated = Self.currentPermissions()
                self.permissionHandler(updated)
                if updated.allGranted {
                    _ = self.enable(requestAccess: false)
                }
            }
            permissionHandler(permissions)
        }
        guard permissions.allGranted else {
            phaseHandler(.needsPermission)
            return false
        }
        guard
            transcriptionEngine != .openAITranscribe
                || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            phaseHandler(.failed("Save an OpenAI API key before using Quick Dictation with GPT-Transcribe."))
            return false
        }

        do {
            try monitor.start()
            isRunning = true
            isModelReady = false
            transcriberState = .idle
            reconnectPolicy.reset()
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            generation = UUID()
            connectTranscriber(generation: generation)
            connectFallbackTranscriberIfNeeded()
            publishRecoveries()
            return true
        } catch {
            phaseHandler(.failed(error.localizedDescription))
            return false
        }
    }

    func disable() {
        let hadActiveWork = wantsEnabled
            || isRunning
            || recordingID != nil
            || transcriber != nil
            || workState.hasPendingTranscriptions
            || activeLivePreviewID != nil
            || livePreviewWorkItem != nil
            || activeStreamID != nil
            || reconnectWorkItem != nil
        wantsEnabled = false
        guard hadActiveWork else { return }
        generation = UUID()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectPolicy.reset()
        monitor.stop()
        stopLivePreview()
        discardDictationStream()
        cancelRecording(nextPhase: .off)
        pasteInjector.cancel()
        transcriber?.disconnect()
        transcriber = nil
        fallbackTranscriber?.disconnect()
        fallbackTranscriber = nil
        fallbackTranscriberState = .idle
        fallbackWatchdogWorkItems.values.forEach { $0.cancel() }
        fallbackWatchdogWorkItems.removeAll()
        fallbackTranscriptionIDs.removeAll()
        primaryFailureMessages.removeAll()
        fallbackFailureMessages.removeAll()
        activeRecoveryIDs.removeAll()
        workState.reset()
        transcriptionStartUptimes.removeAll()
        transcriberState = .idle
        isModelReady = false
        isRunning = false
    }

    func setLivePreviewEnabled(_ enabled: Bool) {
        guard transcribesAfterRecording else { return }
        guard enabled else {
            stopLivePreview()
            return
        }
        // A streamed dictation already emits live text from the transcription
        // socket, so only the sampling loop needs starting here.
        guard
            availableStreamingTranscriber == nil,
            let recordingID,
            activeLivePreviewID == nil,
            livePreviewWorkItem == nil
        else {
            return
        }
        scheduleLivePreview(recordingID: recordingID)
    }

    @discardableResult
    func retryRecovery(_ recovery: QuickDictationRecoveryEntry) -> Bool {
        guard isRunning else {
            phaseHandler(.failed("Enable Quick Dictation before retrying this recording."))
            return false
        }
        guard isAnyFinalTranscriberReady else {
            phaseHandler(.preparing(transcriptionEngine))
            return false
        }
        guard activeRecoveryIDs.insert(recovery.id).inserted else {
            phaseHandler(.transcribing)
            return false
        }
        guard let transcriber else {
            activeRecoveryIDs.remove(recovery.id)
            retainRecovery(
                recovery,
                message: "The selected Quick Dictation model is unavailable."
            )
            return false
        }

        let audio: Data
        do {
            audio = try recoveryStore.pcm16Audio(for: recovery)
        } catch {
            activeRecoveryIDs.remove(recovery.id)
            retainRecovery(
                recovery,
                message: "The retained recording could not be read: \(error.localizedDescription)"
            )
            return false
        }

        let transcriptID = "dictation-recovery-\(recovery.id.uuidString)"
        let languages = recovery.languages.isEmpty
            ? expectedLanguages()
            : recovery.languages
        let context: TranscriptionContext
        do {
            context = try makeTranscriptionContext(
                delay: .medium,
                languages: languages
            )
        } catch {
            activeRecoveryIDs.remove(recovery.id)
            retainRecovery(recovery, message: error.localizedDescription)
            return false
        }
        let request = RealtimeRefinementRequest(
            transcriptID: transcriptID,
            speaker: .you,
            pcm16Audio: audio,
            context: context,
            recentTranscript: ""
        )
        workState.submit(
            transcriptID: transcriptID,
            target: QuickDictationPendingTranscription(
                pasteTarget: nil,
                recovery: recovery,
                request: request
            )
        )
        transcriptionStartUptimes[transcriptID] =
            DispatchTime.now().uptimeNanoseconds
        phaseHandler(currentWorkPhase())
        Self.logger.notice(
            "transcription_retry_started recovery_id=\(recovery.id.uuidString, privacy: .public) pending=\(self.workState.pendingTranscriptionIDs.count, privacy: .public)"
        )
        transcriber.refine(request)
        return true
    }

    static func currentPermissions() -> DictationPermissionState {
        let accessibilityTrusted = AXIsProcessTrusted()
        return DictationPermissionState(
            canMonitorKeyboard: accessibilityTrusted,
            canPasteIntoOtherApps: accessibilityTrusted,
            canUseMicrophone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }

    static func requestPermissions(
        onMicrophoneDecision: (() -> Void)? = nil
    ) -> DictationPermissionState {
        if !AXIsProcessTrusted() {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)

            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(700)) {
                openAccessibilitySettings()
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    onMicrophoneDecision?()
                }
            }
        }
        return currentPermissions()
    }

    private static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func connectTranscriber(generation: UUID) {
        transcriberState = .connecting
        if recordingID == nil, !workState.hasPendingTranscriptions {
            phaseHandler(.preparing(transcriptionEngine))
        }
        let callbacks = DictationTranscriberCallbacks(
            onState: { [weak self] state in
                self?.handleTranscriberState(state, generation: generation)
            },
            onRefined: { [weak self] transcriptID, text in
                self?.handleTranscription(
                    transcriptID: transcriptID,
                    text: text,
                    generation: generation
                )
            },
            onFailure: { [weak self] transcriptID, message in
                self?.handleTranscriptionFailure(
                    transcriptID: transcriptID,
                    message: message,
                    generation: generation
                )
            },
            onUsage: { [usageHandler] usage in
                usageHandler(usage)
            },
            onCommitted: { [weak self] transcriptID in
                self?.handlePrimaryTranscriptionCommitted(
                    transcriptID: transcriptID,
                    generation: generation
                )
            },
            onStreamPartial: { [weak self] streamID, text in
                self?.handleStreamPartial(
                    streamID: streamID,
                    text: text,
                    generation: generation
                )
            },
            onStreamCompleted: { [weak self] streamID, text in
                self?.handleStreamCompleted(
                    streamID: streamID,
                    text: text,
                    generation: generation
                )
            },
            onStreamFailed: { [weak self] streamID, message in
                self?.handleStreamFailure(
                    streamID: streamID,
                    message: message,
                    generation: generation
                )
            },
            onUploadProgress: { [weak self] transcriptID, sentBytes, totalBytes in
                self?.handleUploadProgress(
                    transcriptID: transcriptID,
                    sentBytes: sentBytes,
                    totalBytes: totalBytes,
                    generation: generation
                )
            }
        )
        let transcriber = QuickDictationTranscriberFactory.make(
            engine: transcriptionEngine,
            apiKey: apiKey,
            callbacks: callbacks
        )
        self.transcriber = transcriber
        transcriber.connect()
    }

    private func connectFallbackTranscriberIfNeeded() {
        guard
            transcriptionEngine == .openAITranscribe,
            fallbackTranscriber == nil
        else {
            return
        }
        let fallback = WhisperRefinementClient(
            onState: { [weak self] state in
                self?.handleFallbackTranscriberState(state)
            },
            onRefined: { [weak self] transcriptID, text in
                self?.handleFallbackTranscription(
                    transcriptID: transcriptID,
                    text: text
                )
            },
            onFailure: { [weak self] transcriptID, message in
                self?.handleFallbackTranscriptionFailure(
                    transcriptID: transcriptID,
                    message: message
                )
            }
        )
        fallbackTranscriber = fallback
        fallbackTranscriberState = .connecting
        fallback.connect()
    }

    private func handleTranscriberState(
        _ state: SocketState,
        generation: UUID
    ) {
        guard self.generation == generation, isRunning else { return }
        transcriberState = state
        let reconnectDelay = reconnectPolicy.reconnectDelay(
            after: state,
            engine: transcriptionEngine
        )
        switch state {
        case .idle:
            isModelReady = false
            if recordingID == nil, !workState.hasPendingTranscriptions {
                phaseHandler(
                    isFallbackReady ? .ready : .preparing(transcriptionEngine)
                )
            }
        case .connecting:
            isModelReady = false
            if recordingID == nil, !workState.hasPendingTranscriptions {
                phaseHandler(
                    isFallbackReady ? .ready : .preparing(transcriptionEngine)
                )
            }
        case .connected:
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            isModelReady = true
            if recordingID == nil, !workState.hasPendingTranscriptions {
                phaseHandler(.ready)
            }
        case let .failed(message):
            isModelReady = false
            if recordingID == nil, !workState.hasPendingTranscriptions {
                phaseHandler(isFallbackReady ? .ready : .failed(message))
            } else {
                Self.logger.error(
                    "transcriber_failed_with_active_capture_or_recovery error=\(message, privacy: .public)"
                )
                phaseHandler(currentWorkPhase())
            }
        }
        if let reconnectDelay {
            scheduleTranscriberReconnect(
                after: reconnectDelay,
                generation: generation
            )
        }
    }

    private func handleFallbackTranscriberState(_ state: SocketState) {
        fallbackTranscriberState = state
        if case let .failed(message) = state {
            Self.logger.error(
                "fallback_transcriber_unavailable error=\(message, privacy: .public)"
            )
        }
        guard
            transcriptionEngine == .openAITranscribe,
            !isModelReady,
            recordingID == nil,
            !workState.hasPendingTranscriptions,
            isFallbackReady
        else {
            return
        }
        Self.logger.notice("fallback_transcriber_ready_while_cloud_unavailable")
        phaseHandler(.ready)
    }

    private func scheduleTranscriberReconnect(
        after delay: TimeInterval,
        generation: UUID
    ) {
        guard transcriptionEngine == .openAITranscribe, isRunning else { return }
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.isRunning,
                self.generation == generation
            else {
                return
            }
            self.reconnectWorkItem = nil
            self.restartTranscriber()
        }
        reconnectWorkItem = workItem
        Self.logger.notice(
            "transcriber_reconnect_scheduled delay_ms=\(Int(delay * 1_000), privacy: .public)"
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func restartTranscriber() {
        guard transcriptionEngine == .openAITranscribe, isRunning else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        let previousTranscriber = transcriber
        let nextGeneration = UUID()
        generation = nextGeneration
        transcriber = nil
        transcriberState = .connecting
        isModelReady = false
        previousTranscriber?.disconnect()
        Self.logger.notice("transcriber_reconnecting")
        connectTranscriber(generation: nextGeneration)
    }

    private func handle(
        _ signal: ModifierHoldSignal,
        initialApplication: NSRunningApplication?
    ) {
        switch signal {
        case .pressed:
            startRecording(initialApplication: initialApplication)
        case .released:
            finishRecording()
        case .cancelled:
            cancelRecording()
        }
    }

    private func startRecording(
        initialApplication: NSRunningApplication?
    ) {
        guard isRunning, recordingID == nil else { return }
        guard isAnyFinalTranscriberReady else {
            if transcriptionEngine == .openAITranscribe,
               transcriberState != .connecting {
                restartTranscriber()
            } else {
                phaseHandler(.preparing(transcriptionEngine))
            }
            return
        }
        guard canRecord() else {
            phaseHandler(.failed("Quick Dictation is unavailable while meeting capture is active."))
            return
        }
        let pasteTarget: QuickDictationPasteTarget?
        if transcribesAfterRecording {
            guard
                let capturedTarget = QuickDictationPasteTarget.capture(
                    initialApplication: initialApplication
                )
            else {
                phaseHandler(
                    .failed("Quick Dictation could not identify the focused app that should receive the text.")
                )
                return
            }
            pasteTarget = capturedTarget
        } else {
            pasteTarget = nil
        }

        let currentRecordingID = UUID()
        let buffer = LockedAudioBuffer()

        // Streaming uploads audio as the user speaks so that releasing the
        // shortcut only leaves the tail to send. The stream handle and ID are
        // captured here rather than read from the audio thread, so the capture
        // callback never races with the main-actor state below.
        let streamHandle = availableStreamingTranscriber
        let streamID = streamHandle == nil
            ? nil
            : "dictation-\(UUID().uuidString)"

        let pipeline = AudioTrackPipeline(
            label: "MeetingCopilot.Audio.Dictation",
            onChunk: { chunk in
                buffer.append(chunk)
                if let streamHandle, let streamID {
                    streamHandle.appendStream(
                        streamID: streamID,
                        pcm16Audio: chunk
                    )
                }
            },
            onTelemetry: { [telemetryHandler] telemetry in
                telemetryHandler(telemetry)
            }
        )
        let capture = CaptureSessionMicrophoneCapture()

        recordingID = currentRecordingID
        recordingTarget = pasteTarget
        audioBuffer = buffer
        self.pipeline = pipeline
        microphoneCapture = capture
        recordingHandler(true)
        phaseHandler(.recording)
        partialHandler("")
        progressHandler(nil)
        beginDictationStream(
            streamHandle,
            streamID: streamID,
            recordingID: currentRecordingID
        )
        if transcribesAfterRecording, shouldProduceLivePreview(),
           streamID == nil {
            // The stream produces its own live text, so the sampling preview
            // loop only runs for engines that cannot stream.
            scheduleLivePreview(recordingID: currentRecordingID)
        }
        Self.logger.notice("recording_started")

        startMicrophoneCapture(
            capture,
            recordingID: currentRecordingID,
            pipeline: pipeline
        )
    }

    private func startMicrophoneCapture(
        _ capture: CaptureSessionMicrophoneCapture,
        recordingID currentRecordingID: UUID,
        pipeline: AudioTrackPipeline
    ) {
        capture.start(
            onBuffer: { audio in
                pipeline.submit(audio)
            },
            completion: { [weak self, weak capture] result in
                DispatchQueue.main.async {
                    guard
                        let self,
                        let capture,
                        self.recordingID == currentRecordingID,
                        self.microphoneCapture === capture
                    else {
                        capture?.stop()
                        return
                    }
                    switch result {
                    case let .success(microphoneName):
                        self.microphoneHandler(microphoneName)
                    case let .failure(error):
                        self.cancelRecording(nextPhase: .failed(error.localizedDescription))
                    }
                }
            }
        )
    }

    private func finishRecording() {
        guard recordingID != nil else { return }
        let capture = microphoneCapture
        let pipeline = pipeline
        let buffer = audioBuffer
        let pasteTarget = recordingTarget

        microphoneCapture = nil
        self.pipeline = nil
        audioBuffer = nil
        self.recordingID = nil
        recordingTarget = nil
        capture?.stop()
        pipeline?.finish()
        stopLivePreview()
        cancelInFlightPreviewWork()
        stopStreamSegmentScheduling()
        recordingHandler(false)

        let audio = buffer?.take() ?? Data()
        let peak = PCM16SignalGate.peakMagnitude(audio)
        Self.logger.notice(
            "recording_finished bytes=\(audio.count, privacy: .public) peak=\(peak, privacy: .public)"
        )
        guard transcribesAfterRecording else {
            discardDictationStream()
            phaseHandler(currentWorkPhase())
            return
        }
        guard audio.count >= 4_800 else {
            Self.logger.notice("recording_skipped reason=too_short")
            discardDictationStream()
            phaseHandler(currentWorkPhase())
            return
        }
        guard peak >= 64 else {
            Self.logger.notice("recording_skipped reason=silence")
            discardDictationStream()
            phaseHandler(currentWorkPhase())
            return
        }

        let languages = expectedLanguages()
        // A streamed dictation keeps the ID it was opened with so the transcript
        // that arrives can be matched to this recording's paste target.
        let streamedID = streamDidFail ? nil : activeStreamID
        let transcriptID = streamedID ?? "dictation-\(UUID().uuidString)"
        let recovery: QuickDictationRecoveryEntry
        do {
            recovery = try recoveryStore.preserve(
                pcm16Audio: audio,
                languages: languages
            )
            publishRecoveries()
            Self.logger.notice(
                "recording_retained recovery_id=\(recovery.id.uuidString, privacy: .public)"
            )
        } catch {
            Self.logger.fault(
                "recording_retention_failed error=\(error.localizedDescription, privacy: .public)"
            )
            phaseHandler(
                .failed(
                    "Quick Dictation could not safely retain this recording: \(error.localizedDescription)"
                )
            )
            return
        }
        guard let transcriber else {
            retainRecovery(
                recovery,
                message: "The selected Quick Dictation model is unavailable."
            )
            return
        }
        let context: TranscriptionContext
        do {
            context = try makeTranscriptionContext(
                delay: .medium,
                languages: languages
            )
        } catch {
            retainRecovery(recovery, message: error.localizedDescription)
            return
        }
        let request = RealtimeRefinementRequest(
            transcriptID: transcriptID,
            speaker: .you,
            pcm16Audio: audio,
            context: context,
            recentTranscript: ""
        )
        workState.submit(
            transcriptID: transcriptID,
            target: QuickDictationPendingTranscription(
                pasteTarget: pasteTarget,
                recovery: recovery,
                request: request
            )
        )
        activeRecoveryIDs.insert(recovery.id)
        transcriptionStartUptimes[transcriptID] =
            DispatchTime.now().uptimeNanoseconds
        phaseHandler(currentWorkPhase())
        Self.logger.notice(
            "transcription_started pending=\(self.workState.pendingTranscriptionIDs.count, privacy: .public) streamed=\(streamedID != nil, privacy: .public)"
        )

        if let streamedID, let streaming = availableStreamingTranscriber {
            // The audio is already at the provider; only the tail and the final
            // commit remain, so the fallback watchdog starts now.
            progressHandler(.finishing)
            streaming.finishStream(streamID: streamedID)
            handlePrimaryTranscriptionCommitted(
                transcriptID: streamedID,
                generation: generation
            )
            return
        }

        discardDictationStream()
        progressHandler(.uploading(fraction: 0))
        transcriber.refine(request)
    }

    // MARK: - Streaming dictation

    /// The primary transcriber when it can accept audio during recording.
    private var availableStreamingTranscriber: TranscriptStreaming? {
        guard
            transcribesAfterRecording,
            let streaming = transcriber as? TranscriptStreaming,
            streaming.supportsStreaming
        else {
            return nil
        }
        return streaming
    }

    private func beginDictationStream(
        _ streaming: TranscriptStreaming?,
        streamID: String?,
        recordingID: UUID
    ) {
        activeStreamID = nil
        streamDidFail = false
        streamCommittedByteCount = 0
        guard let streaming, let streamID else { return }
        let context: TranscriptionContext
        do {
            context = try makeTranscriptionContext(
                delay: .medium,
                languages: expectedLanguages()
            )
        } catch {
            // Without a context the stream cannot be configured; the batch path
            // at release still produces the transcript.
            Self.logger.error(
                "stream_context_failed error=\(error.localizedDescription, privacy: .public)"
            )
            streamDidFail = true
            return
        }
        activeStreamID = streamID
        streaming.beginStream(
            DictationStreamStart(streamID: streamID, context: context)
        )
        scheduleStreamSegmentCheck(recordingID: recordingID)
    }

    /// Closes a segment when the user pauses, so its transcript comes back
    /// while they keep talking instead of piling up for the final commit.
    private func scheduleStreamSegmentCheck(recordingID: UUID) {
        streamSegmentWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateStreamSegment(recordingID: recordingID)
        }
        streamSegmentWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(500),
            execute: workItem
        )
    }

    private func evaluateStreamSegment(recordingID currentRecordingID: UUID) {
        streamSegmentWorkItem = nil
        guard
            recordingID == currentRecordingID,
            let streamID = activeStreamID,
            !streamDidFail,
            let streaming = availableStreamingTranscriber,
            let buffer = audioBuffer
        else {
            return
        }
        let totalBytes = buffer.count
        let segmentBytes = max(0, totalBytes - streamCommittedByteCount)
        let segmentSeconds = Double(segmentBytes)
            / Double(QuickDictationStreamPolicy.captureBytesPerSecond)
        let trailingBytes = Int(
            Double(QuickDictationStreamPolicy.captureBytesPerSecond)
                * DictationSegmentCommitPolicy.trailingSilenceSeconds
        )
        let trailingIsSilent = !PCM16SignalGate.containsAudibleSignal(
            buffer.tail(trailingBytes),
            minimumPeak: QuickDictationStreamPolicy.pausePeakThreshold
        )
        if DictationSegmentCommitPolicy.shouldCommit(
            segmentSeconds: segmentSeconds,
            trailingIsSilent: trailingIsSilent
        ) {
            streaming.commitStreamSegment(streamID: streamID)
            streamCommittedByteCount = totalBytes
            Self.logger.notice(
                "stream_segment_committed seconds=\(Int(segmentSeconds), privacy: .public) silent_boundary=\(trailingIsSilent, privacy: .public)"
            )
        }
        scheduleStreamSegmentCheck(recordingID: currentRecordingID)
    }

    private func stopStreamSegmentScheduling() {
        streamSegmentWorkItem?.cancel()
        streamSegmentWorkItem = nil
    }

    /// Abandons the open stream without publishing a result, for recordings
    /// that will never be transcribed or that fall back to the batch upload.
    private func discardDictationStream() {
        stopStreamSegmentScheduling()
        if let activeStreamID {
            availableStreamingTranscriber?.cancelStream(streamID: activeStreamID)
        }
        activeStreamID = nil
        streamDidFail = false
        streamCommittedByteCount = 0
    }

    private func handleStreamPartial(
        streamID: String,
        text: String,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            isRunning,
            activeStreamID == streamID
        else {
            return
        }
        let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return }
        partialHandler(partial)
    }

    private func handleStreamCompleted(
        streamID: String,
        text: String,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            isRunning,
            activeStreamID == streamID
        else {
            return
        }
        activeStreamID = nil
        streamCommittedByteCount = 0
        progressHandler(nil)
        completeFinalTranscription(transcriptID: streamID, text: text)
    }

    private func handleStreamFailure(
        streamID: String,
        message: String,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            isRunning,
            activeStreamID == streamID
        else {
            return
        }
        Self.logger.error(
            "stream_unavailable error=\(message, privacy: .public)"
        )
        streamDidFail = true
        activeStreamID = nil
        stopStreamSegmentScheduling()

        // Still recording: the buffer keeps filling and the batch upload at
        // release covers the whole take, so nothing is lost.
        guard recordingID == nil else { return }

        // Already released: the recording is retained, so resubmit it through
        // the batch path rather than dropping the dictation.
        guard let pending = workState.value(for: streamID) else { return }
        guard let transcriber else {
            handleTranscriptionFailure(
                transcriptID: streamID,
                message: message,
                generation: generation
            )
            return
        }
        Self.logger.notice(
            "stream_fallback_to_batch transcript_id=\(streamID, privacy: .public)"
        )
        progressHandler(.uploading(fraction: 0))
        transcriber.refine(pending.request)
    }

    private func handleUploadProgress(
        transcriptID: String,
        sentBytes: Int,
        totalBytes: Int,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            isRunning,
            totalBytes > 0,
            workState.value(for: transcriptID) != nil
        else {
            return
        }
        let fraction = Double(sentBytes) / Double(totalBytes)
        progressHandler(
            fraction >= 1 ? .transcribing : .uploading(fraction: fraction)
        )
    }

    /// Stops preview work that is already running. A preview issued moments
    /// before release would otherwise keep competing with the transcription the
    /// user is waiting for.
    private func cancelInFlightPreviewWork() {
        guard activeLivePreviewID != nil else { return }
        activeLivePreviewID = nil
        transcriber?.cancelPendingRequests()
    }

    private func handleTranscription(
        transcriptID: String,
        text: String,
        generation: UUID
    ) {
        guard self.generation == generation, isRunning else { return }
        if activeLivePreviewID == transcriptID {
            activeLivePreviewID = nil
            guard let recordingID else { return }
            let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                partialHandler(partial)
            }
            scheduleLivePreview(recordingID: recordingID)
            return
        }

        completeFinalTranscription(transcriptID: transcriptID, text: text)
    }

    private func completeFinalTranscription(
        transcriptID: String,
        text: String
    ) {
        guard isRunning else { return }
        guard let pending = workState.complete(transcriptID: transcriptID) else {
            return
        }
        activeRecoveryIDs.remove(pending.recovery.id)
        cancelFallbackWatchdog(transcriptID: transcriptID)
        fallbackTranscriptionIDs.remove(transcriptID)
        primaryFailureMessages.removeValue(forKey: transcriptID)
        fallbackFailureMessages.removeValue(forKey: transcriptID)
        if let latencyMilliseconds = takeTranscriptionLatencyMilliseconds(
            transcriptID: transcriptID
        ) {
            Self.logger.notice(
                "transcription_received latency_ms=\(latencyMilliseconds, privacy: .public) characters=\(text.count, privacy: .public)"
            )
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            Self.logger.error("transcription_empty")
            retainRecovery(
                pending.recovery,
                message: "\(transcriptionEngine.title) returned no dictation text."
            )
            return
        }

        let textWasSaved = resultHandler(result)
        if textWasSaved {
            removeRecovery(pending.recovery)
        } else {
            retainRecovery(
                pending.recovery,
                message: "The transcript completed, but its text could not be saved to history."
            )
        }

        guard let pasteTarget = pending.pasteTarget else {
            Self.logger.notice(
                "transcription_recovered characters=\(result.count, privacy: .public)"
            )
            finishDelivery(
                .notDelivered(
                    reason: "This dictation has no destination field."
                ),
                text: result
            )
            return
        }

        // The user may have moved on during the transcription. Pasting into
        // wherever they are now, or dragging them back to where they were, is
        // never what they asked for.
        guard pasteTarget.isStillFrontmost else {
            let currentApplication = NSWorkspace.shared.frontmostApplication?
                .localizedName ?? "another app"
            Self.logger.notice(
                "paste_skipped_stale_target expected=\(pasteTarget.applicationName, privacy: .public) frontmost=\(currentApplication, privacy: .public)"
            )
            finishDelivery(
                .notDelivered(
                    reason: "You switched to \(currentApplication) while this was transcribing."
                ),
                text: result
            )
            return
        }

        pasteInjector.paste(result, into: pasteTarget) { [weak self] pasteResult in
            guard let self, self.isRunning else { return }
            switch pasteResult {
            case let .success(delivery):
                Self.logger.notice(
                    "transcription_completed characters=\(result.count, privacy: .public) paste_delivery=\(delivery.rawValue, privacy: .public)"
                )
                switch delivery {
                case .verified:
                    self.finishDelivery(.pasted, text: result)
                case .unverified:
                    self.finishDelivery(
                        .unverified(
                            applicationName: pasteTarget.applicationName
                        ),
                        text: result
                    )
                }
            case let .failure(error):
                Self.logger.error(
                    "paste_failed error=\(error.localizedDescription, privacy: .public)"
                )
                self.finishDelivery(
                    .notDelivered(reason: error.localizedDescription),
                    text: result
                )
            }
        }
    }

    /// Publishes the delivery outcome and, when nothing was pasted, leaves the
    /// text on the clipboard so it is one keystroke away instead of lost.
    ///
    /// Several dictations can be transcribing at once, so one going
    /// undeliverable says nothing about whether another is mid-paste. The
    /// clipboard write therefore goes through `PasteInjector`, which holds it
    /// until no posted Cmd+V could still pick it up by mistake.
    private func finishDelivery(
        _ outcome: QuickDictationDeliveryOutcome,
        text: String
    ) {
        if case .notDelivered = outcome {
            pasteInjector.offerOnClipboard(text)
        }
        deliveryHandler(outcome)
        progressHandler(nil)
        if recordingID == nil {
            phaseHandler(currentWorkPhase())
        }
    }

    private func handlePrimaryTranscriptionCommitted(
        transcriptID: String,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            isRunning,
            workState.value(for: transcriptID) != nil
        else {
            return
        }
        Self.logger.notice(
            "primary_audio_committed fallback_watchdog_ms=\(Int(QuickDictationFallbackPolicy.responseWatchdogSeconds * 1_000), privacy: .public)"
        )
        scheduleFallbackWatchdog(transcriptID: transcriptID)
    }

    private func scheduleFallbackWatchdog(transcriptID: String) {
        guard
            transcriptionEngine == .openAITranscribe,
            fallbackTranscriber != nil
        else {
            return
        }
        cancelFallbackWatchdog(transcriptID: transcriptID)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fallbackWatchdogWorkItems.removeValue(forKey: transcriptID)
            _ = self.startFallback(
                transcriptID: transcriptID,
                reason: "cloud_unresponsive_after_commit"
            )
        }
        fallbackWatchdogWorkItems[transcriptID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + QuickDictationFallbackPolicy.responseWatchdogSeconds,
            execute: workItem
        )
    }

    @discardableResult
    private func startFallback(
        transcriptID: String,
        reason: String
    ) -> Bool {
        cancelFallbackWatchdog(transcriptID: transcriptID)
        guard
            isRunning,
            let pending = workState.value(for: transcriptID),
            let fallbackTranscriber,
            fallbackFailureMessages[transcriptID] == nil,
            fallbackTranscriptionIDs.insert(transcriptID).inserted
        else {
            return false
        }
        Self.logger.notice(
            "transcription_fallback_started provider=LocalWhisper reason=\(reason, privacy: .public) recovery_id=\(pending.recovery.id.uuidString, privacy: .public)"
        )
        if case .failed = fallbackTranscriberState {
            Self.logger.notice("transcription_fallback_reconnecting provider=LocalWhisper")
            fallbackTranscriberState = .connecting
            fallbackTranscriber.connect()
        }
        fallbackTranscriber.refine(pending.request)
        return true
    }

    private func cancelFallbackWatchdog(transcriptID: String) {
        fallbackWatchdogWorkItems.removeValue(forKey: transcriptID)?.cancel()
    }

    private func handleTranscriptionFailure(
        transcriptID: String,
        message: String,
        generation: UUID
    ) {
        guard self.generation == generation, isRunning else { return }
        if activeLivePreviewID == transcriptID {
            activeLivePreviewID = nil
            Self.logger.error(
                "live_preview_failed error=\(message, privacy: .public)"
            )
            if let recordingID {
                scheduleLivePreview(recordingID: recordingID)
            }
            return
        }

        guard workState.value(for: transcriptID) != nil else {
            return
        }
        if let latencyMilliseconds = transcriptionLatencyMilliseconds(
            transcriptID: transcriptID
        ) {
            Self.logger.error(
                "primary_transcription_failed latency_ms=\(latencyMilliseconds, privacy: .public) error=\(message, privacy: .public)"
            )
        } else {
            Self.logger.error(
                "primary_transcription_failed error=\(message, privacy: .public)"
            )
        }
        guard transcriptionEngine == .openAITranscribe else {
            finalizeTranscriptionFailure(
                transcriptID: transcriptID,
                message: message
            )
            return
        }

        primaryFailureMessages[transcriptID] = message
        cancelFallbackWatchdog(transcriptID: transcriptID)
        if fallbackTranscriptionIDs.contains(transcriptID) {
            Self.logger.notice(
                "transcription_waiting_for_active_fallback provider=LocalWhisper"
            )
            return
        }
        if let fallbackMessage = fallbackFailureMessages[transcriptID] {
            finalizeTranscriptionFailure(
                transcriptID: transcriptID,
                message: combinedProviderFailureMessage(
                    primary: message,
                    fallback: fallbackMessage
                )
            )
            return
        }
        guard startFallback(
            transcriptID: transcriptID,
            reason: "cloud_failed"
        ) else {
            finalizeTranscriptionFailure(
                transcriptID: transcriptID,
                message: message
            )
            return
        }
    }

    private func handleFallbackTranscription(
        transcriptID: String,
        text: String
    ) {
        guard
            isRunning,
            fallbackTranscriptionIDs.remove(transcriptID) != nil
        else {
            return
        }
        Self.logger.notice(
            "transcription_fallback_completed provider=LocalWhisper"
        )
        completeFinalTranscription(transcriptID: transcriptID, text: text)
        resetCloudTranscriberAfterFallbackIfIdle()
    }

    private func handleFallbackTranscriptionFailure(
        transcriptID: String,
        message: String
    ) {
        guard
            isRunning,
            fallbackTranscriptionIDs.remove(transcriptID) != nil
        else {
            return
        }
        fallbackFailureMessages[transcriptID] = message
        guard let primaryMessage = primaryFailureMessages[transcriptID] else {
            Self.logger.error(
                "transcription_fallback_failed_primary_continues error=\(message, privacy: .public)"
            )
            return
        }
        finalizeTranscriptionFailure(
            transcriptID: transcriptID,
            message: combinedProviderFailureMessage(
                primary: primaryMessage,
                fallback: message
            )
        )
    }

    private func combinedProviderFailureMessage(
        primary: String,
        fallback: String
    ) -> String {
        "OpenAI: \(primary) Local Whisper: \(fallback)"
    }

    private func resetCloudTranscriberAfterFallbackIfIdle() {
        guard
            transcriptionEngine == .openAITranscribe,
            isRunning,
            recordingID == nil,
            !workState.hasPendingTranscriptions
        else {
            return
        }
        Self.logger.notice("cloud_transcriber_reset_after_fallback")
        restartTranscriber()
    }

    private func finalizeTranscriptionFailure(
        transcriptID: String,
        message: String
    ) {
        guard let pending = workState.complete(transcriptID: transcriptID) else {
            return
        }
        activeRecoveryIDs.remove(pending.recovery.id)
        cancelFallbackWatchdog(transcriptID: transcriptID)
        fallbackTranscriptionIDs.remove(transcriptID)
        primaryFailureMessages.removeValue(forKey: transcriptID)
        fallbackFailureMessages.removeValue(forKey: transcriptID)
        if let latencyMilliseconds = takeTranscriptionLatencyMilliseconds(
            transcriptID: transcriptID
        ) {
            Self.logger.error(
                "transcription_failed latency_ms=\(latencyMilliseconds, privacy: .public) error=\(message, privacy: .public)"
            )
        } else {
            Self.logger.error(
                "transcription_failed error=\(message, privacy: .public)"
            )
        }
        retainRecovery(pending.recovery, message: message)
    }

    private func transcriptionLatencyMilliseconds(
        transcriptID: String
    ) -> UInt64? {
        guard let start = transcriptionStartUptimes[transcriptID] else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }

    private func takeTranscriptionLatencyMilliseconds(
        transcriptID: String
    ) -> UInt64? {
        guard let start = transcriptionStartUptimes.removeValue(
            forKey: transcriptID
        ) else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return (now - start) / 1_000_000
    }

    private func retainRecovery(
        _ recovery: QuickDictationRecoveryEntry,
        message: String
    ) {
        let retainedMessage: String
        do {
            let updated = try recoveryStore.recordFailure(
                for: recovery,
                message: message
            )
            retainedMessage =
                "\(message) The recording is saved in Quick Dictation Recovery "
                + "(attempt \(updated.attemptCount))."
            Self.logger.notice(
                "recording_recovery_available recovery_id=\(updated.id.uuidString, privacy: .public) attempts=\(updated.attemptCount, privacy: .public)"
            )
        } catch {
            retainedMessage =
                "\(message) The recording package is still on disk, but its "
                + "recovery status could not be updated: \(error.localizedDescription)"
            Self.logger.fault(
                "recording_recovery_update_failed recovery_id=\(recovery.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        publishRecoveries()
        publishTranscriptionFailure(retainedMessage)
    }

    private func removeRecovery(_ recovery: QuickDictationRecoveryEntry) {
        do {
            try recoveryStore.remove(recovery)
            Self.logger.notice(
                "recording_recovery_removed recovery_id=\(recovery.id.uuidString, privacy: .public) reason=text_saved"
            )
        } catch {
            Self.logger.error(
                "recording_recovery_remove_failed recovery_id=\(recovery.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        publishRecoveries()
    }

    private func publishRecoveries() {
        do {
            recoveriesHandler(try recoveryStore.load())
        } catch {
            Self.logger.error(
                "recording_recovery_load_failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func publishTranscriptionFailure(_ message: String) {
        guard recordingID == nil else {
            Self.logger.error(
                "background_transcription_failed_while_recording error=\(message, privacy: .public)"
            )
            return
        }
        phaseHandler(.failed(message))
    }

    private func currentWorkPhase() -> DictationPhase {
        workState.phase(
            isRunning: isRunning,
            isRecording: recordingID != nil,
            isModelReady: isAnyFinalTranscriberReady,
            engine: transcriptionEngine
        )
    }

    private var isAnyFinalTranscriberReady: Bool {
        QuickDictationTranscriberAvailability.isReady(
            primaryReady: isModelReady,
            engine: transcriptionEngine,
            fallbackState: fallbackTranscriberState
        )
    }

    private var isFallbackReady: Bool {
        if case .connected = fallbackTranscriberState {
            return true
        }
        return false
    }

    private func makeTranscriptionContext(
        delay: TranscriptionDelay,
        languages: [String]? = nil
    ) throws -> TranscriptionContext {
        QuickDictationContextPolicy.context(
            from: try contextProvider(),
            cleanDictation: shouldCleanDictation(),
            delay: delay,
            languages: languages
        )
    }

    private func cancelRecording(nextPhase: DictationPhase? = nil) {
        stopLivePreview()
        discardDictationStream()
        microphoneCapture?.stop()
        pipeline?.finish()
        microphoneCapture = nil
        pipeline = nil
        audioBuffer = nil
        recordingID = nil
        recordingTarget = nil
        recordingHandler(false)
        phaseHandler(nextPhase ?? currentWorkPhase())
    }

    /// The selected transcribers consume committed clips, so the overlay
    /// periodically submits a bounded snapshot of the growing recording through
    /// that same selected model to produce genuine live hypotheses.
    private func scheduleLivePreview(recordingID: UUID) {
        livePreviewWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.produceLivePreview(recordingID: recordingID)
        }
        livePreviewWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(650),
            execute: workItem
        )
    }

    private func produceLivePreview(recordingID: UUID) {
        livePreviewWorkItem = nil
        guard self.recordingID == recordingID else { return }
        guard shouldProduceLivePreview() else {
            stopLivePreview()
            return
        }
        guard activeLivePreviewID == nil else {
            scheduleLivePreview(recordingID: recordingID)
            return
        }

        let bufferedAudio = audioBuffer?.snapshot() ?? Data()
        guard QuickDictationLivePreviewPolicy.shouldTranscribe(
            audioByteCount: bufferedAudio.count,
            lastTranscribedByteCount: lastLivePreviewByteCount
        ) else {
            scheduleLivePreview(recordingID: recordingID)
            return
        }
        guard PCM16SignalGate.containsAudibleSignal(bufferedAudio) else {
            scheduleLivePreview(recordingID: recordingID)
            return
        }

        lastLivePreviewByteCount = bufferedAudio.count
        let audio = QuickDictationLivePreviewPolicy.previewAudio(from: bufferedAudio)
        let context: TranscriptionContext
        do {
            context = try makeTranscriptionContext(delay: .minimal)
        } catch {
            Self.logger.error(
                "live_preview_context_failed error=\(error.localizedDescription, privacy: .public)"
            )
            scheduleLivePreview(recordingID: recordingID)
            return
        }
        guard let selectedPreviewTranscriber = transcriber else {
            scheduleLivePreview(recordingID: recordingID)
            return
        }
        let transcriptID = "dictation-preview-\(UUID().uuidString)"
        activeLivePreviewID = transcriptID
        selectedPreviewTranscriber.refine(
            RealtimeRefinementRequest(
                transcriptID: transcriptID,
                speaker: .you,
                pcm16Audio: audio,
                context: context,
                recentTranscript: ""
            )
        )
    }

    private func stopLivePreview() {
        livePreviewWorkItem?.cancel()
        livePreviewWorkItem = nil
        activeLivePreviewID = nil
        lastLivePreviewByteCount = 0
    }

    deinit {
        disable()
    }
}

enum PCM16SignalGate {
    /// Avoids passing silence to a bounded ASR model. Some Core ML execution
    /// paths cannot construct a valid encoder tensor for all-silence input.
    static func containsAudibleSignal(
        _ pcm16Audio: Data,
        minimumPeak: Int32 = 64
    ) -> Bool {
        peakMagnitude(pcm16Audio) >= minimumPeak
    }

    static func peakMagnitude(_ pcm16Audio: Data) -> Int32 {
        pcm16Audio.withUnsafeBytes { rawBuffer in
            rawBuffer.bindMemory(to: Int16.self).reduce(into: Int32(0)) { peak, sample in
                peak = max(peak, abs(Int32(sample)))
            }
        }
    }
}

enum QuickDictationStreamPolicy {
    static let captureBytesPerSecond =
        RealtimeRefinementClient.captureSampleRate * MemoryLayout<Int16>.size
    /// Peak below which the trailing window counts as a pause rather than
    /// speech. Set well under conversational level so room tone does not read
    /// as speech; if it never trips, the segment ceiling still forces a commit.
    static let pausePeakThreshold: Int32 = 1_200
}

enum QuickDictationLivePreviewPolicy {
    private static let bytesPerSecond = 24_000 * MemoryLayout<Int16>.size
    static let minimumAudioBytes = Int(Double(bytesPerSecond) * 0.6)
    static let minimumAdditionalAudioBytes = Int(Double(bytesPerSecond) * 0.4)
    // The overlay only displays the newest text, and bounding this snapshot
    // keeps long dictations from doing progressively more preview work.
    static let maximumAudioBytes = bytesPerSecond * 15

    static func shouldTranscribe(
        audioByteCount: Int,
        lastTranscribedByteCount: Int
    ) -> Bool {
        audioByteCount >= minimumAudioBytes
            && audioByteCount - lastTranscribedByteCount >= minimumAdditionalAudioBytes
    }

    static func previewAudio(from bufferedAudio: Data) -> Data {
        Data(bufferedAudio.suffix(maximumAudioBytes))
    }
}

private final class LockedAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer {
            data.removeAll(keepingCapacity: false)
            lock.unlock()
        }
        return data
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }

    /// Copies only the trailing bytes. The segment scheduler polls for trailing
    /// silence several times a second, and copying the whole recording each
    /// time would grow more expensive the longer the user speaks.
    func tail(_ byteCount: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data(data.suffix(byteCount))
    }
}

struct QuickDictationPasteVerification {
    let expectedValue: String
    let expectedSelectedRange: CFRange

    init?(
        originalValue: String,
        selectedRange: CFRange,
        insertedText: String
    ) {
        let original = originalValue as NSString
        guard
            selectedRange.location >= 0,
            selectedRange.length >= 0,
            selectedRange.location + selectedRange.length <= original.length
        else {
            return nil
        }
        expectedValue = original.replacingCharacters(
            in: NSRange(
                location: selectedRange.location,
                length: selectedRange.length
            ),
            with: insertedText
        )
        expectedSelectedRange = CFRange(
            location: selectedRange.location + (insertedText as NSString).length,
            length: 0
        )
    }

    func matches(
        currentValue: String,
        selectedRange: CFRange
    ) -> Bool {
        currentValue == expectedValue
            && selectedRange.location == expectedSelectedRange.location
            && selectedRange.length == expectedSelectedRange.length
    }
}

/// Evidence that a paste landed in a target that has no editable value/range
/// model. A terminal's `AXValue` is the visible screen rather than a field's
/// contents, so exact comparison never matches — but the screen is stable when
/// idle, which makes both "the text appeared" and "nothing happened at all"
/// reliable signals.
struct QuickDictationContentEvidence: Equatable {
    enum Outcome: Equatable {
        /// The pasted text is visible on screen.
        case inserted
        /// The screen changed but the text is not literally visible, which is
        /// what a TUI that renders a pasted-text placeholder looks like.
        case changed
        /// Nothing happened; the paste did not reach the target.
        case unchanged
    }

    /// Enough trailing characters to be unambiguous, few enough to survive the
    /// text scrolling partly out of view.
    private static let probeLength = 32
    private static let minimumProbeLength = 6

    private let probe: String
    private let originalContent: String

    init(originalValue: String, insertedText: String) {
        let originalContent = Self.normalize(originalValue)
        self.originalContent = originalContent
        // The tail is checked rather than the head: a long paste scrolls its
        // beginning off the top, but the end sits at the cursor.
        let normalizedInsert = Self.normalize(insertedText)
        let probe = String(normalizedInsert.suffix(Self.probeLength))
        // A probe already on screen — dictating the same thing twice, or
        // reading back text that is already there — would report `.inserted`
        // against an untouched screen. That is worse than having no probe at
        // all, because `.inserted` is the one outcome trusted enough to hand
        // the clipboard back immediately.
        self.probe = probe.count >= Self.minimumProbeLength
            && !originalContent.contains(probe)
            ? probe
            : ""
    }

    func evaluate(currentValue: String) -> Outcome {
        let current = Self.normalize(currentValue)
        if !probe.isEmpty, current.contains(probe) {
            return .inserted
        }
        return current == originalContent ? .unchanged : .changed
    }

    /// Terminals wrap lines mid-token, so whitespace cannot be compared.
    private static func normalize(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}

enum QuickDictationPasteVerificationPolicy {
    static let iTermBundleIdentifier = "com.googlecode.iterm2"

    static func shouldVerify(bundleIdentifier: String?) -> Bool {
        // iTerm exposes terminal contents through Accessibility, but not as
        // the editable value/range model used by ordinary text fields. The
        // paste succeeds while exact value comparison consistently fails, so
        // those targets are checked with content evidence instead.
        bundleIdentifier != iTermBundleIdentifier
    }

    static func unverifiedDeliveryDelaySeconds(
        bundleIdentifier: String?
    ) -> TimeInterval {
        bundleIdentifier == iTermBundleIdentifier ? 0.25 : 2
    }
}

enum QuickDictationClipboardRestorationPolicy {
    /// How long the dictation has to stay on the clipboard after the paste
    /// keystroke before the previous contents may be put back.
    ///
    /// macOS never reports "the target read the pasteboard", and the keystroke
    /// is delivered asynchronously, so evidence that *something* happened in
    /// the target is not evidence that it has read the clipboard yet. Restoring
    /// inside that window makes the target paste the user's previous clipboard
    /// instead of their dictation.
    ///
    /// There is no signal to wait on, so this is a heuristic bound on how long
    /// a target can take to service a posted Cmd+V. It is set well past what a
    /// busy app plausibly needs; the only cost of overshooting is that the
    /// user's clipboard comes back a beat later. It may safely exceed
    /// `PasteInjector`'s serialization delay, because a paste that starts
    /// during the dwell inherits the pending restore rather than racing it.
    static let minimumDwellSeconds: TimeInterval = 1.5

    static func shouldRestore(
        insertedChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        insertedChangeCount == currentChangeCount
    }

    /// Delay before restoring, measured from the paste keystroke. Seeing the
    /// text itself land in the target proves the clipboard was already read,
    /// which is the one case that needs no dwell.
    static func restoreDelaySeconds(
        elapsedSincePaste: TimeInterval,
        isDeliveryProven: Bool
    ) -> TimeInterval {
        guard !isDeliveryProven else { return 0 }
        return max(0, minimumDwellSeconds - elapsedSincePaste)
    }
}

/// The application, window, and keyboard-focused control that were active when
/// a Quick Dictation recording began.
final class QuickDictationPasteTarget {
    private let runningApplication: NSRunningApplication
    private let accessibilityApplication: AXUIElement
    private let window: AXUIElement?
    private let focusedElement: AXUIElement?

    var applicationName: String {
        runningApplication.localizedName
            ?? runningApplication.bundleIdentifier
            ?? "the original application"
    }

    var applicationBundleIdentifier: String? {
        runningApplication.bundleIdentifier
    }

    var isAvailable: Bool {
        !runningApplication.isTerminated
    }

    /// Whether this target is still the app the user is working in. A long
    /// transcription gives the user time to switch away, and pasting into
    /// whatever they moved to — or yanking focus back — is worse than not
    /// pasting at all.
    var isStillFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == runningApplication.processIdentifier
    }

    private init(
        runningApplication: NSRunningApplication,
        accessibilityApplication: AXUIElement,
        window: AXUIElement?,
        focusedElement: AXUIElement?
    ) {
        self.runningApplication = runningApplication
        self.accessibilityApplication = accessibilityApplication
        self.window = window
        self.focusedElement = focusedElement
    }

    static func capture(
        initialApplication: NSRunningApplication? = nil
    ) -> QuickDictationPasteTarget? {
        let systemWideElement = AXUIElementCreateSystemWide()
        let accessibilityApplication: AXUIElement
        let runningApplication: NSRunningApplication

        if let initialApplication {
            runningApplication = initialApplication
            accessibilityApplication = AXUIElementCreateApplication(
                initialApplication.processIdentifier
            )
        } else if let focusedApplication = copyElement(
            attribute: kAXFocusedApplicationAttribute as CFString,
            from: systemWideElement
        ) {
            var processIdentifier: pid_t = 0
            guard
                AXUIElementGetPid(focusedApplication, &processIdentifier) == .success,
                let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                )
            else {
                return nil
            }
            accessibilityApplication = focusedApplication
            runningApplication = application
        } else {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            runningApplication = application
            accessibilityApplication = AXUIElementCreateApplication(
                application.processIdentifier
            )
        }

        return QuickDictationPasteTarget(
            runningApplication: runningApplication,
            accessibilityApplication: accessibilityApplication,
            window: copyElement(
                attribute: kAXFocusedWindowAttribute as CFString,
                from: accessibilityApplication
            ),
            focusedElement: copyElement(
                attribute: kAXFocusedUIElementAttribute as CFString,
                from: accessibilityApplication
            )
        )
    }

    func makePasteVerification(
        inserting text: String
    ) -> QuickDictationPasteVerification? {
        guard
            QuickDictationPasteVerificationPolicy.shouldVerify(
                bundleIdentifier: applicationBundleIdentifier
            ),
            let focusedElement,
            let originalValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            ),
            let selectedRange = Self.copyRange(
                attribute: kAXSelectedTextRangeAttribute as CFString,
                from: focusedElement
            )
        else {
            return nil
        }
        return QuickDictationPasteVerification(
            originalValue: originalValue,
            selectedRange: selectedRange,
            insertedText: text
        )
    }

    /// Snapshots the visible content of a target that cannot be verified
    /// through the editable value/range model.
    func makeContentEvidence(
        inserting text: String
    ) -> QuickDictationContentEvidence? {
        guard
            let focusedElement,
            let originalValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            )
        else {
            return nil
        }
        return QuickDictationContentEvidence(
            originalValue: originalValue,
            insertedText: text
        )
    }

    func evaluateContentEvidence(
        _ evidence: QuickDictationContentEvidence
    ) -> QuickDictationContentEvidence.Outcome? {
        guard
            let focusedElement,
            let currentValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            )
        else {
            return nil
        }
        return evidence.evaluate(currentValue: currentValue)
    }

    func verifyPaste(_ verification: QuickDictationPasteVerification) -> Bool {
        guard
            let focusedElement,
            let currentValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            ),
            let selectedRange = Self.copyRange(
                attribute: kAXSelectedTextRangeAttribute as CFString,
                from: focusedElement
            )
        else {
            return false
        }
        return verification.matches(
            currentValue: currentValue,
            selectedRange: selectedRange
        )
    }

    /// Requests activation and reasserts the exact window and control. The
    /// activation itself can complete on a later run-loop turn, so callers may
    /// need to retry this method briefly before posting keyboard events.
    @discardableResult
    func restoreFocus() -> Bool {
        guard isAvailable else { return false }

        _ = runningApplication.activate(options: [])
        _ = AXUIElementSetAttributeValue(
            accessibilityApplication,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        if let window {
            _ = AXUIElementSetAttributeValue(
                accessibilityApplication,
                kAXMainWindowAttribute as CFString,
                window
            )
            _ = AXUIElementSetAttributeValue(
                accessibilityApplication,
                kAXFocusedWindowAttribute as CFString,
                window
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if let focusedElement {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        return hasFocus
    }

    private var hasFocus: Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        guard
            let currentApplication = Self.copyElement(
                attribute: kAXFocusedApplicationAttribute as CFString,
                from: systemWideElement
            )
        else {
            return false
        }
        var currentProcessIdentifier: pid_t = 0
        guard
            AXUIElementGetPid(
                currentApplication,
                &currentProcessIdentifier
            ) == .success,
            currentProcessIdentifier == runningApplication.processIdentifier
        else {
            return false
        }

        if let window {
            guard
                let currentWindow = Self.copyElement(
                    attribute: kAXFocusedWindowAttribute as CFString,
                    from: accessibilityApplication
                ),
                CFEqual(currentWindow, window)
            else {
                return false
            }
        }
        if let focusedElement {
            guard
                let currentElement = Self.copyElement(
                    attribute: kAXFocusedUIElementAttribute as CFString,
                    from: accessibilityApplication
                ),
                CFEqual(currentElement, focusedElement)
            else {
                return false
            }
        }
        return true
    }

    private static func copyElement(
        attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func copyString(
        attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value
        else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        return (value as? NSAttributedString)?.string
    }

    private static func copyRange(
        attribute: CFString,
        from element: AXUIElement
    ) -> CFRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let accessibilityValue = value as! AXValue
        guard AXValueGetType(accessibilityValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(accessibilityValue, .cfRange, &range) else {
            return nil
        }
        return range
    }
}

enum QuickDictationPasteDelivery: String, Equatable {
    case verified
    case unverified
}

/// Serializes focus restoration, paste events, and clipboard restoration so
/// multiple completed dictations cannot redirect or overwrite one another.
final class PasteInjector {
    typealias Completion = (Result<QuickDictationPasteDelivery, Error>) -> Void

    private struct Request {
        let text: String
        let target: QuickDictationPasteTarget
        let completion: Completion
    }

    private struct PasteAttempt {
        let id = UUID()
        let verification: QuickDictationPasteVerification?
        let contentEvidence: QuickDictationContentEvidence?
        let previousClipboardItems: [NSPasteboardItem]
        let insertedChangeCount: Int
        let pastedAtUptime: TimeInterval
    }

    private static let logger = Logger(
        subsystem: "com.permanentunderclass.meetingcopilot",
        category: "QuickDictationPaste"
    )
    private static let focusRetryDelay = DispatchTimeInterval.milliseconds(50)
    private static let maximumFocusAttempts = 20
    private static let verificationRetryDelay = DispatchTimeInterval.milliseconds(50)
    private static let maximumVerificationAttempts = 40
    private static let pasteSerializationDelay = DispatchTimeInterval.milliseconds(650)

    private var queuedRequests: [Request] = []
    private var activeRequest: Request?
    private var activePasteAttempt: PasteAttempt?
    /// A restore that is waiting out its dwell. Until it runs, it — not the
    /// pasteboard — holds the user's real clipboard.
    private var pendingRestore: PasteAttempt?
    /// Text owed to the clipboard once no paste is in flight. Last one wins,
    /// matching the plain overwrite this replaced.
    private var pendingClipboardOffer: String?
    private var scheduledWorkItem: DispatchWorkItem?
    private var generation = UUID()

    func paste(
        _ text: String,
        into target: QuickDictationPasteTarget,
        completion: @escaping Completion
    ) {
        queuedRequests.append(
            Request(text: text, target: target, completion: completion)
        )
        processNextRequest()
    }

    /// Leaves text on the clipboard for the user to paste by hand, once doing
    /// so cannot corrupt a paste in flight.
    ///
    /// Writing straight to the pasteboard — which is what callers used to do —
    /// makes an already-posted Cmd+V deliver *this* text instead of its own,
    /// and bumps the change count so the in-flight attempt gives up on handing
    /// the user their real clipboard back. Several dictations can be in flight
    /// at once, so this is reachable whenever one of them is undeliverable.
    func offerOnClipboard(_ text: String) {
        pendingClipboardOffer = text
        drainClipboardOffer()
    }

    func cancel() {
        generation = UUID()
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        restoreActiveClipboardIfUnchanged(isDeliveryProven: false)
        queuedRequests.removeAll()
        activeRequest = nil
        drainClipboardOffer()
    }

    private func drainClipboardOffer() {
        guard let text = pendingClipboardOffer else { return }
        // The offer is only unsafe while a posted Cmd+V could still read it:
        // an attempt that has not been retired yet (`activePasteAttempt`), one
        // inside its dwell (`pendingRestore`), or one about to be posted.
        // Notably this does *not* wait on `activeRequest`, so the ordinary
        // "paste failed" path still hands the text over without delay.
        guard
            activePasteAttempt == nil,
            pendingRestore == nil,
            queuedRequests.isEmpty
        else {
            return
        }
        pendingClipboardOffer = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Self.logger.notice("clipboard_offer_delivered")
    }

    private func processNextRequest() {
        guard activeRequest == nil, !queuedRequests.isEmpty else {
            drainClipboardOffer()
            return
        }
        let request = queuedRequests.removeFirst()
        activeRequest = request
        // Re-checked here, not just when the dictation was handed over: a
        // queued request waits out the previous paste's serialization delay,
        // and by the time it runs the user may have moved on. `restoreFocus`
        // would then drag them back to where they were to type into a field
        // they have left, which is worse than not pasting at all.
        guard request.target.isStillFrontmost else {
            let currentApplication = NSWorkspace.shared.frontmostApplication?
                .localizedName ?? "another app"
            Self.logger.notice(
                "paste_skipped_stale_target expected=\(request.target.applicationName, privacy: .public) frontmost=\(currentApplication, privacy: .public)"
            )
            finishActiveRequest(
                with: .failure(
                    MeetingCopilotError.audio(
                        "You switched to \(currentApplication) before Quick Dictation could paste this text."
                    )
                ),
                generation: generation
            )
            return
        }
        attemptFocus(
            remainingAttempts: Self.maximumFocusAttempts,
            generation: generation
        )
    }

    private func attemptFocus(
        remainingAttempts: Int,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            let request = activeRequest
        else {
            return
        }
        guard request.target.isAvailable else {
            finishActiveRequest(
                with: .failure(
                    MeetingCopilotError.audio(
                        "\(request.target.applicationName) closed before Quick Dictation could paste the text."
                    )
                ),
                generation: generation
            )
            return
        }
        if request.target.restoreFocus() {
            let inheritedItems = consumePendingRestoreItems()
            do {
                let attempt = try Self.performPaste(
                    request.text,
                    into: request.target,
                    inheritedPreviousItems: inheritedItems
                )
                activePasteAttempt = attempt
                awaitPasteDelivery(
                    attempt,
                    remainingAttempts: Self.maximumVerificationAttempts,
                    generation: generation
                )
            } catch {
                // `performPaste` can fail before it ever touches the clipboard,
                // which would strand inherited items that no pending restore
                // owns any more. Nothing of ours is on the pasteboard now, so
                // putting them straight back is the correct final state.
                if let inheritedItems {
                    Self.restore(items: inheritedItems, to: .general)
                }
                finishActiveRequest(
                    with: .failure(error),
                    generation: generation
                )
            }
            return
        }
        guard remainingAttempts > 1 else {
            finishActiveRequest(
                with: .failure(
                    MeetingCopilotError.audio(
                        "Quick Dictation could not return to the original field in \(request.target.applicationName), so no text was pasted."
                    )
                ),
                generation: generation
            )
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduledWorkItem = nil
            self?.attemptFocus(
                remainingAttempts: remainingAttempts - 1,
                generation: generation
            )
        }
        scheduledWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.focusRetryDelay,
            execute: workItem
        )
    }

    private func awaitPasteDelivery(
        _ attempt: PasteAttempt,
        remainingAttempts: Int,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            let request = activeRequest
        else {
            return
        }

        if let evidence = attempt.contentEvidence {
            awaitContentDelivery(
                attempt,
                evidence: evidence,
                remainingAttempts: remainingAttempts,
                generation: generation
            )
            return
        }
        guard let verification = attempt.verification else {
            scheduleUnverifiedCompletion(
                generation: generation,
                target: request.target
            )
            return
        }
        if request.target.verifyPaste(verification) {
            Self.logger.notice(
                "paste_delivery_verified target=\(request.target.applicationName, privacy: .public)"
            )
            finishActiveRequest(
                with: .success(.verified),
                delayBeforeNextRequest: Self.pasteSerializationDelay,
                isDeliveryProven: true,
                generation: generation
            )
            return
        }
        guard remainingAttempts > 1 else {
            Self.logger.error(
                "paste_delivery_unconfirmed target=\(request.target.applicationName, privacy: .public)"
            )
            finishActiveRequest(
                with: .failure(
                    MeetingCopilotError.audio(
                        "Quick Dictation sent the paste to \(request.target.applicationName) but could not confirm that the text was inserted. The completed text was saved in Quick Dictation history."
                    )
                ),
                delayBeforeNextRequest: Self.pasteSerializationDelay,
                generation: generation
            )
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledWorkItem = nil
            self.awaitPasteDelivery(
                attempt,
                remainingAttempts: remainingAttempts - 1,
                generation: generation
            )
        }
        scheduledWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.verificationRetryDelay,
            execute: workItem
        )
    }

    /// Confirms delivery into a target checked by visible content. Either the
    /// text appears or the screen changes; only a screen that never changed at
    /// all is reported back as undelivered.
    private func awaitContentDelivery(
        _ attempt: PasteAttempt,
        evidence: QuickDictationContentEvidence,
        remainingAttempts: Int,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            let request = activeRequest
        else {
            return
        }
        let outcome = request.target.evaluateContentEvidence(evidence)
        switch outcome {
        case .inserted, .changed:
            Self.logger.notice(
                "paste_delivery_verified target=\(request.target.applicationName, privacy: .public) evidence=\(outcome == .inserted ? "text_visible" : "screen_changed", privacy: .public)"
            )
            finishActiveRequest(
                with: .success(.verified),
                delayBeforeNextRequest: Self.pasteSerializationDelay,
                // A screen that merely *changed* may have been redrawn by
                // something else entirely — a spinner, streaming output — while
                // the paste is still on its way, so it proves nothing about the
                // clipboard having been read.
                isDeliveryProven: outcome == .inserted,
                generation: generation
            )
            return
        case .none:
            // The target stopped exposing its content; fall back to the
            // previous behaviour rather than inventing a failure.
            scheduleUnverifiedCompletion(
                generation: generation,
                target: request.target
            )
            return
        case .unchanged:
            break
        }

        guard remainingAttempts > 1 else {
            Self.logger.error(
                "paste_delivery_unchanged target=\(request.target.applicationName, privacy: .public)"
            )
            finishActiveRequest(
                with: .success(.unverified),
                delayBeforeNextRequest: Self.pasteSerializationDelay,
                generation: generation
            )
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledWorkItem = nil
            self.awaitContentDelivery(
                attempt,
                evidence: evidence,
                remainingAttempts: remainingAttempts - 1,
                generation: generation
            )
        }
        scheduledWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.verificationRetryDelay,
            execute: workItem
        )
    }

    private func scheduleUnverifiedCompletion(
        generation: UUID,
        target: QuickDictationPasteTarget
    ) {
        let delaySeconds =
            QuickDictationPasteVerificationPolicy.unverifiedDeliveryDelaySeconds(
                bundleIdentifier: target.applicationBundleIdentifier
            )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.scheduledWorkItem = nil
            Self.logger.notice(
                "paste_delivery_unverifiable target=\(target.applicationName, privacy: .public)"
            )
            self.finishActiveRequest(
                with: .success(.unverified),
                delayBeforeNextRequest: Self.pasteSerializationDelay,
                generation: generation
            )
        }
        scheduledWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delaySeconds,
            execute: workItem
        )
    }

    private func finishActiveRequest(
        with result: Result<QuickDictationPasteDelivery, Error>,
        delayBeforeNextRequest: DispatchTimeInterval? = nil,
        isDeliveryProven: Bool = false,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            let request = activeRequest
        else {
            return
        }

        restoreActiveClipboardIfUnchanged(isDeliveryProven: isDeliveryProven)

        if let delayBeforeNextRequest {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation else { return }
                self.scheduledWorkItem = nil
                self.activeRequest = nil
                self.processNextRequest()
            }
            scheduledWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delayBeforeNextRequest,
                execute: workItem
            )
            request.completion(result)
            return
        }

        activeRequest = nil
        request.completion(result)
        guard self.generation == generation else { return }
        processNextRequest()
    }

    private static func performPaste(
        _ text: String,
        into target: QuickDictationPasteTarget,
        inheritedPreviousItems: [NSPasteboardItem]?
    ) throws -> PasteAttempt {
        guard AXIsProcessTrusted() else {
            throw MeetingCopilotError.audio(
                "Accessibility permission is required to paste dictation into another app."
            )
        }
        guard
            let keyDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 9,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 9,
                keyDown: false
            )
        else {
            throw MeetingCopilotError.audio("Could not create the paste keyboard event.")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.setIntegerValueField(
            .eventSourceUserData,
            value: ModifierHoldMonitor.pasteEventTag
        )
        keyUp.setIntegerValueField(
            .eventSourceUserData,
            value: ModifierHoldMonitor.pasteEventTag
        )

        let pasteboard = NSPasteboard.general
        // Reading back every representation of a large clipboard is expensive,
        // so an inherited snapshot is both more correct and cheaper.
        let previousItems = inheritedPreviousItems
            ?? copyItems(pasteboard.pasteboardItems ?? [])
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(items: previousItems, to: pasteboard)
            throw MeetingCopilotError.audio("Could not place the dictation on the clipboard.")
        }
        var insertedChangeCount = pasteboard.changeCount

        // Snapshotted here rather than before the clipboard work above, which
        // is slow in exactly the cases that matter: reading back every
        // representation of a large clipboard, then writing out a long
        // dictation. A baseline captured before that gap lets any unrelated
        // redraw in the target — a spinner, streaming output — be read as the
        // paste landing, which retires the attempt and puts the user's previous
        // clipboard back before the target has read ours.
        let verification = target.makePasteVerification(inserting: text)
        // Targets without an editable value/range model still expose their
        // visible content, which is what makes a terminal paste checkable.
        let contentEvidence = verification == nil
            ? target.makeContentEvidence(inserting: text)
            : nil

        // Those snapshots are cross-process calls, which is long enough for a
        // clipboard manager or a user copy to land on top of the dictation.
        // Posting then would paste that instead, and no later guard can undo
        // it — the change-count check only ever suppresses the restore.
        if pasteboard.changeCount != insertedChangeCount {
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                restore(items: previousItems, to: pasteboard)
                throw MeetingCopilotError.audio("Could not place the dictation on the clipboard.")
            }
            insertedChangeCount = pasteboard.changeCount
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return PasteAttempt(
            verification: verification,
            contentEvidence: contentEvidence,
            previousClipboardItems: previousItems,
            insertedChangeCount: insertedChangeCount,
            pastedAtUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// - Parameter isDeliveryProven: Whether the dictation was seen in the
    ///   target, which is the only evidence that it has already read the
    ///   clipboard. Anything weaker waits out the dwell first.
    private func restoreActiveClipboardIfUnchanged(isDeliveryProven: Bool) {
        guard let attempt = activePasteAttempt else { return }
        activePasteAttempt = nil

        let delay = QuickDictationClipboardRestorationPolicy.restoreDelaySeconds(
            elapsedSincePaste:
                ProcessInfo.processInfo.systemUptime - attempt.pastedAtUptime,
            isDeliveryProven: isDeliveryProven
        )
        guard delay > 0 else {
            Self.restoreClipboardAndLog(after: attempt)
            return
        }
        pendingRestore = attempt
        // Deliberately outside `scheduledWorkItem` and ungated by generation:
        // a cancelled or superseded request still owes the user their clipboard
        // back, and the change-count check keeps it from clobbering a newer one.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                // Nothing can start another paste now, so this restore is
                // unconditionally the right final state.
                Self.restoreClipboardAndLog(after: attempt)
                return
            }
            // A paste that started inside the dwell has taken these items over.
            guard self.pendingRestore?.id == attempt.id else { return }
            self.pendingRestore = nil
            Self.restoreClipboardAndLog(after: attempt)
            // The dwell was the last thing holding back an undeliverable
            // dictation waiting for the clipboard.
            self.drainClipboardOffer()
        }
    }

    /// Hands a still-pending restore's saved items to the paste that is about
    /// to start. Without this, that paste would record the *previous
    /// dictation* as the clipboard to put back, and the user's real clipboard
    /// would be lost the moment two dictations land inside one dwell.
    private func consumePendingRestoreItems() -> [NSPasteboardItem]? {
        guard let pending = pendingRestore else { return nil }
        pendingRestore = nil
        guard QuickDictationClipboardRestorationPolicy.shouldRestore(
            insertedChangeCount: pending.insertedChangeCount,
            currentChangeCount: NSPasteboard.general.changeCount
        ) else {
            // Someone else wrote the clipboard during the dwell; what they put
            // there is the user's clipboard now, so it is what gets saved.
            return nil
        }
        return pending.previousClipboardItems
    }

    private static func restoreClipboardAndLog(after attempt: PasteAttempt) {
        let restored = restoreClipboardIfUnchanged(after: attempt)
        logger.notice(
            "clipboard_restore restored=\(restored, privacy: .public)"
        )
    }

    private static func restoreClipboardIfUnchanged(
        after attempt: PasteAttempt
    ) -> Bool {
        let pasteboard = NSPasteboard.general
        guard QuickDictationClipboardRestorationPolicy.shouldRestore(
            insertedChangeCount: attempt.insertedChangeCount,
            currentChangeCount: pasteboard.changeCount
        ) else {
            return false
        }
        restore(items: attempt.previousClipboardItems, to: pasteboard)
        return true
    }

    private static func restore(
        items: [NSPasteboardItem],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func copyItems(_ items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}

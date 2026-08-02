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
            signal = isDiagnosticHold ? nil : state.cancelForKeyDown()
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

    init(
        onState: @escaping (SocketState) -> Void,
        onRefined: @escaping (_ transcriptID: String, _ text: String) -> Void,
        onFailure: @escaping (_ transcriptID: String, _ message: String) -> Void,
        onUsage: @escaping (OpenAITranscriptionUsageRecord) -> Void = { _ in }
    ) {
        self.onState = onState
        self.onRefined = onRefined
        self.onFailure = onFailure
        self.onUsage = onUsage
    }
}

enum QuickDictationTranscriberFactory {
    static func make(
        engine: TranscriptRefinementEngine,
        apiKey: String,
        callbacks: DictationTranscriberCallbacks
    ) -> TranscriptRefining {
        switch engine {
        case .localParakeet:
            ParakeetRefinementClient(
                onState: callbacks.onState,
                onRefined: callbacks.onRefined,
                onFailure: callbacks.onFailure
            )
        case .openAITranscribe:
            RealtimeRefinementClient(
                apiKey: apiKey,
                label: "QuickDictation",
                onState: callbacks.onState,
                onRefined: callbacks.onRefined,
                onFailure: callbacks.onFailure,
                onUsage: callbacks.onUsage
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

final class HoldToDictateService {
    typealias PhaseHandler = (DictationPhase) -> Void
    typealias PermissionHandler = (DictationPermissionState) -> Void
    typealias RecordingHandler = (Bool) -> Void
    typealias TelemetryHandler = (TrackTelemetry) -> Void
    typealias PartialHandler = (String) -> Void
    typealias ResultHandler = (String) -> Void
    typealias UsageHandler = (OpenAITranscriptionUsageRecord) -> Void

    private static let logger = Logger(
        subsystem: "com.permanentunderclass.meetingcopilot",
        category: "QuickDictationCapture"
    )
    private let canRecord: () -> Bool
    private let expectedLanguages: () -> [String]
    private let shouldProduceLivePreview: () -> Bool
    private let phaseHandler: PhaseHandler
    private let permissionHandler: PermissionHandler
    private let recordingHandler: RecordingHandler
    private let telemetryHandler: TelemetryHandler
    private let partialHandler: PartialHandler
    private let resultHandler: ResultHandler
    private let usageHandler: UsageHandler
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
    private var workState = QuickDictationWorkState<QuickDictationPasteTarget>()
    private let pasteInjector = PasteInjector()
    private var activeLivePreviewID: String?
    private var livePreviewWorkItem: DispatchWorkItem?
    private var lastLivePreviewByteCount = 0
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
        shouldProduceLivePreview: @escaping () -> Bool = { true },
        onPhase: @escaping PhaseHandler,
        onPermissions: @escaping PermissionHandler,
        onRecording: @escaping RecordingHandler,
        onTelemetry: @escaping TelemetryHandler,
        onPartial: @escaping PartialHandler = { _ in },
        onResult: @escaping ResultHandler,
        onUsage: @escaping UsageHandler = { _ in },
        transcriptionEngine: TranscriptRefinementEngine = .localParakeet,
        apiKey: String = "",
        transcribesAfterRecording: Bool = true
    ) {
        self.canRecord = canRecord
        self.expectedLanguages = expectedLanguages
        self.shouldProduceLivePreview = shouldProduceLivePreview
        phaseHandler = onPhase
        permissionHandler = onPermissions
        recordingHandler = onRecording
        telemetryHandler = onTelemetry
        partialHandler = onPartial
        resultHandler = onResult
        usageHandler = onUsage
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
            || reconnectWorkItem != nil
        wantsEnabled = false
        guard hadActiveWork else { return }
        generation = UUID()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectPolicy.reset()
        monitor.stop()
        stopLivePreview()
        cancelRecording(nextPhase: .off)
        pasteInjector.cancel()
        transcriber?.disconnect()
        transcriber = nil
        workState.reset()
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
        guard
            let recordingID,
            activeLivePreviewID == nil,
            livePreviewWorkItem == nil
        else {
            return
        }
        scheduleLivePreview(recordingID: recordingID)
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
                phaseHandler(.preparing(transcriptionEngine))
            }
        case .connecting:
            isModelReady = false
            if recordingID == nil, !workState.hasPendingTranscriptions {
                phaseHandler(.preparing(transcriptionEngine))
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
            if recordingID == nil {
                phaseHandler(.failed(message))
            } else {
                Self.logger.error(
                    "transcriber_failed_while_recording error=\(message, privacy: .public)"
                )
            }
        }
        if let reconnectDelay {
            scheduleTranscriberReconnect(
                after: reconnectDelay,
                generation: generation
            )
        }
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
        guard isModelReady else {
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
        let pipeline = AudioTrackPipeline(
            label: "MeetingCopilot.Audio.Dictation",
            onChunk: { chunk in
                buffer.append(chunk)
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
        if transcribesAfterRecording, shouldProduceLivePreview() {
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
                    if case let .failure(error) = result {
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
        recordingHandler(false)

        let audio = buffer?.take() ?? Data()
        let peak = PCM16SignalGate.peakMagnitude(audio)
        Self.logger.notice(
            "recording_finished bytes=\(audio.count, privacy: .public) peak=\(peak, privacy: .public)"
        )
        guard transcribesAfterRecording else {
            phaseHandler(currentWorkPhase())
            return
        }
        guard audio.count >= 4_800 else {
            Self.logger.notice("recording_skipped reason=too_short")
            phaseHandler(currentWorkPhase())
            return
        }
        guard peak >= 64 else {
            Self.logger.notice("recording_skipped reason=silence")
            phaseHandler(currentWorkPhase())
            return
        }

        let languages = expectedLanguages()
        let transcriptID = "dictation-\(UUID().uuidString)"
        guard let transcriber else {
            phaseHandler(.failed("The selected Quick Dictation model is unavailable."))
            return
        }
        guard let pasteTarget else {
            phaseHandler(
                .failed("Quick Dictation lost the original app target before transcription began.")
            )
            return
        }
        workState.submit(transcriptID: transcriptID, target: pasteTarget)
        phaseHandler(currentWorkPhase())
        Self.logger.notice(
            "transcription_started pending=\(self.workState.pendingTranscriptionIDs.count, privacy: .public)"
        )
        transcriber.refine(
            RealtimeRefinementRequest(
                transcriptID: transcriptID,
                speaker: .you,
                pcm16Audio: audio,
                context: TranscriptionContext(
                    prompt: "",
                    keywords: [],
                    languages: languages,
                    delay: .medium
                ),
                recentTranscript: ""
            )
        )
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

        guard let pasteTarget = workState.complete(transcriptID: transcriptID) else {
            return
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            Self.logger.error("transcription_empty")
            publishTranscriptionFailure(
                "\(transcriptionEngine.title) returned no dictation text."
            )
            return
        }
        pasteInjector.paste(result, into: pasteTarget) { [weak self] pasteResult in
            guard
                let self,
                self.generation == generation,
                self.isRunning
            else {
                return
            }
            switch pasteResult {
            case .success:
                Self.logger.notice(
                    "transcription_completed characters=\(result.count, privacy: .public)"
                )
                self.resultHandler(result)
                if self.recordingID == nil {
                    self.phaseHandler(self.currentWorkPhase())
                }
            case let .failure(error):
                Self.logger.error(
                    "paste_failed error=\(error.localizedDescription, privacy: .public)"
                )
                self.resultHandler(result)
                self.publishTranscriptionFailure(error.localizedDescription)
            }
        }
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

        guard workState.complete(transcriptID: transcriptID) != nil else {
            return
        }
        Self.logger.error(
            "transcription_failed error=\(message, privacy: .public)"
        )
        publishTranscriptionFailure(message)
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
            isModelReady: isModelReady,
            engine: transcriptionEngine
        )
    }

    private func cancelRecording(nextPhase: DictationPhase? = nil) {
        stopLivePreview()
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
        let languages = expectedLanguages()
        guard let transcriber else {
            scheduleLivePreview(recordingID: recordingID)
            return
        }
        let transcriptID = "dictation-preview-\(UUID().uuidString)"
        activeLivePreviewID = transcriptID
        transcriber.refine(
            RealtimeRefinementRequest(
                transcriptID: transcriptID,
                speaker: .you,
                pcm16Audio: audio,
                context: TranscriptionContext(
                    prompt: "",
                    keywords: [],
                    languages: languages,
                    delay: .minimal
                ),
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

    var isAvailable: Bool {
        !runningApplication.isTerminated
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
}

/// Serializes focus restoration, paste events, and clipboard restoration so
/// multiple completed dictations cannot redirect or overwrite one another.
final class PasteInjector {
    typealias Completion = (Result<Void, Error>) -> Void

    private struct Request {
        let text: String
        let target: QuickDictationPasteTarget
        let completion: Completion
    }

    private static let focusRetryDelay = DispatchTimeInterval.milliseconds(50)
    private static let maximumFocusAttempts = 20
    private static let clipboardRestoreDelay = DispatchTimeInterval.milliseconds(600)
    private static let pasteSerializationDelay = DispatchTimeInterval.milliseconds(650)

    private var queuedRequests: [Request] = []
    private var activeRequest: Request?
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

    func cancel() {
        generation = UUID()
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        queuedRequests.removeAll()
        activeRequest = nil
    }

    private func processNextRequest() {
        guard activeRequest == nil, !queuedRequests.isEmpty else { return }
        activeRequest = queuedRequests.removeFirst()
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
            do {
                try Self.performPaste(request.text)
                finishActiveRequest(
                    with: .success(()),
                    delayBeforeNextRequest: Self.pasteSerializationDelay,
                    generation: generation
                )
            } catch {
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

    private func finishActiveRequest(
        with result: Result<Void, Error>,
        delayBeforeNextRequest: DispatchTimeInterval? = nil,
        generation: UUID
    ) {
        guard
            self.generation == generation,
            let request = activeRequest
        else {
            return
        }

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

    private static func performPaste(_ text: String) throws {
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

        let pasteboard = NSPasteboard.general
        let previousItems = copyItems(pasteboard.pasteboardItems ?? [])
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(items: previousItems, to: pasteboard)
            throw MeetingCopilotError.audio("Could not place the dictation on the clipboard.")
        }
        let insertedChangeCount = pasteboard.changeCount

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(
            deadline: .now() + clipboardRestoreDelay
        ) {
            guard pasteboard.changeCount == insertedChangeCount else { return }
            restore(items: previousItems, to: pasteboard)
        }
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

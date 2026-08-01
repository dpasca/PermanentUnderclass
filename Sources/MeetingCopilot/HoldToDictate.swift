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
    typealias SignalHandler = (ModifierHoldSignal) -> Void

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
            Self.logger.notice(
                "shortcut_signal=\(String(describing: signal), privacy: .public) flags=\(event.flags.rawValue, privacy: .public)"
            )
            DispatchQueue.main.async { [signalHandler] in
                signalHandler(signal)
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
                onFailure: callbacks.onFailure
            )
        }
    }
}

final class HoldToDictateService {
    typealias PhaseHandler = (DictationPhase) -> Void
    typealias PermissionHandler = (DictationPermissionState) -> Void
    typealias RecordingHandler = (Bool) -> Void
    typealias TelemetryHandler = (TrackTelemetry) -> Void
    typealias PartialHandler = (String) -> Void
    typealias ResultHandler = (String) -> Void

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
    private let transcribesAfterRecording: Bool
    private let transcriptionEngine: TranscriptRefinementEngine
    private let apiKey: String

    private lazy var monitor = ModifierHoldMonitor { [weak self] signal in
        self?.handle(signal)
    }
    private var microphoneCapture: CaptureSessionMicrophoneCapture?
    private var pipeline: AudioTrackPipeline?
    private var audioBuffer: LockedAudioBuffer?
    private var recordingID: UUID?
    private var transcriber: TranscriptRefining?
    private var activeTranscriptionID: String?
    private var activeLivePreviewID: String?
    private var livePreviewWorkItem: DispatchWorkItem?
    private var lastLivePreviewByteCount = 0
    private var generation = UUID()
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
            || activeTranscriptionID != nil
            || activeLivePreviewID != nil
            || livePreviewWorkItem != nil
        wantsEnabled = false
        guard hadActiveWork else { return }
        generation = UUID()
        monitor.stop()
        stopLivePreview()
        cancelRecording(nextPhase: .off)
        transcriber?.disconnect()
        transcriber = nil
        activeTranscriptionID = nil
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
        phaseHandler(.preparing(transcriptionEngine))
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
        switch state {
        case .idle:
            isModelReady = false
        case .connecting:
            isModelReady = false
            if recordingID == nil, activeTranscriptionID == nil {
                phaseHandler(.preparing(transcriptionEngine))
            }
        case .connected:
            isModelReady = true
            if recordingID == nil, activeTranscriptionID == nil {
                phaseHandler(.ready)
            }
        case let .failed(message):
            isModelReady = false
            phaseHandler(.failed(message))
        }
    }

    private func handle(_ signal: ModifierHoldSignal) {
        switch signal {
        case .pressed:
            startRecording()
        case .released:
            finishRecording()
        case .cancelled:
            cancelRecording(nextPhase: isRunning ? .ready : .off)
        }
    }

    private func startRecording() {
        guard isRunning, recordingID == nil, activeTranscriptionID == nil else { return }
        guard isModelReady else {
            phaseHandler(.preparing(transcriptionEngine))
            return
        }
        guard canRecord() else {
            phaseHandler(.failed("Quick Dictation is unavailable while meeting capture is active."))
            return
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

        microphoneCapture = nil
        self.pipeline = nil
        audioBuffer = nil
        self.recordingID = nil
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
            phaseHandler(isRunning ? .ready : .off)
            return
        }
        guard audio.count >= 4_800 else {
            Self.logger.notice("recording_skipped reason=too_short")
            phaseHandler(.ready)
            return
        }
        guard peak >= 64 else {
            Self.logger.notice("recording_skipped reason=silence")
            phaseHandler(.ready)
            return
        }

        let languages = expectedLanguages()
        phaseHandler(.transcribing)
        Self.logger.notice("transcription_started")
        let transcriptID = "dictation-\(UUID().uuidString)"
        activeTranscriptionID = transcriptID
        guard let transcriber else {
            activeTranscriptionID = nil
            phaseHandler(.failed("The selected Quick Dictation model is unavailable."))
            return
        }
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

        guard
            recordingID == nil,
            activeTranscriptionID == transcriptID
        else {
            return
        }
        activeTranscriptionID = nil
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            Self.logger.error("transcription_empty")
            phaseHandler(.failed("\(transcriptionEngine.title) returned no dictation text."))
            return
        }
        do {
            try PasteInjector.paste(result)
            Self.logger.notice(
                "transcription_completed characters=\(result.count, privacy: .public)"
            )
            resultHandler(result)
            phaseHandler(.ready)
        } catch {
            Self.logger.error(
                "paste_failed error=\(error.localizedDescription, privacy: .public)"
            )
            resultHandler(result)
            phaseHandler(.failed(error.localizedDescription))
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

        guard
            activeTranscriptionID == transcriptID
        else {
            return
        }
        activeTranscriptionID = nil
        Self.logger.error(
            "transcription_failed error=\(message, privacy: .public)"
        )
        phaseHandler(.failed(message))
    }

    private func cancelRecording(nextPhase: DictationPhase) {
        stopLivePreview()
        microphoneCapture?.stop()
        pipeline?.finish()
        microphoneCapture = nil
        pipeline = nil
        audioBuffer = nil
        recordingID = nil
        recordingHandler(false)
        phaseHandler(nextPhase)
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

enum PasteInjector {
    static func paste(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            throw MeetingCopilotError.audio(
                "Accessibility permission is required to paste dictation into another app."
            )
        }

        let pasteboard = NSPasteboard.general
        let previousItems = copyItems(pasteboard.pasteboardItems ?? [])
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw MeetingCopilotError.audio("Could not place the dictation on the clipboard.")
        }
        let insertedChangeCount = pasteboard.changeCount

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
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) {
            guard pasteboard.changeCount == insertedChangeCount else { return }
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
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

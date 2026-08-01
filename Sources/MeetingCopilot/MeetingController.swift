import AppKit
import CoreAudio
import Foundation

final class MeetingController: ObservableObject {
    @Published var apiKeyDraft = ""
    @Published var topicPrompt =
        "An English-language one-on-one technical company meeting. Speakers may have different regional or non-native English accents. Discussion may include software, hardware, APIs, product names, acronyms, numbers, and action items."
    @Published var keywordsText = ""
    @Published var languagesText = "en"
    @Published var delay: TranscriptionDelay = .medium
    @Published var refinementEngine: TranscriptRefinementEngine = .openAITranscribe
    @Published var processes: [AudioProcessInfo] = []
    @Published var selectedProcessID: AudioObjectID?
    @Published var localTrack = TrackViewState()
    @Published var remoteTrack = TrackViewState()
    @Published var refinementState: SocketState = .idle
    @Published var transcript: [TranscriptTurn] = []
    @Published var isListening = false
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?
    @Published var keyStatus = ""
    @Published var microphoneName = "System default microphone"
    @Published private(set) var microphoneAvailable = false
    @Published private(set) var inputDevices: [AudioDeviceOption] = []
    @Published private(set) var selectedInputDeviceID: AudioObjectID?
    @Published private(set) var audioOutputName = "System default output"
    @Published private(set) var audioOutputAvailable = false
    @Published private(set) var outputDevices: [AudioDeviceOption] = []
    @Published private(set) var selectedOutputDeviceID: AudioObjectID?
    @Published var dictationEnabled = false
    @Published var dictationPhase: DictationPhase = .off
    @Published var dictationPermissions = HoldToDictateService.currentPermissions()
    @Published var isDictating = false
    @Published var dictationTelemetry = TrackTelemetry()
    @Published var lastDictation = ""
    @Published private(set) var parakeetPreparation = ParakeetPreparationState()
    @Published var dictationPartialTranscript = ""
    @Published var dictationPreviewEnabled = true

    private var microphoneCapture: MicrophoneCapture?
    private var processCapture: ProcessTapCapture?
    private var localPipeline: AudioTrackPipeline?
    private var remotePipeline: AudioTrackPipeline?
    private var localClient: RealtimeTranscriptionClient?
    private var remoteClient: RealtimeTranscriptionClient?
    private var refinementClients: [SpeakerTag: TranscriptRefining] = [:]
    private var refinementStates: [SpeakerTag: SocketState] = [:]
    private var activeContext: TranscriptionContext?
    private var activeSessionID: UUID?
    private var inputDeviceMonitor: DefaultInputDeviceMonitor?
    private var outputDeviceMonitor: DefaultOutputDeviceMonitor?
    private var microphoneRestartWorkItem: DispatchWorkItem?
    private var microphoneCaptureGeneration: UUID?
    private var dictationService: HoldToDictateService?
    private var parakeetWarmupTask: Task<Void, Never>?
    private let dictationOverlay = QuickDictationOverlayController()

    private static let dictationEnabledDefaultsKey =
        "MeetingCopilot.HoldToDictateEnabled"
    private static let dictationPreviewEnabledDefaultsKey =
        "MeetingCopilot.QuickDictationPreviewEnabled"

    init() {
        apiKeyDraft = KeychainStore.loadAPIKey()
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""
        dictationPreviewEnabled = UserDefaults.standard.object(
            forKey: Self.dictationPreviewEnabledDefaultsKey
        ) as? Bool ?? true
        dictationOverlay.setEnabled(dictationPreviewEnabled)
        refreshAudioDevices()
        refreshProcesses()

        let monitor = DefaultInputDeviceMonitor { [weak self] _ in
            self?.refreshAudioDevices()
        }
        inputDeviceMonitor = monitor
        do {
            try monitor.start()
        } catch {
            present(error)
        }

        let outputMonitor = DefaultOutputDeviceMonitor { [weak self] _ in
            self?.refreshAudioDevices()
        }
        outputDeviceMonitor = outputMonitor
        do {
            try outputMonitor.start()
        } catch {
            present(error)
        }

        startParakeetWarmup()

        if UserDefaults.standard.bool(forKey: Self.dictationEnabledDefaultsKey) {
            dictationEnabled = true
            DispatchQueue.main.async { [weak self] in
                self?.startDictationService(requestAccess: false)
            }
        }
    }

    func refreshProcesses() {
        do {
            let previous = selectedProcessID.flatMap { selectedID in
                processes.first(where: { $0.id == selectedID })
            }
            let refreshed = try AudioProcessCatalog.load()
            processes = refreshed
            if
                let previous,
                let resolved = AudioProcessSelectionResolver.resolve(
                    previous: previous,
                    candidates: refreshed
                )
            {
                selectedProcessID = resolved.id
            } else {
                selectedProcessID = refreshed.first(where: \.isProducingOutput)?.id
            }
            if processes.isEmpty {
                statusMessage = "Open the meeting application, then refresh the list."
            }
        } catch {
            present(error)
        }
    }

    func refreshAudioDevices() {
        do {
            inputDevices = try CoreAudioUtilities.availableInputDevices()
            outputDevices = try CoreAudioUtilities.availableOutputDevices()
        } catch {
            present(error)
        }

        handleDefaultInputDeviceChange(CoreAudioUtilities.defaultInputDevice())
        handleDefaultOutputDeviceChange(CoreAudioUtilities.defaultOutputDevice())
    }

    func selectInputDevice(_ deviceID: AudioObjectID) {
        guard deviceID != selectedInputDeviceID else { return }
        do {
            try CoreAudioUtilities.setDefaultInputDevice(deviceID)
            refreshAudioDevices()
        } catch {
            present(error)
        }
    }

    func selectOutputDevice(_ deviceID: AudioObjectID) {
        guard deviceID != selectedOutputDeviceID else { return }
        do {
            try CoreAudioUtilities.setDefaultOutputDevice(deviceID)
            refreshAudioDevices()
        } catch {
            present(error)
        }
    }

    func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            present(MeetingCopilotError.noAPIKey)
            return
        }
        do {
            try KeychainStore.saveAPIKey(key)
            apiKeyDraft = key
            keyStatus = "Saved in Keychain"
            if
                dictationEnabled,
                !isDictationBusy,
                refinementEngine == .openAITranscribe
            {
                restartDictationService()
            }
        } catch {
            present(error)
        }
    }

    func startMeeting() {
        errorMessage = nil
        do {
            guard !isDictating else {
                throw MeetingCopilotError.audio(
                    "Release the Quick Dictation shortcut before starting meeting capture."
                )
            }
            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw MeetingCopilotError.noAPIKey }
            guard
                let selectedProcessID,
                let previousSelection = processes.first(where: { $0.id == selectedProcessID })
            else {
                throw MeetingCopilotError.noProcessSelected
            }
            let selectedProcess = try refreshSelection(previous: previousSelection)
            let context = try transcriptionContext()
            uniqueRefinementClients().forEach { $0.disconnect() }
            refinementClients.removeAll()
            refinementStates.removeAll()
            markRefiningTurnsLiveOnly(
                "Refinement was interrupted when a new meeting started."
            )
            let sessionID = UUID()
            activeSessionID = sessionID
            activeContext = context
            isListening = true
            statusMessage = "Starting capture…"
            let monitoringStartedAt = Date()
            localTrack = TrackViewState(
                socket: .connecting,
                telemetry: TrackTelemetry(monitoringStartedAt: monitoringStartedAt)
            )
            remoteTrack = TrackViewState(
                socket: .connecting,
                telemetry: TrackTelemetry(monitoringStartedAt: monitoringStartedAt)
            )
            refinementState = .connecting

            let localClient = makeClient(
                speaker: .you,
                apiKey: key,
                context: context,
                sessionID: sessionID
            )
            let remoteClient = makeClient(
                speaker: .other,
                apiKey: key,
                context: context,
                sessionID: sessionID
            )
            self.localClient = localClient
            self.remoteClient = remoteClient

            let refinedHandler: (String, String) -> Void = {
                [weak self] transcriptID, text in
                guard let self, self.activeSessionID == sessionID else { return }
                self.applyRefinement(transcriptID: transcriptID, text: text)
            }
            let failureHandler: (String, String) -> Void = {
                [weak self] transcriptID, message in
                guard let self, self.activeSessionID == sessionID else { return }
                self.markTurnLiveOnly(transcriptID: transcriptID, message: message)
            }
            refinementStates = [.you: .connecting, .other: .connecting]
            switch refinementEngine {
            case .localParakeet:
                let client = ParakeetRefinementClient(
                    onState: { [weak self] state in
                        self?.handleRefinementState(
                            state,
                            speaker: nil,
                            sessionID: sessionID
                        )
                    },
                    onRefined: refinedHandler,
                    onFailure: failureHandler
                )
                refinementClients = [.you: client, .other: client]

            case .openAITranscribe:
                var clients: [SpeakerTag: TranscriptRefining] = [:]
                for speaker in [SpeakerTag.you, .other] {
                    clients[speaker] = RealtimeRefinementClient(
                        apiKey: key,
                        label: speaker.rawValue,
                        onState: { [weak self] state in
                            self?.handleRefinementState(
                                state,
                                speaker: speaker,
                                sessionID: sessionID
                            )
                        },
                        onRefined: refinedHandler,
                        onFailure: failureHandler
                    )
                }
                refinementClients = clients
            }

            let localPipeline = AudioTrackPipeline(
                label: "MeetingCopilot.Audio.You",
                onChunk: { [weak localClient] chunk in
                    localClient?.sendAudio(chunk)
                },
                onTelemetry: { [weak self] telemetry in
                    guard self?.activeSessionID == sessionID else { return }
                    self?.localTrack.telemetry = telemetry
                }
            )
            let remotePipeline = AudioTrackPipeline(
                label: "MeetingCopilot.Audio.Other",
                onChunk: { [weak remoteClient] chunk in
                    remoteClient?.sendAudio(chunk)
                },
                onTelemetry: { [weak self] telemetry in
                    guard self?.activeSessionID == sessionID else { return }
                    self?.remoteTrack.telemetry = telemetry
                }
            )
            self.localPipeline = localPipeline
            self.remotePipeline = remotePipeline

            localClient.connect()
            remoteClient.connect()
            uniqueRefinementClients().forEach { $0.connect() }

            let processCapture = ProcessTapCapture()
            do {
                try processCapture.start(processObjectID: selectedProcess.id) { buffer in
                    remotePipeline.submit(buffer)
                }
            } catch {
                let retriedSelection = try refreshSelection(previous: selectedProcess)
                guard retriedSelection.id != selectedProcess.id else {
                    throw error
                }
                try processCapture.start(processObjectID: retriedSelection.id) { buffer in
                    remotePipeline.submit(buffer)
                }
            }
            self.processCapture = processCapture

            startMicrophoneCapture(sessionID: sessionID, isSwitch: false)
        } catch {
            stopImmediately()
            present(error)
        }
    }

    func stopMeeting() {
        guard activeSessionID != nil else { return }
        isListening = false
        statusMessage = "Finalizing transcript…"
        microphoneRestartWorkItem?.cancel()
        microphoneRestartWorkItem = nil
        microphoneCaptureGeneration = nil

        microphoneCapture?.stop()
        processCapture?.stop()
        microphoneCapture = nil
        processCapture = nil

        localPipeline?.finish()
        remotePipeline?.finish()
        localPipeline = nil
        remotePipeline = nil

        let clients = [localClient, remoteClient].compactMap { $0 }
        let refinementClients = uniqueRefinementClients()
        clients.forEach { $0.commitPendingAudio() }
        localClient = nil
        remoteClient = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            clients.forEach { $0.disconnect() }
            refinementClients.forEach { $0.finishWhenIdle() }
            guard self?.activeSessionID != nil, self?.isListening == false else { return }
            if self?.transcript.contains(where: {
                if case .refining = $0.refinement { return true }
                return false
            }) == true {
                self?.statusMessage = "Stopped — finishing second pass…"
            } else {
                self?.statusMessage = "Stopped"
            }
        }
    }

    func applyContext() {
        do {
            let context = try transcriptionContext()
            activeContext = context
            localClient?.updateContext(context)
            remoteClient?.updateContext(context)
            statusMessage = isListening ? "Context updated" : "Context ready"
        } catch {
            present(error)
        }
    }

    func finalizeLocalTurn() {
        guard isListening else { return }
        localPipeline?.finish()
        localClient?.commitPendingAudio()
        statusMessage = "Finishing your current turn…"
    }

    func selectRefinementEngine(_ engine: TranscriptRefinementEngine) {
        guard !isListening, !isDictationBusy, refinementEngine != engine else { return }
        refinementEngine = engine
        if engine == .localParakeet, parakeetPreparation.isFailed {
            startParakeetWarmup()
        }
        if dictationEnabled {
            restartDictationService()
        }
    }

    func setDictationEnabled(_ enabled: Bool) {
        dictationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.dictationEnabledDefaultsKey)
        if enabled {
            startDictationService(requestAccess: true)
        } else {
            dictationService?.disable()
            dictationService = nil
            dictationPhase = .off
            isDictating = false
            dictationPartialTranscript = ""
            dictationOverlay.handle(phase: .off)
        }
    }

    func setDictationPreviewEnabled(_ enabled: Bool) {
        dictationPreviewEnabled = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: Self.dictationPreviewEnabledDefaultsKey
        )
        dictationOverlay.setEnabled(enabled)
        dictationService?.setLivePreviewEnabled(enabled)
        if enabled {
            dictationOverlay.handle(phase: dictationPhase)
            dictationOverlay.update(telemetry: dictationTelemetry)
            dictationOverlay.update(partialTranscript: dictationPartialTranscript)
        }
    }

    func requestDictationPermissions() {
        dictationPermissions = HoldToDictateService.requestPermissions { [weak self] in
            self?.refreshDictationPermissions()
        }
        if dictationEnabled {
            startDictationService(requestAccess: false)
        } else if !dictationPermissions.allGranted {
            dictationPhase = .needsPermission
        }
    }

    func microphoneHealth(at now: Date = Date()) -> AudioStreamHealth {
        AudioStreamHealth.evaluate(
            sourceAvailable: microphoneAvailable,
            permissionGranted: dictationPermissions.canUseMicrophone,
            isMonitoring: isMicrophoneMonitoring,
            telemetry: visibleMicrophoneTelemetry,
            now: now
        )
    }

    func meetingAudioHealth(at now: Date = Date()) -> AudioStreamHealth {
        AudioStreamHealth.evaluate(
            sourceAvailable: selectedProcessID != nil,
            isMonitoring: isListening,
            telemetry: remoteTrack.telemetry,
            now: now
        )
    }

    var isMicrophoneMonitoring: Bool {
        isListening || isDictating
    }

    var isDictationBusy: Bool {
        isDictating || dictationPhase == .transcribing
    }

    var visibleMicrophoneTelemetry: TrackTelemetry {
        isDictating ? dictationTelemetry : localTrack.telemetry
    }

    func refreshDictationPermissions() {
        dictationPermissions = HoldToDictateService.currentPermissions()
        if dictationEnabled, dictationPermissions.allGranted {
            startDictationService(requestAccess: false)
        }
    }

    func clearTranscript() {
        transcript.removeAll()
        localTrack.partialTranscript = ""
        remoteTrack.partialTranscript = ""
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(), forType: .string)
        statusMessage = "Transcript copied"
    }

    func exportTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Meeting Transcript.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptText().write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Transcript saved"
        } catch {
            present(error)
        }
    }

    private func makeClient(
        speaker: SpeakerTag,
        apiKey: String,
        context: TranscriptionContext,
        sessionID: UUID
    ) -> RealtimeTranscriptionClient {
        RealtimeTranscriptionClient(
            apiKey: apiKey,
            context: context,
            label: speaker.rawValue,
            onState: { [weak self] state in
                guard let self, self.activeSessionID == sessionID else { return }
                if speaker == .you {
                    self.localTrack.socket = state
                } else {
                    self.remoteTrack.socket = state
                }
                if case let .failed(message) = state {
                    self.errorMessage = "\(speaker.rawValue) transcription: \(message)"
                }
            },
            onPartial: { [weak self] itemID, text in
                guard let self, self.activeSessionID == sessionID else { return }
                if speaker == .you {
                    self.localTrack.lastItemID = itemID
                    self.localTrack.partialTranscript = text
                } else {
                    self.remoteTrack.lastItemID = itemID
                    self.remoteTrack.partialTranscript = text
                }
            },
            onFinal: { [weak self] itemID, text, startedAt, endedAt, pcm16Audio in
                guard
                    let self,
                    self.activeSessionID == sessionID,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return
                }
                let transcriptID = "\(speaker.rawValue)-\(itemID)"
                let refinement: TranscriptRefinementState = pcm16Audio.isEmpty
                    ? .liveOnly("No buffered audio was available for the second pass.")
                    : .refining
                self.transcript.append(
                    TranscriptTurn(
                        id: transcriptID,
                        speaker: speaker,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        liveText: text,
                        text: text,
                        refinement: refinement
                    )
                )
                self.transcript.sort {
                    if $0.startedAt == $1.startedAt {
                        return $0.id < $1.id
                    }
                    return $0.startedAt < $1.startedAt
                }
                guard
                    !pcm16Audio.isEmpty,
                    let refinementClient = self.refinementClients[speaker],
                    let activeContext = self.activeContext
                else {
                    return
                }
                let recentTranscript = self.transcript
                    .filter { $0.id != transcriptID }
                    .suffix(8)
                    .map { "\($0.speaker.rawValue): \($0.text)" }
                    .joined(separator: "\n")
                refinementClient.refine(
                    RealtimeRefinementRequest(
                        transcriptID: transcriptID,
                        speaker: speaker,
                        pcm16Audio: pcm16Audio,
                        context: activeContext,
                        recentTranscript: recentTranscript
                    )
                )
            }
        )
    }

    private func uniqueRefinementClients() -> [TranscriptRefining] {
        var seen: Set<ObjectIdentifier> = []
        return [SpeakerTag.you, .other].compactMap { speaker in
            guard let client = refinementClients[speaker] else { return nil }
            let identifier = ObjectIdentifier(client)
            guard seen.insert(identifier).inserted else { return nil }
            return client
        }
    }

    private func handleRefinementState(
        _ state: SocketState,
        speaker: SpeakerTag?,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID else { return }
        if let speaker {
            refinementStates[speaker] = state
        } else {
            refinementStates[.you] = state
            refinementStates[.other] = state
        }
        refinementState = combinedRefinementState()

        if case let .failed(message) = state {
            markRefiningTurnsLiveOnly(message, speaker: speaker)
            let track = speaker.map { "\($0.rawValue) " } ?? ""
            errorMessage =
                "\(track)final transcription: \(message) Live transcription continues."
        }

        if
            !isListening,
            refinementStates[.you] == .idle,
            refinementStates[.other] == .idle
        {
            statusMessage = "Stopped — transcript refinement complete"
        }
    }

    private func combinedRefinementState() -> SocketState {
        let states = [SpeakerTag.you, .other].compactMap { refinementStates[$0] }
        if let failed = states.first(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            return failed
        }
        if states.contains(.connecting) {
            return .connecting
        }
        if states.contains(.connected) {
            return .connected
        }
        return .idle
    }

    private func applyRefinement(transcriptID: String, text: String) {
        guard let index = transcript.firstIndex(where: { $0.id == transcriptID }) else {
            return
        }
        transcript[index].text = text
        transcript[index].refinement = .refined
    }

    private func markTurnLiveOnly(transcriptID: String, message: String) {
        guard let index = transcript.firstIndex(where: { $0.id == transcriptID }) else {
            return
        }
        transcript[index].refinement = .liveOnly(message)
    }

    private func markRefiningTurnsLiveOnly(
        _ message: String,
        speaker: SpeakerTag? = nil
    ) {
        for index in transcript.indices {
            guard case .refining = transcript[index].refinement else { continue }
            if let speaker, transcript[index].speaker != speaker { continue }
            transcript[index].refinement = .liveOnly(message)
        }
    }

    private func transcriptionContext() throws -> TranscriptionContext {
        let keywords = keywordsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for keyword in keywords where
            keyword.contains("<")
            || keyword.contains(">")
            || keyword.contains("\r")
            || keyword.contains("\n") {
            throw MeetingCopilotError.invalidKeyword(keyword)
        }

        let separators = CharacterSet(charactersIn: ", \n\t")
        let languages = languagesText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return TranscriptionContext(
            prompt: topicPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: keywords,
            languages: languages,
            delay: delay
        )
    }

    private func transcriptText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return transcript.map {
            "[\(formatter.string(from: $0.startedAt))] \($0.speaker.rawValue): \($0.text)"
        }
        .joined(separator: "\n\n")
    }

    private func startDictationService(requestAccess: Bool) {
        if refinementEngine == .localParakeet, parakeetPreparation.isFailed {
            startParakeetWarmup()
        }
        let service: HoldToDictateService
        if let dictationService {
            service = dictationService
        } else {
            let created = HoldToDictateService(
                canRecord: { [weak self] in
                    self?.isListening == false
                },
                expectedLanguages: { [weak self] in
                    self?.dictationLanguages() ?? ["en"]
                },
                shouldProduceLivePreview: { [weak self] in
                    self?.dictationPreviewEnabled == true
                },
                onPhase: { [weak self] phase in
                    self?.dictationPhase = phase
                    self?.dictationOverlay.handle(phase: phase)
                },
                onPermissions: { [weak self] permissions in
                    self?.dictationPermissions = permissions
                },
                onRecording: { [weak self] recording in
                    guard let self else { return }
                    self.isDictating = recording
                    if recording {
                        self.dictationPartialTranscript = ""
                        self.dictationTelemetry = TrackTelemetry(
                            monitoringStartedAt: Date(),
                            sourceFormat: "Starting \(self.microphoneName)…"
                        )
                    }
                },
                onTelemetry: { [weak self] telemetry in
                    self?.dictationTelemetry = telemetry
                    self?.dictationOverlay.update(telemetry: telemetry)
                },
                onPartial: { [weak self] text in
                    self?.dictationPartialTranscript = text
                    self?.dictationOverlay.update(partialTranscript: text)
                },
                onResult: { [weak self] text in
                    self?.lastDictation = text
                    self?.dictationPartialTranscript = text
                    self?.dictationOverlay.show(result: text)
                },
                transcriptionEngine: refinementEngine,
                apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dictationService = created
            service = created
        }
        _ = service.enable(requestAccess: requestAccess)
    }

    private func restartDictationService() {
        dictationService?.disable()
        dictationService = nil
        startDictationService(requestAccess: false)
    }

    private func startParakeetWarmup() {
        guard
            parakeetWarmupTask == nil,
            !parakeetPreparation.isInProgress,
            !parakeetPreparation.isReady
        else {
            return
        }

        let startedAt = Date()
        parakeetPreparation = ParakeetPreparationState(
            stage: .checkingCache,
            startedAt: startedAt
        )
        let progressRelay = ParakeetPreparationProgressRelay { [weak self] event in
            self?.handleParakeetPreparationEvent(
                event,
                startedAt: startedAt
            )
        }
        parakeetWarmupTask = Task(priority: .utility) { [weak self] in
            do {
                try await ParakeetTranscriber.shared.prepare { event in
                    progressRelay.send(event)
                }
                await MainActor.run { [weak self] in
                    guard self?.parakeetPreparation.startedAt == startedAt else { return }
                    self?.parakeetWarmupTask = nil
                    self?.parakeetPreparation = ParakeetPreparationState(
                        stage: .ready,
                        startedAt: startedAt,
                        finishedAt: Date()
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard self?.parakeetPreparation.startedAt == startedAt else { return }
                    self?.parakeetWarmupTask = nil
                    self?.parakeetPreparation = ParakeetPreparationState(
                        stage: .failed(error.localizedDescription),
                        startedAt: startedAt,
                        finishedAt: Date()
                    )
                }
            }
        }
    }

    private func handleParakeetPreparationEvent(
        _ event: ParakeetPreparationEvent,
        startedAt: Date
    ) {
        guard
            parakeetPreparation.startedAt == startedAt,
            parakeetPreparation.isInProgress
        else {
            return
        }

        let stage: ParakeetPreparationStage
        switch event {
        case .checkingCache:
            stage = .checkingCache
        case let .downloading(fractionCompleted):
            stage = .downloading(fractionCompleted: fractionCompleted)
        case let .loading(component):
            stage = .loading(component: component)
        }
        parakeetPreparation = ParakeetPreparationState(
            stage: stage,
            startedAt: startedAt
        )
    }

    private func dictationLanguages() -> [String] {
        let separators = CharacterSet(charactersIn: ", \n\t")
        let languages = languagesText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return languages.isEmpty ? ["en"] : languages
    }

    private func refreshSelection(
        previous: AudioProcessInfo
    ) throws -> AudioProcessInfo {
        let refreshed = try AudioProcessCatalog.load()
        processes = refreshed
        guard let resolved = AudioProcessSelectionResolver.resolve(
            previous: previous,
            candidates: refreshed
        ) else {
            selectedProcessID = refreshed.first(where: \.isProducingOutput)?.id
            throw MeetingCopilotError.audio(
                "\(previous.name) stopped or restarted and its new audio process could not be matched. The process list was refreshed; select it again."
            )
        }
        selectedProcessID = resolved.id
        return resolved
    }

    private func handleDefaultInputDeviceChange(_ device: AudioInputDeviceInfo?) {
        let previousDeviceID = selectedInputDeviceID
        selectedInputDeviceID = device?.id
        microphoneName = device?.name ?? "No input device"
        microphoneAvailable = device != nil

        guard previousDeviceID != device?.id, isListening, let sessionID = activeSessionID else {
            return
        }
        guard device != nil else {
            microphoneRestartWorkItem?.cancel()
            microphoneRestartWorkItem = nil
            microphoneCaptureGeneration = nil
            microphoneCapture?.stop()
            microphoneCapture = nil
            localPipeline?.finish()
            localClient?.commitPendingAudio()
            localTrack.telemetry.sourceFormat = "Waiting for an input device"
            statusMessage = "Microphone disconnected — remote audio is still running"
            return
        }

        scheduleMicrophoneRestart(
            sessionID: sessionID,
            message: "Switching microphone to \(microphoneName)…"
        )
    }

    private func handleDefaultOutputDeviceChange(_ device: AudioOutputDeviceInfo?) {
        selectedOutputDeviceID = device?.id
        audioOutputName = device?.name ?? "No output device"
        audioOutputAvailable = device != nil
    }

    private func scheduleMicrophoneRestart(sessionID: UUID, message: String) {
        guard
            isListening,
            activeSessionID == sessionID,
            selectedInputDeviceID != nil
        else {
            return
        }
        microphoneRestartWorkItem?.cancel()
        statusMessage = message

        let work = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.isListening,
                self.activeSessionID == sessionID
            else {
                return
            }
            self.startMicrophoneCapture(sessionID: sessionID, isSwitch: true)
        }
        microphoneRestartWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(280),
            execute: work
        )
    }

    private func startMicrophoneCapture(sessionID: UUID, isSwitch: Bool) {
        guard isListening, activeSessionID == sessionID, let localPipeline else {
            return
        }
        microphoneRestartWorkItem?.cancel()
        microphoneRestartWorkItem = nil

        if isSwitch {
            microphoneCapture?.stop()
            localPipeline.finish()
            localClient?.commitPendingAudio()
        }

        let generation = UUID()
        microphoneCaptureGeneration = generation
        let capture = MicrophoneCapture()
        microphoneCapture = capture
        capture.start(
            onBuffer: { buffer in
                localPipeline.submit(buffer)
            },
            onConfigurationChange: { [weak self] in
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.microphoneCaptureGeneration == generation
                    else {
                        return
                    }
                    self.scheduleMicrophoneRestart(
                        sessionID: sessionID,
                        message: "Adapting to the new microphone configuration…"
                    )
                }
            },
            completion: { [weak self, weak capture] result in
                DispatchQueue.main.async {
                    guard
                        let self,
                        let capture,
                        self.activeSessionID == sessionID,
                        self.microphoneCaptureGeneration == generation
                    else {
                        capture?.stop()
                        return
                    }

                    switch result {
                    case .success:
                        self.statusMessage =
                            "Listening on \(self.microphoneName) — headphones required"

                    case let .failure(error):
                        capture.stop()
                        if self.microphoneCapture === capture {
                            self.microphoneCapture = nil
                        }
                        if isSwitch {
                            self.errorMessage =
                                "Could not switch to \(self.microphoneName): \(error.localizedDescription)"
                            self.statusMessage =
                                "Remote audio continues — waiting for a microphone"
                        } else {
                            self.stopMeeting()
                            self.present(error)
                        }
                    }
                }
            }
        )
    }

    private func stopImmediately() {
        microphoneRestartWorkItem?.cancel()
        microphoneRestartWorkItem = nil
        microphoneCaptureGeneration = nil
        microphoneCapture?.stop()
        processCapture?.stop()
        localClient?.disconnect()
        remoteClient?.disconnect()
        uniqueRefinementClients().forEach { $0.disconnect() }
        microphoneCapture = nil
        processCapture = nil
        localPipeline = nil
        remotePipeline = nil
        localClient = nil
        remoteClient = nil
        refinementClients.removeAll()
        refinementStates.removeAll()
        activeContext = nil
        activeSessionID = nil
        isListening = false
        localTrack.socket = .idle
        remoteTrack.socket = .idle
        refinementState = .idle
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "Needs attention"
    }

    deinit {
        parakeetWarmupTask?.cancel()
        dictationOverlay.setEnabled(false)
        dictationService?.disable()
        inputDeviceMonitor?.stop()
        outputDeviceMonitor?.stop()
        stopImmediately()
    }
}

private final class ParakeetPreparationProgressRelay: @unchecked Sendable {
    private let handler: (ParakeetPreparationEvent) -> Void

    init(handler: @escaping (ParakeetPreparationEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: ParakeetPreparationEvent) {
        DispatchQueue.main.async { [handler] in
            handler(event)
        }
    }
}

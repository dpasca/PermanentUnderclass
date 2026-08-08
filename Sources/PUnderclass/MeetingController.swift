import AppKit
import CoreAudio
import Foundation
import OSLog

final class MeetingController: ObservableObject {
    @Published var apiKeyDraft = ""
    @Published var meetingContextPrompt =
        "An English-language one-on-one technical company meeting. Speakers may have different regional or non-native English accents. Discussion may include software, hardware, APIs, product names, acronyms, numbers, and action items."
    @Published var interviewContextPrompt =
        "An English-language technical job interview. The other speaker is the interviewer and may ask about the candidate's experience, system design, debugging, performance, collaboration, and role-specific technical topics."
    @Published var keywordsText = ""
    @Published var languagesText = "en"
    @Published var delay: TranscriptionDelay = .medium
    @Published var preparationPurpose: CapturePurpose = .meeting
    /// Local-first: the app is fully usable on a fresh install with no key.
    @Published var refinementEngine: TranscriptRefinementEngine = .localWhisper
    @Published var processes: [AudioProcessInfo] = []
    @Published var selectedProcessID: AudioObjectID?
    @Published var localTrack = TrackViewState()
    @Published var remoteTrack = TrackViewState()
    @Published var refinementState: SocketState = .idle
    @Published var transcript: [TranscriptTurn] = []
    @Published var isListening = false
    @Published private(set) var capturePurpose: CapturePurpose?
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
    @Published private(set) var quickDictationHistory: [QuickDictationHistoryEntry] = []
    @Published private(set) var recoverableDictations: [QuickDictationRecoveryEntry] = []
    @Published private(set) var whisperPreparation = WhisperPreparationState()
    @Published private(set) var parakeetPreparation = ParakeetPreparationState()
    @Published var dictationPartialTranscript = ""
    @Published var dictationPreviewEnabled = true
    @Published var dictationCleanupEnabled = true
    /// Set by someone who has a key but wants a hard guarantee that nothing
    /// leaves the Mac. Without a key the cloud features are already locked, so
    /// this is an override rather than the primary gate.
    @Published private(set) var privacyLockEnabled = false
    /// Which settings section to reveal when a locked feature is tapped.
    @Published var pendingSettingsSection: SettingsSection?
    @Published private(set) var apiExpenses = APIExpenseSummary()
    @Published private(set) var referenceLibraryState = ReferenceLibraryState()
    @Published private(set) var companionGatewayStatus = "Starting companion display…"
    @Published private(set) var syntheticInterviewState =
        SyntheticInterviewState.ready(for: .interview)

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
    private var whisperWarmupTask: Task<Void, Never>?
    private var parakeetWarmupTask: Task<Void, Never>?
    private var referenceLibraryService: ReferenceLibraryService?
    private let companionGateway = CompanionGateway()
    private let liveAssistantClient = LiveAssistantClient()
    private let syntheticInterviewGeneratorClient =
        SyntheticInterviewGeneratorClient()
    private var companionUpdateTail: Task<Void, Never>?
    private var assistantGenerationTask: Task<Void, Never>?
    private var assistantGenerationRequestID: UUID?
    private var assistantGenerationIdentity: AssistantEvaluationIdentity?
    private let syntheticSpeechPlayer = SyntheticSpeechPlayer()
    private var syntheticInterviewTask: Task<Void, Never>?
    private var syntheticInterviewRunID: UUID?
    private var syntheticInterviewReferences: ReferenceLibrarySnapshot?
    private let dictationOverlay = QuickDictationOverlayController()
    private let quickDictationHistoryStore: QuickDictationHistoryStore
    private let quickDictationRecoveryStore: QuickDictationRecoveryStore
    private let apiExpenseStore: APIExpenseStore
    private let syntheticInterviewScenarioStore: SyntheticInterviewScenarioStore
    private let syntheticMeetingScenarioStore: SyntheticInterviewScenarioStore

    private static let dictationEnabledDefaultsKey =
        "PUnderclass.HoldToDictateEnabled"
    private static let dictationPreviewEnabledDefaultsKey =
        "PUnderclass.QuickDictationPreviewEnabled"
    private static let dictationCleanupEnabledDefaultsKey =
        "PUnderclass.QuickDictationCleanupEnabled"
    private static let referenceFolderDefaultsKey =
        "PUnderclass.ReferenceFolderPath"
    static let privacyLockDefaultsKey =
        "PUnderclass.PrivacyLock"
    static let refinementEngineDefaultsKey =
        "PUnderclass.RefinementEngine"
    /// Renamed when local-only stopped being the primary gate and became a
    /// privacy override.
    static let legacyLocalOnlyModeDefaultsKey =
        "PUnderclass.LocalOnlyMode"
    private static let liveAssistantLogger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "LiveAssistant"
    )

    init(
        quickDictationHistoryStore: QuickDictationHistoryStore = .applicationSupport(),
        quickDictationRecoveryStore: QuickDictationRecoveryStore = .applicationSupport(),
        syntheticInterviewScenarioStore: SyntheticInterviewScenarioStore =
            .applicationSupport(for: .interview),
        syntheticMeetingScenarioStore: SyntheticInterviewScenarioStore =
            .applicationSupport(for: .meeting),
        apiExpenseStore: APIExpenseStore = .applicationSupport()
    ) {
        self.quickDictationHistoryStore = quickDictationHistoryStore
        self.quickDictationRecoveryStore = quickDictationRecoveryStore
        self.syntheticInterviewScenarioStore = syntheticInterviewScenarioStore
        self.syntheticMeetingScenarioStore = syntheticMeetingScenarioStore
        self.apiExpenseStore = apiExpenseStore
        // A spend estimate that resets on every launch cannot answer "how much
        // did today cost", so the running total outlives the process.
        apiExpenses = (try? apiExpenseStore.load()) ?? APIExpenseSummary()
        apiKeyDraft = KeychainStore.loadAPIKey()
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""
        dictationPreviewEnabled = UserDefaults.standard.object(
            forKey: Self.dictationPreviewEnabledDefaultsKey
        ) as? Bool ?? true
        dictationCleanupEnabled = UserDefaults.standard.object(
            forKey: Self.dictationCleanupEnabledDefaultsKey
        ) as? Bool ?? true
        Self.migrateLegacyLocalOnlyMode()
        privacyLockEnabled = UserDefaults.standard.bool(
            forKey: Self.privacyLockDefaultsKey
        )
        if
            let storedEngine = UserDefaults.standard.string(
                forKey: Self.refinementEngineDefaultsKey
            ),
            let engine = TranscriptRefinementEngine(rawValue: storedEngine)
        {
            refinementEngine = engine
        }
        // A cloud choice left over from before the key was removed must not
        // break dictation on the next launch.
        refinementEngine = capability.resolvedEngine(preferring: refinementEngine)
        dictationOverlay.setEnabled(dictationPreviewEnabled)
        dictationOverlay.update(
            engine: capability.resolvedEngine(preferring: refinementEngine)
        )
        do {
            quickDictationHistory = try quickDictationHistoryStore.load()
            lastDictation = quickDictationHistory.first?.text ?? ""
        } catch {
            errorMessage = "Quick Dictation history could not be loaded: \(error.localizedDescription)"
            statusMessage = "Quick Dictation history needs attention"
        }
        reloadQuickDictationRecoveries()
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

        startWhisperWarmup()
        configureReferenceLibrary()
        startCompanionGateway()
        publishCompanionSession()
        publishCompanionReference()
        publishCompanionUsage()

        if UserDefaults.standard.bool(forKey: Self.dictationEnabledDefaultsKey) {
            dictationEnabled = true
            DispatchQueue.main.async { [weak self] in
                self?.startDictationService(requestAccess: false)
            }
        }

        if CommandLine.arguments.contains(SyntheticInterviewScenario.launchArgument) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startGeneratedReplay(for: .interview)
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

            // nil deliberately represents the default: capture all system audio.
            guard selectedProcessID != nil else { return }
            guard
                let previous,
                let resolved = AudioProcessSelectionResolver.resolve(
                    previous: previous,
                    candidates: refreshed
                )
            else {
                selectedProcessID = nil
                return
            }
            selectedProcessID = resolved.id
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
            present(PUnderclassError.noAPIKey)
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

    func startCapture(for purpose: CapturePurpose) {
        errorMessage = nil
        guard !isListening else {
            let activeTitle = capturePurpose?.title.lowercased() ?? "live"
            present(
                PUnderclassError.audio(
                    "The \(activeTitle) capture is already running."
                )
            )
            return
        }
        do {
            guard !syntheticInterviewState.isActive else {
                throw PUnderclassError.audio(
                    "Stop the generated \(syntheticInterviewState.purpose.title.lowercased()) replay before starting live capture."
                )
            }
            guard !isDictating else {
                throw PUnderclassError.audio(
                    "Release the Quick Dictation shortcut before starting live capture."
                )
            }
            // The live pass is a hosted model with no on-device equivalent, so
            // it is refused rather than quietly sending audio.
            let requiredFeature: CloudFeature = purpose == .meeting
                ? .meetingCapture
                : .answerMirror
            if let message = capability.lockMessage(for: requiredFeature) {
                throw PUnderclassError.audio(message)
            }
            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw PUnderclassError.noAPIKey }
            let selectedProcess: AudioProcessInfo?
            if let selectedProcessID {
                guard let previousSelection = processes.first(where: {
                    $0.id == selectedProcessID
                }) else {
                    self.selectedProcessID = nil
                    throw PUnderclassError.audio(
                        "The selected app is no longer available. All system audio is now selected; start again."
                    )
                }
                selectedProcess = try refreshSelection(previous: previousSelection)
            } else {
                selectedProcess = nil
            }
            syntheticInterviewState = SyntheticInterviewState.ready(for: purpose)
            syntheticInterviewReferences = nil
            capturePurpose = purpose
            prepareCompanionForNewSession()
            let context = try transcriptionContext(for: purpose)
            uniqueRefinementClients().forEach { $0.disconnect() }
            refinementClients.removeAll()
            refinementStates.removeAll()
            markRefiningTurnsLiveOnly(
                "Refinement was interrupted when new live capture started."
            )
            let sessionID = UUID()
            activeSessionID = sessionID
            activeContext = context
            isListening = true
            statusMessage = "Starting \(purpose.title.lowercased()) capture…"
            publishCompanionSession()
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
                purpose: purpose,
                apiKey: key,
                context: context,
                sessionID: sessionID
            )
            let remoteClient = makeClient(
                speaker: .other,
                purpose: purpose,
                apiKey: key,
                context: context,
                sessionID: sessionID
            )
            self.localClient = localClient
            self.remoteClient = remoteClient

            let refinedHandler: (String, String) -> Void = {
                [weak self] transcriptID, text in
                guard let self, self.activeSessionID == sessionID else { return }
                self.applyRefinement(
                    transcriptID: transcriptID,
                    purpose: purpose,
                    text: text
                )
            }
            let failureHandler: (String, String) -> Void = {
                [weak self] transcriptID, message in
                guard let self, self.activeSessionID == sessionID else { return }
                self.markTurnLiveOnly(
                    transcriptID: transcriptID,
                    purpose: purpose,
                    message: message
                )
            }
            let usageHandler: (OpenAITranscriptionUsageRecord) -> Void = {
                [weak self] usage in
                guard let self, self.activeSessionID == sessionID else { return }
                self.recordOpenAIUsage(usage)
            }
            refinementStates = [.you: .connecting, .other: .connecting]
            switch refinementEngine {
            case .localWhisper:
                let client = WhisperRefinementClient(
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
                        onFailure: failureHandler,
                        onUsage: usageHandler
                    )
                }
                refinementClients = clients
            }

            let localPipeline = AudioTrackPipeline(
                label: "PUnderclass.Audio.You",
                onChunk: { [weak localClient] chunk in
                    localClient?.sendAudio(chunk)
                },
                onTelemetry: { [weak self] telemetry in
                    guard self?.activeSessionID == sessionID else { return }
                    self?.localTrack.telemetry = telemetry
                }
            )
            let remotePipeline = AudioTrackPipeline(
                label: "PUnderclass.Audio.Other",
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
                try processCapture.start(processObjectID: selectedProcess?.id) { buffer in
                    remotePipeline.submit(buffer)
                }
            } catch {
                guard let selectedProcess else { throw error }
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

    func stopCapture() {
        guard activeSessionID != nil else { return }
        isListening = false
        statusMessage = "Finalizing transcript…"
        publishCompanionSession()
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
            self?.publishCompanionSession()
        }
    }

    func applyContext(for purpose: CapturePurpose) {
        do {
            guard !isListening || capturePurpose == purpose else {
                let activeTitle = capturePurpose?.title.lowercased() ?? "live"
                throw PUnderclassError.audio(
                    "Stop the active \(activeTitle) capture before applying \(purpose.title.lowercased()) context."
                )
            }
            let context = try transcriptionContext(for: purpose)
            activeContext = context
            if isListening {
                localClient?.updateContext(context)
                remoteClient?.updateContext(context)
            }
            statusMessage = isListening
                ? "\(purpose.title) context updated"
                : "\(purpose.title) context ready"
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

    /// Carries a pre-rename local-only choice into the privacy lock, then
    /// drops the old key so it cannot linger and confuse a later reader.
    ///
    /// The presence of the engine key proves the user has already made a
    /// choice under the new model, in which case adopting the old flag would
    /// override a more recent decision — so it is discarded instead.
    static func migrateLegacyLocalOnlyMode(
        defaults: UserDefaults = .standard
    ) {
        guard defaults.object(forKey: legacyLocalOnlyModeDefaultsKey) != nil
        else {
            return
        }
        defer { defaults.removeObject(forKey: legacyLocalOnlyModeDefaultsKey) }
        guard
            defaults.object(forKey: privacyLockDefaultsKey) == nil,
            defaults.object(forKey: refinementEngineDefaultsKey) == nil
        else {
            return
        }
        defaults.set(
            defaults.bool(forKey: legacyLocalOnlyModeDefaultsKey),
            forKey: privacyLockDefaultsKey
        )
    }

    /// What works right now. Derived from the key rather than from a mode the
    /// user has to find and understand.
    var capability: CloudCapability {
        CloudCapability(
            hasAPIKey: !apiKeyDraft
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            privacyLockEnabled: privacyLockEnabled
        )
    }

    func access(to feature: CloudFeature) -> FeatureAccess {
        capability.access(to: feature)
    }

    /// Hard opt-out for someone who has a key but wants nothing to leave the
    /// Mac. Turning it off does not silently re-select a cloud model.
    func setPrivacyLock(_ enabled: Bool) {
        guard privacyLockEnabled != enabled else { return }
        privacyLockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.privacyLockDefaultsKey)
        guard enabled else {
            statusMessage = "OpenAI features are available again"
            return
        }
        if isListening {
            stopCapture()
        }
        if refinementEngine.isCloud {
            selectRefinementEngine(.localWhisper)
        }
        statusMessage = "Everything stays on this Mac"
    }

    /// Records which section the settings window should open at. Opening it is
    /// the view's job: only SwiftUI's `openSettings` action reliably presents
    /// the Settings scene, and it is unavailable outside a view hierarchy.
    func requestSettings(_ section: SettingsSection) {
        pendingSettingsSection = section
    }

    func selectRefinementEngine(_ engine: TranscriptRefinementEngine) {
        guard !engine.isCloud || capability.isCloudEnabled else {
            errorMessage = privacyLockEnabled
                ? "Turn off \u{201C}Keep everything on this Mac\u{201D} to use \(engine.title)."
                : "Add an OpenAI API key to use \(engine.title)."
            return
        }
        guard !isListening, !isDictationBusy, refinementEngine != engine else { return }
        refinementEngine = engine
        UserDefaults.standard.set(
            engine.rawValue,
            forKey: Self.refinementEngineDefaultsKey
        )
        dictationOverlay.update(engine: engine)
        if engine == .localWhisper {
            startWhisperWarmup()
        } else if engine == .localParakeet {
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

    func setDictationCleanupEnabled(_ enabled: Bool) {
        dictationCleanupEnabled = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: Self.dictationCleanupEnabledDefaultsKey
        )
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

    func localTrack(for purpose: CapturePurpose) -> TrackViewState {
        capturePurpose == purpose ? localTrack : TrackViewState()
    }

    func remoteTrack(for purpose: CapturePurpose) -> TrackViewState {
        capturePurpose == purpose ? remoteTrack : TrackViewState()
    }

    func captureMicrophoneHealth(
        for purpose: CapturePurpose,
        at now: Date = Date()
    ) -> AudioStreamHealth {
        AudioStreamHealth.evaluate(
            sourceAvailable: microphoneAvailable,
            permissionGranted: dictationPermissions.canUseMicrophone,
            isMonitoring: isListening && capturePurpose == purpose,
            telemetry: localTrack(for: purpose).telemetry,
            now: now
        )
    }

    func captureSystemAudioHealth(
        for purpose: CapturePurpose,
        at now: Date = Date()
    ) -> AudioStreamHealth {
        let sourceAvailable = selectedProcessID.map { selectedID in
            processes.contains(where: { $0.id == selectedID })
        } ?? audioOutputAvailable
        return AudioStreamHealth.evaluate(
            sourceAvailable: sourceAvailable,
            isMonitoring: isListening && capturePurpose == purpose,
            telemetry: remoteTrack(for: purpose).telemetry,
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

    func transcript(for purpose: CapturePurpose) -> [TranscriptTurn] {
        transcript.filter { $0.purpose == purpose }
    }

    func clearTranscript(for purpose: CapturePurpose) {
        transcript.removeAll { $0.purpose == purpose }
        if capturePurpose == purpose {
            localTrack.partialTranscript = ""
            remoteTrack.partialTranscript = ""
            enqueueCompanionUpdate { hub in
                await hub.clearTranscript()
            }
        }
    }

    @discardableResult
    func copyQuickDictationToClipboard(_ entry: QuickDictationHistoryEntry) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(entry.text, forType: .string) else {
            errorMessage = "The quick dictation could not be copied to the clipboard."
            statusMessage = "Needs attention"
            return false
        }
        statusMessage = "Quick dictation copied"
        return true
    }

    func deleteQuickDictation(_ entry: QuickDictationHistoryEntry) {
        let updated = quickDictationHistory.filter { $0.id != entry.id }
        guard updated.count != quickDictationHistory.count else { return }
        do {
            try quickDictationHistoryStore.save(updated)
            quickDictationHistory = updated
            lastDictation = updated.first?.text ?? ""
            statusMessage = "Quick dictation deleted"
        } catch {
            presentQuickDictationHistoryError(action: "deleted", error: error)
        }
    }

    func deleteAllQuickDictations() {
        guard !quickDictationHistory.isEmpty else { return }
        do {
            try quickDictationHistoryStore.save([])
            quickDictationHistory = []
            lastDictation = ""
            statusMessage = "Quick Dictation history erased"
        } catch {
            presentQuickDictationHistoryError(action: "erased", error: error)
        }
    }

    func retryQuickDictation(_ recovery: QuickDictationRecoveryEntry) {
        guard !isDictationBusy else { return }
        guard dictationEnabled else {
            errorMessage = "Enable Quick Dictation before retrying a retained recording."
            statusMessage = "Quick Dictation recovery is waiting"
            return
        }
        if dictationService == nil {
            startDictationService(requestAccess: false)
        }
        guard let dictationService else {
            errorMessage = "Quick Dictation could not start the selected transcription provider."
            statusMessage = "Recovery retry needs attention"
            return
        }
        if dictationService.retryRecovery(recovery) {
            statusMessage = "Retrying retained quick dictation…"
        }
    }

    func revealQuickDictation(_ recovery: QuickDictationRecoveryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([
            quickDictationRecoveryStore.audioURL(for: recovery)
        ])
    }

    func deleteQuickDictation(_ recovery: QuickDictationRecoveryEntry) {
        do {
            try quickDictationRecoveryStore.remove(recovery)
            reloadQuickDictationRecoveries()
            statusMessage = "Retained dictation recording deleted"
        } catch {
            errorMessage =
                "The retained recording could not be deleted: \(error.localizedDescription)"
            statusMessage = "Quick Dictation recovery needs attention"
        }
    }

    func resetAPIExpenses() {
        apiExpenses = APIExpenseSummary(startedAt: Date())
        persistAPIExpenses()
        publishCompanionUsage()
    }

    private func persistAPIExpenses() {
        do {
            try apiExpenseStore.save(apiExpenses)
        } catch {
            // The estimate is informational; a failed write must not interrupt
            // a dictation or a meeting.
            errorMessage =
                "The API cost estimate could not be saved: \(error.localizedDescription)"
        }
    }

    func chooseReferenceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Reference Material Folder"
        panel.message =
            "PUnderclass reads supported documents locally and watches this folder for changes."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = referenceLibraryState.folderURL
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        UserDefaults.standard.set(
            folderURL.standardizedFileURL.path,
            forKey: Self.referenceFolderDefaultsKey
        )
        referenceLibraryService?.setFolder(folderURL)
    }

    func rescanReferenceFolder() {
        referenceLibraryService?.rescan()
    }

    func revealReferenceFolder() {
        guard let folderURL = referenceLibraryState.folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    func clearReferenceFolder() {
        UserDefaults.standard.removeObject(forKey: Self.referenceFolderDefaultsKey)
        referenceLibraryService?.setFolder(nil)
    }

    func generatedReplayState(
        for purpose: CapturePurpose
    ) -> SyntheticInterviewState {
        guard syntheticInterviewState.purpose == purpose else {
            return .ready(for: purpose)
        }
        return syntheticInterviewState
    }

    func canStartGeneratedReplay(for purpose: CapturePurpose) -> Bool {
        guard
            !syntheticInterviewState.isActive,
            !isListening,
            !isDictationBusy,
            capability.isCloudEnabled,
            referenceLibraryState.phase == .ready,
            referenceLibraryState.snapshot?.documents.isEmpty == false
        else {
            return false
        }
        return true
    }

    func generatedReplayReadinessDetail(
        for purpose: CapturePurpose
    ) -> String {
        let feature: CloudFeature = purpose == .meeting
            ? .mockMeeting
            : .mockInterview
        if let message = capability.lockMessage(for: feature) {
            return message
        }
        switch referenceLibraryState.phase {
        case .notConfigured:
            return "Choose a reference folder; its indexed documents will drive every question and response."
        case .scanning:
            return "Waiting for the reference folder to finish indexing…"
        case .failed:
            return "Fix the reference-folder error before generating the replay."
        case .ready:
            let count = referenceLibraryState.snapshot?.documents.count ?? 0
            guard count > 0 else {
                return "The reference folder has no supported readable documents."
            }
            let label = count == 1 ? "document" : "documents"
            return "Ready to generate from \(count) indexed \(label); the matching scenario is cached for repeatable reruns."
        }
    }

    func openCompanionDisplay() {
        NSWorkspace.shared.open(CompanionGateway.url)
    }

    @MainActor
    func startGeneratedReplay(
        for purpose: CapturePurpose,
        forceRegeneration: Bool = false
    ) {
        guard !syntheticInterviewState.isActive else { return }
        guard !isListening else {
            present(
                PUnderclassError.audio(
                    "Stop live capture before starting the generated \(purpose.title.lowercased()) replay."
                )
            )
            return
        }
        guard !isDictationBusy else {
            present(
                PUnderclassError.audio(
                    "Finish Quick Dictation before starting the generated \(purpose.title.lowercased()) replay."
                )
            )
            return
        }

        let feature: CloudFeature = purpose == .meeting
            ? .mockMeeting
            : .mockInterview
        if let message = capability.lockMessage(for: feature) {
            present(PUnderclassError.audio(message))
            return
        }
        let apiKey = apiKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            referenceLibraryState.phase == .ready,
            let references = referenceLibraryState.snapshot,
            !references.documents.isEmpty
        else {
            present(SyntheticInterviewError.referencesUnavailable)
            return
        }

        let scenarioStore = syntheticScenarioStore(for: purpose)
        let cachedScenario = forceRegeneration
            ? nil
            : try? scenarioStore.load(
                referenceRevision: references.revision,
                purpose: purpose
            )
        let runID = UUID()
        syntheticInterviewRunID = runID
        capturePurpose = purpose
        prepareCompanionForNewSession()
        localTrack = TrackViewState()
        remoteTrack = TrackViewState()
        refinementState = .idle
        syntheticInterviewState = SyntheticInterviewState(
            purpose: purpose,
            isGenerating: cachedScenario == nil,
            isRunning: false,
            hasRun: cachedScenario != nil,
            title: cachedScenario == nil
                ? "Generating \(purpose.title.lowercased()) from references"
                : "Loading cached reference \(purpose.title.lowercased())",
            detail: cachedScenario == nil
                ? "Creating five grounded exchanges from \(references.documents.count) indexed documents…"
                : "Reusing the scenario generated for reference revision \(references.revision.prefix(8)).",
            scenarioName: cachedScenario?.name
                ?? "Generated \(purpose.title.lowercased()) replay",
            referenceRevision: references.revision,
            currentTurn: 0,
            totalTurns: cachedScenario?.turns.count ?? 10
        )
        statusMessage = cachedScenario == nil
            ? "Generating \(purpose.title.lowercased()) replay…"
            : "Preparing \(purpose.title.lowercased()) replay…"
        publishCompanionSession()

        syntheticInterviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let scenario: SyntheticInterviewScenario
                if let cachedScenario {
                    scenario = cachedScenario
                    Self.liveAssistantLogger.notice(
                        "generated_replay_cache_hit purpose=\(purpose.rawValue, privacy: .public) document_count=\(references.documents.count, privacy: .public)"
                    )
                } else {
                    let generation = try await self.syntheticInterviewGeneratorClient
                        .generate(
                            apiKey: apiKey,
                            references: references,
                            purpose: purpose
                        )
                    try Task.checkCancellation()
                    self.recordAssistantUsage(generation.usage)
                    scenario = generation.scenario
                    Self.liveAssistantLogger.notice(
                        "generated_replay_created purpose=\(purpose.rawValue, privacy: .public) document_count=\(references.documents.count, privacy: .public) model_ms=\(generation.generationMilliseconds, privacy: .public)"
                    )
                    do {
                        try scenarioStore.save(scenario)
                    } catch {
                        Self.liveAssistantLogger.error(
                            "generated_replay_cache_failed purpose=\(purpose.rawValue, privacy: .public)"
                        )
                    }
                }
                guard
                    self.referenceLibraryState.snapshot?.revision
                        == scenario.referenceRevision
                else {
                    throw SyntheticInterviewError.referencesChanged
                }

                self.syntheticInterviewState = SyntheticInterviewState(
                    purpose: purpose,
                    isGenerating: false,
                    isRunning: true,
                    hasRun: true,
                    title: scenario.name,
                    detail: "Generated from \(scenario.referenceDocumentCount) indexed documents · starting audible replay.",
                    scenarioName: scenario.name,
                    referenceRevision: scenario.referenceRevision,
                    currentTurn: 0,
                    totalTurns: scenario.turns.count
                )
                self.syntheticInterviewReferences = references
                self.statusMessage =
                    "Generated \(purpose.title.lowercased()) replay running"
                self.publishCompanionSession()
                try await self.runSyntheticInterview(
                    scenario,
                    runID: runID
                )
            } catch is CancellationError {
                self.finishSyntheticInterview(
                    runID: runID,
                    title: "\(purpose.title) replay stopped",
                    detail: "The replay was stopped before all turns completed."
                )
            } catch {
                self.finishSyntheticInterview(
                    runID: runID,
                    title: "\(purpose.title) replay failed",
                    detail: error.localizedDescription
                )
                self.present(error)
            }
        }
    }

    @MainActor
    func regenerateGeneratedReplay(for purpose: CapturePurpose) {
        startGeneratedReplay(for: purpose, forceRegeneration: true)
    }

    @MainActor
    func stopGeneratedReplay() {
        guard syntheticInterviewState.isActive else { return }
        syntheticInterviewTask?.cancel()
        syntheticSpeechPlayer.stop()
    }

    private func syntheticScenarioStore(
        for purpose: CapturePurpose
    ) -> SyntheticInterviewScenarioStore {
        purpose == .meeting
            ? syntheticMeetingScenarioStore
            : syntheticInterviewScenarioStore
    }

    @MainActor
    private func runSyntheticInterview(
        _ scenario: SyntheticInterviewScenario,
        runID: UUID
    ) async throws {
        for (index, turn) in scenario.turns.enumerated() {
            try Task.checkCancellation()
            guard syntheticInterviewRunID == runID else {
                throw CancellationError()
            }

            let turnNumber = index + 1
            let turnID = "synthetic-\(runID.uuidString.lowercased())-\(turn.id)"
            let startedAt = Date()
            syntheticInterviewState = SyntheticInterviewState(
                purpose: scenario.purpose,
                isGenerating: false,
                isRunning: true,
                hasRun: true,
                title: "\(turn.speaker.displayName(for: scenario.purpose)) is speaking",
                detail: "Turn \(turnNumber) of \(scenario.turns.count) · transcript words stream with the audible voice.",
                scenarioName: scenario.name,
                referenceRevision: scenario.referenceRevision,
                currentTurn: turnNumber,
                totalTurns: scenario.turns.count
            )
            setSyntheticTrackItemID(turnID, speaker: turn.speaker)

            try await syntheticSpeechPlayer.speak(
                turn.text,
                speaker: turn.speaker
            ) { [weak self] partialText in
                self?.receiveSyntheticPartial(
                    id: turnID,
                    speaker: turn.speaker,
                    text: partialText
                )
            }
            receiveSyntheticPartial(
                id: turnID,
                speaker: turn.speaker,
                text: turn.text
            )

            let endedAt = Date()
            let partialPauseSeconds = Double(
                AssistantEvaluationPolicy.partialSpeechPauseMilliseconds
            ) / 1_000
            if AssistantEvaluationPolicy.shouldEvaluate(
                speaker: turn.speaker,
                purpose: scenario.purpose
            ) {
                syntheticInterviewState.title = "Model-answer window"
                syntheticInterviewState.detail = scenario.purpose == .meeting
                    ? "The other participant is quiet. Meeting Assistant starts a grounded response outline while the generated reply waits."
                    : "The interviewer is quiet. Answer Mirror starts a shorthand outline while the generated candidate reply waits."
            } else {
                syntheticInterviewState.title = "Comparison-answer pause"
                syntheticInterviewState.detail = scenario.purpose == .meeting
                    ? "The generated meeting response remains beside the assistant outline for comparison."
                    : "The candidate response remains beside the Answer Mirror outline for comparison."
            }
            try await Self.sleep(seconds: partialPauseSeconds)
            if AssistantEvaluationPolicy.shouldEvaluate(
                speaker: turn.speaker,
                purpose: scenario.purpose
            ) {
                scheduleLiveAssistant(
                    trigger: .partialTranscript,
                    turnID: turnID,
                    sourceText: turn.text,
                    speaker: turn.speaker,
                    purpose: scenario.purpose,
                    observedAt: endedAt
                )
            }
            try await Self.sleep(
                seconds: max(
                    0,
                    scenario.finalizationDelay - partialPauseSeconds
                )
            )

            finishSyntheticTurn(
                id: turnID,
                speaker: turn.speaker,
                text: turn.text,
                startedAt: startedAt,
                endedAt: endedAt,
                purpose: scenario.purpose
            )

            let remainingPause = max(
                0,
                turn.pauseAfterSpeech - scenario.finalizationDelay
            )
            if remainingPause > 0 {
                syntheticInterviewState.title = "\(scenario.purpose.title) pause"
                syntheticInterviewState.detail =
                    "Watch the Live Assistant timing before the next speaker begins."
                try await Self.sleep(seconds: remainingPause)
            }
        }

        finishSyntheticInterview(
            runID: runID,
            title: "\(scenario.purpose.title) replay complete",
            detail: "All \(scenario.turns.count) audible turns generated from \(scenario.referenceDocumentCount) reference documents were replayed."
        )
    }

    @MainActor
    private func receiveSyntheticPartial(
        id: String,
        speaker: SpeakerTag,
        text: String
    ) {
        guard syntheticInterviewState.isRunning else { return }
        if speaker == .you {
            localTrack.partialTranscript = text
        } else {
            remoteTrack.partialTranscript = text
        }
        publishCompanionPartial(id: id, speaker: speaker, text: text)
    }

    @MainActor
    private func finishSyntheticTurn(
        id: String,
        speaker: SpeakerTag,
        text: String,
        startedAt: Date,
        endedAt: Date,
        purpose: CapturePurpose
    ) {
        if speaker == .you {
            localTrack.partialTranscript = ""
        } else {
            remoteTrack.partialTranscript = ""
        }
        publishCompanionPartial(id: id, speaker: speaker, text: "")

        let turn = TranscriptTurn(
            id: id,
            purpose: purpose,
            speaker: speaker,
            startedAt: startedAt,
            endedAt: endedAt,
            liveText: text,
            text: text,
            refinement: .liveOnly(
                "Generated replay transcript; ASR was intentionally bypassed."
            )
        )
        transcript.removeAll { $0.id == id }
        transcript.append(turn)
        transcript.sort {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt < $1.startedAt
        }
        publishCompanionFinal(turn)
        if AssistantEvaluationPolicy.shouldEvaluate(
            speaker: speaker,
            purpose: purpose
        ) {
            scheduleLiveAssistant(
                trigger: .finalizedTurn,
                turnID: id,
                sourceText: text,
                speaker: speaker,
                purpose: purpose
            )
        }
    }

    @MainActor
    private func setSyntheticTrackItemID(
        _ id: String,
        speaker: SpeakerTag
    ) {
        if speaker == .you {
            localTrack.lastItemID = id
        } else {
            remoteTrack.lastItemID = id
        }
    }

    @MainActor
    private func finishSyntheticInterview(
        runID: UUID,
        title: String,
        detail: String
    ) {
        guard syntheticInterviewRunID == runID else { return }
        syntheticInterviewRunID = nil
        syntheticInterviewTask = nil
        if localTrack.lastItemID.hasPrefix("synthetic-") {
            publishCompanionPartial(
                id: localTrack.lastItemID,
                speaker: .you,
                text: ""
            )
        }
        if remoteTrack.lastItemID.hasPrefix("synthetic-") {
            publishCompanionPartial(
                id: remoteTrack.lastItemID,
                speaker: .other,
                text: ""
            )
        }
        localTrack.partialTranscript = ""
        remoteTrack.partialTranscript = ""
        syntheticInterviewState.isGenerating = false
        syntheticInterviewState.isRunning = false
        syntheticInterviewState.title = title
        syntheticInterviewState.detail = detail
        statusMessage = title
        publishCompanionSession()
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let milliseconds = max(0, Int(seconds * 1_000))
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    func copyTranscript(for purpose: CapturePurpose) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            transcriptText(for: purpose),
            forType: .string
        )
        statusMessage = "\(purpose.title) transcript copied"
    }

    func exportTranscript(for purpose: CapturePurpose) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(purpose.title) Transcript.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptText(for: purpose).write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            statusMessage = "\(purpose.title) transcript saved"
        } catch {
            present(error)
        }
    }

    private func makeClient(
        speaker: SpeakerTag,
        purpose: CapturePurpose,
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
                self.publishCompanionPartial(
                    id: "\(speaker.rawValue)-\(itemID)",
                    speaker: speaker,
                    text: text
                )
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
                let turn = TranscriptTurn(
                    id: transcriptID,
                    purpose: purpose,
                    speaker: speaker,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    liveText: text,
                    text: text,
                    refinement: refinement
                )
                self.transcript.append(turn)
                self.transcript.sort {
                    if $0.startedAt == $1.startedAt {
                        return $0.id < $1.id
                    }
                    return $0.startedAt < $1.startedAt
                }
                self.publishCompanionFinal(turn)
                if AssistantEvaluationPolicy.shouldEvaluate(
                    speaker: speaker,
                    purpose: purpose
                ) {
                    self.scheduleLiveAssistant(
                        trigger: .finalizedTurn,
                        turnID: transcriptID,
                        sourceText: text,
                        speaker: speaker,
                        purpose: purpose
                    )
                }
                guard
                    !pcm16Audio.isEmpty,
                    let refinementClient = self.refinementClients[speaker],
                    let activeContext = self.activeContext
                else {
                    return
                }
                let recentTranscript = self.transcript
                    .filter {
                        $0.purpose == purpose && $0.id != transcriptID
                    }
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
            },
            onSpeechPause: { [weak self] speechEndedAt in
                guard
                    let self,
                    self.activeSessionID == sessionID,
                    AssistantEvaluationPolicy.shouldEvaluate(
                        speaker: speaker,
                        purpose: purpose
                    )
                else {
                    return
                }
                let itemID: String
                let text: String
                if speaker == .you {
                    itemID = self.localTrack.lastItemID
                    text = self.localTrack.partialTranscript
                } else {
                    itemID = self.remoteTrack.lastItemID
                    text = self.remoteTrack.partialTranscript
                }
                guard !itemID.isEmpty else { return }
                self.scheduleLiveAssistant(
                    trigger: .partialTranscript,
                    turnID: "\(speaker.rawValue)-\(itemID)",
                    sourceText: text,
                    speaker: speaker,
                    purpose: purpose,
                    observedAt: speechEndedAt
                )
            },
            onUsage: { [weak self] usage in
                guard let self, self.activeSessionID == sessionID else { return }
                self.recordOpenAIUsage(usage)
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

    private func applyRefinement(
        transcriptID: String,
        purpose: CapturePurpose,
        text: String
    ) {
        guard let index = transcript.lastIndex(where: {
            $0.id == transcriptID && $0.purpose == purpose
        }) else {
            return
        }
        transcript[index].text = text
        transcript[index].refinement = .refined
        publishCompanionRevision(transcript[index])
    }

    private func markTurnLiveOnly(
        transcriptID: String,
        purpose: CapturePurpose,
        message: String
    ) {
        guard let index = transcript.lastIndex(where: {
            $0.id == transcriptID && $0.purpose == purpose
        }) else {
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

    private func transcriptionContext(
        for purpose: CapturePurpose
    ) throws -> TranscriptionContext {
        let keywords = keywordsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for keyword in keywords where
            keyword.contains("<")
            || keyword.contains(">")
            || keyword.contains("\r")
            || keyword.contains("\n") {
            throw PUnderclassError.invalidKeyword(keyword)
        }

        let separators = CharacterSet(charactersIn: ", \n\t")
        let languages = languagesText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return TranscriptionContext(
            prompt: contextPrompt(for: purpose).trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            keywords: keywords,
            languages: languages,
            delay: delay
        )
    }

    private func contextPrompt(for purpose: CapturePurpose) -> String {
        switch purpose {
        case .meeting:
            meetingContextPrompt
        case .interview:
            interviewContextPrompt
        }
    }

    private func transcriptText(for purpose: CapturePurpose) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return transcript(for: purpose).map {
            "[\(formatter.string(from: $0.startedAt))] \($0.speaker.displayName(for: purpose)): \($0.text)"
        }
        .joined(separator: "\n\n")
    }

    private func startDictationService(requestAccess: Bool) {
        if refinementEngine == .localWhisper || refinementEngine == .openAITranscribe {
            startWhisperWarmup()
        } else if refinementEngine == .localParakeet {
            startParakeetWarmup()
        }
        let service: HoldToDictateService
        if let dictationService {
            service = dictationService
        } else {
            let created = HoldToDictateService(
                canRecord: { [weak self] in
                    guard let self else { return false }
                    return !self.isListening
                        && !self.syntheticInterviewState.isActive
                },
                expectedLanguages: { [weak self] in
                    self?.dictationLanguages() ?? ["en"]
                },
                transcriptionContext: { [weak self] in
                    guard let self else {
                        return TranscriptionContext(
                            prompt: "",
                            keywords: [],
                            languages: ["en"],
                            delay: .medium
                        )
                    }
                    return try self.quickDictationContext()
                },
                shouldProduceLivePreview: { [weak self] in
                    self?.dictationPreviewEnabled == true
                },
                shouldCleanDictation: { [weak self] in
                    self?.dictationCleanupEnabled ?? true
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
                        self.dictationOverlay.update(
                            microphoneName: self.microphoneName
                        )
                        self.dictationPartialTranscript = ""
                        self.dictationTelemetry = TrackTelemetry(
                            monitoringStartedAt: Date(),
                            sourceFormat: "Starting \(self.microphoneName)…"
                        )
                    }
                },
                onMicrophone: { [weak self] microphoneName in
                    self?.dictationOverlay.update(
                        microphoneName: microphoneName
                    )
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
                    guard let self else { return false }
                    let textWasSaved = self.recordQuickDictation(text)
                    if self.isDictating {
                        self.dictationOverlay.show(result: text)
                        return textWasSaved
                    }
                    self.dictationPartialTranscript = text
                    self.dictationOverlay.show(result: text)
                    return textWasSaved
                },
                onUsage: { [weak self] usage in
                    self?.recordOpenAIUsage(usage)
                },
                onProgress: { [weak self] progress in
                    self?.dictationOverlay.update(progress: progress)
                },
                onDelivery: { [weak self] outcome in
                    self?.dictationOverlay.resolve(delivery: outcome)
                },
                onRecoveries: { [weak self] recoveries in
                    self?.recoverableDictations = recoveries
                },
                recoveryStore: quickDictationRecoveryStore,
                // Resolved rather than taken raw: a cloud preference left over
                // from when a key existed must not stop dictation working.
                transcriptionEngine: resolvedDictationEngine,
                apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dictationService = created
            service = created
        }
        _ = service.enable(requestAccess: requestAccess)
    }

    /// The engine dictation will actually use once availability is applied.
    var resolvedDictationEngine: TranscriptRefinementEngine {
        capability.resolvedEngine(preferring: refinementEngine)
    }

    private func restartDictationService() {
        dictationService?.disable()
        dictationService = nil
        startDictationService(requestAccess: false)
    }

    private func recordOpenAIUsage(_ usage: OpenAITranscriptionUsageRecord) {
        var updated = apiExpenses
        updated.record(usage)
        apiExpenses = updated
        persistAPIExpenses()
        publishCompanionUsage()
    }

    @discardableResult
    private func recordQuickDictation(_ text: String) -> Bool {
        let entry = QuickDictationHistoryEntry(text: text)
        let updatedHistory = [entry] + quickDictationHistory
        do {
            try quickDictationHistoryStore.save(updatedHistory)
            quickDictationHistory = updatedHistory
            lastDictation = text
            return true
        } catch {
            presentQuickDictationHistoryError(action: "saved", error: error)
            return false
        }
    }

    private func reloadQuickDictationRecoveries() {
        do {
            recoverableDictations = try quickDictationRecoveryStore.load()
        } catch {
            errorMessage =
                "Quick Dictation recoveries could not be loaded: \(error.localizedDescription)"
            statusMessage = "Quick Dictation recovery needs attention"
        }
    }

    private func presentQuickDictationHistoryError(action: String, error: Error) {
        errorMessage =
            "Quick Dictation history could not be \(action): \(error.localizedDescription)"
        statusMessage = "Quick Dictation history needs attention"
    }

    private func configureReferenceLibrary() {
        let service = ReferenceLibraryService { [weak self] state in
            self?.referenceLibraryState = state
            self?.publishCompanionReference()
        }
        referenceLibraryService = service
        guard
            let storedPath = UserDefaults.standard.string(
                forKey: Self.referenceFolderDefaultsKey
            ),
            !storedPath.isEmpty
        else {
            return
        }
        service.setFolder(URL(fileURLWithPath: storedPath, isDirectory: true))
    }

    private func startCompanionGateway() {
        companionGateway.start(
            onReady: { [weak self] in
                DispatchQueue.main.async {
                    self?.companionGatewayStatus =
                        "Companion ready at \(CompanionGateway.url.absoluteString)"
                }
            },
            onFailure: { [weak self] message in
                DispatchQueue.main.async {
                    self?.companionGatewayStatus = "Companion unavailable: \(message)"
                }
            }
        )
    }

    private func enqueueCompanionUpdate(
        _ operation: @escaping @Sendable (CompanionEventHub) async -> Void
    ) {
        let previous = companionUpdateTail
        let hub = companionGateway.hub
        companionUpdateTail = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation(hub)
        }
    }

    private func prepareCompanionForNewSession() {
        assistantGenerationTask?.cancel()
        assistantGenerationTask = nil
        assistantGenerationRequestID = nil
        assistantGenerationIdentity = nil
        enqueueCompanionUpdate { hub in
            await hub.clearTranscript()
        }
    }

    private func publishCompanionSession() {
        let listening = isListening || syntheticInterviewState.isRunning
        let status = statusMessage
        let isSyntheticSession = !isListening
            && (syntheticInterviewState.isActive || syntheticInterviewState.hasRun)
        let source: CompanionSessionSource = isSyntheticSession
            ? .syntheticInterview
            : .liveCapture
        let title = isSyntheticSession
            ? syntheticInterviewState.scenarioName
            : nil
        let purpose: CapturePurpose? = isSyntheticSession
            ? syntheticInterviewState.purpose
            : capturePurpose
        let isPreparingSyntheticInterview = syntheticInterviewState.isGenerating
        enqueueCompanionUpdate { hub in
            await hub.updateSession(
                isListening: listening,
                status: status,
                purpose: purpose,
                source: source,
                title: title,
                isPreparingSyntheticInterview: isPreparingSyntheticInterview
            )
        }
    }

    private func publishCompanionPartial(
        id: String,
        speaker: SpeakerTag,
        text: String
    ) {
        let partial = CompanionTranscriptPartial(
            id: id,
            speaker: speaker.rawValue.lowercased(),
            text: text
        )
        enqueueCompanionUpdate { hub in
            await hub.updatePartial(partial)
        }
    }

    private func publishCompanionFinal(_ turn: TranscriptTurn) {
        let projected = companionTurn(turn)
        enqueueCompanionUpdate { hub in
            await hub.appendFinal(projected)
        }
    }

    private func publishCompanionRevision(_ turn: TranscriptTurn) {
        let projected = companionTurn(turn)
        enqueueCompanionUpdate { hub in
            await hub.revise(projected)
        }
    }

    private func companionTurn(_ turn: TranscriptTurn) -> CompanionTranscriptTurn {
        let isRefined: Bool
        if case .refined = turn.refinement {
            isRefined = true
        } else {
            isRefined = false
        }
        return CompanionTranscriptTurn(
            id: turn.id,
            speaker: turn.speaker.rawValue.lowercased(),
            text: turn.text,
            startedAt: turn.startedAt,
            endedAt: turn.endedAt,
            isRefined: isRefined
        )
    }

    private func publishCompanionReference() {
        let phase: String
        switch referenceLibraryState.phase {
        case .notConfigured:
            phase = "notConfigured"
        case .scanning:
            phase = "scanning"
        case .ready:
            phase = "ready"
        case .failed:
            phase = "failed"
        }
        let snapshot = referenceLibraryState.snapshot
        let reference = CompanionReferenceState(
            configured: referenceLibraryState.folderURL != nil,
            folderName: referenceLibraryState.folderURL?.lastPathComponent
                ?? "No reference folder",
            phase: phase,
            documentCount: snapshot?.documents.count ?? 0,
            revision: snapshot?.revision ?? "",
            isWatching: referenceLibraryState.isWatching,
            issueCount: snapshot?.issues.count ?? 0
        )
        enqueueCompanionUpdate { hub in
            await hub.updateReference(reference)
        }
    }

    private func publishCompanionUsage() {
        let usage = CompanionUsageState(
            estimatedTranscriptionCostUSD: apiExpenses.totalCostUSD,
            estimatedLiveTranscriptionCostUSD: apiExpenses.liveCostUSD,
            estimatedFinalTranscriptionCostUSD: apiExpenses.finalCostUSD,
            liveAudioSeconds: apiExpenses.liveAudioSeconds,
            finalAudioSeconds: apiExpenses.finalAudioSeconds,
            assistantGenerations: apiExpenses.assistantGenerations,
            assistantInputTokens: apiExpenses.assistantInputTokens,
            assistantCachedInputTokens: apiExpenses.assistantCachedInputTokens,
            assistantCacheWriteTokens: apiExpenses.assistantCacheWriteTokens,
            assistantOutputTokens: apiExpenses.assistantOutputTokens,
            assistantReasoningTokens: apiExpenses.assistantReasoningTokens
        )
        enqueueCompanionUpdate { hub in
            await hub.updateUsage(usage)
        }
    }

    private func scheduleLiveAssistant(
        trigger: CompanionAssistantTrigger,
        turnID: String,
        sourceText: String,
        speaker: SpeakerTag,
        purpose: CapturePurpose,
        observedAt: Date = Date()
    ) {
        guard AssistantEvaluationPolicy.shouldEvaluate(
            speaker: speaker,
            purpose: purpose
        ) else {
            return
        }
        let normalizedText = sourceText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedText.isEmpty else { return }

        let identity = AssistantEvaluationIdentity(
            turnID: turnID,
            text: normalizedText
        )
        guard assistantGenerationIdentity != identity else {
            Self.liveAssistantLogger.debug(
                "assistant_check_coalesced trigger=\(trigger.rawValue, privacy: .public) turn_id=\(turnID, privacy: .public)"
            )
            return
        }

        assistantGenerationTask?.cancel()
        let requestID = UUID()
        assistantGenerationRequestID = requestID
        assistantGenerationIdentity = identity
        // The assistant is a hosted model; local-only mode withholds the key
        // rather than sending the transcript off the Mac.
        let isLocalOnly = privacyLockEnabled
        let assistantFeature: CloudFeature = purpose == .meeting
            ? .meetingCapture
            : .answerMirror
        let apiKey = capability.isAvailable(assistantFeature)
            ? apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let usesSyntheticReferences = syntheticInterviewState.isRunning
        let references = usesSyntheticReferences
            ? syntheticInterviewReferences
            : referenceLibraryState.snapshot
        let recentTranscript = transcript
            .filter { $0.purpose == purpose }
            .suffix(16)
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        let partialTranscript = [
            (SpeakerTag.you, localTrack.partialTranscript),
            (SpeakerTag.other, remoteTrack.partialTranscript)
        ]
        .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { "\($0.0.rawValue): \($0.1)" }
        .joined(separator: "\n")
        let sessionContext = contextPrompt(for: purpose).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let pendingCompanionUpdates = companionUpdateTail
        let hub = companionGateway.hub
        let client = liveAssistantClient
        let controller = WeakMeetingController(self)
        let delayMilliseconds = AssistantEvaluationPolicy.delayMilliseconds(
            for: trigger
        )
        let speechPauseMilliseconds = trigger == .partialTranscript
            ? AssistantEvaluationPolicy.partialSpeechPauseMilliseconds
            : 0

        Self.liveAssistantLogger.notice(
            "assistant_check_scheduled trigger=\(trigger.rawValue, privacy: .public) trigger_speaker=\(speaker.rawValue, privacy: .public) speech_pause_ms=\(speechPauseMilliseconds, privacy: .public) schedule_delay_ms=\(delayMilliseconds, privacy: .public)"
        )

        assistantGenerationTask = Task {
            do {
                if delayMilliseconds > 0 {
                    try await Task.sleep(
                        for: .milliseconds(delayMilliseconds)
                    )
                }
                guard !Task.isCancelled else { return }
                await pendingCompanionUpdates?.value
                guard !(await hub.suggestionsPaused()) else {
                    Self.liveAssistantLogger.notice(
                        "assistant_check_skipped reason=suggestions_paused"
                    )
                    return
                }

                guard !apiKey.isEmpty else {
                    Self.liveAssistantLogger.error(
                        "assistant_check_skipped reason=\(isLocalOnly ? "local_only_mode" : "api_key_missing", privacy: .public)"
                    )
                    await hub.assistantFailed(
                        isLocalOnly
                            ? "\(purpose.assistantTitle) is off because everything is set to stay on this Mac."
                            : "Add an OpenAI API key to turn on \(purpose.assistantTitle).",
                        unavailable: true
                    )
                    return
                }
                if references?.documents.isEmpty != false {
                    Self.liveAssistantLogger.notice(
                        "assistant_inference_grounding mode=general_knowledge reason=no_local_support"
                    )
                }

                let currentRevision = await MainActor.run {
                    controller.value?.assistantReferenceRevision(
                        usesSyntheticReferences: usesSyntheticReferences
                    )
                }
                guard currentRevision == references?.revision else {
                    Self.liveAssistantLogger.notice(
                        "assistant_check_skipped reason=reference_revision_changed"
                    )
                    return
                }

                let basedOnSequence = await hub.currentWatermark()
                let evaluationStartedAt = Date()
                let triggerToStartMilliseconds = Self.milliseconds(
                    from: observedAt,
                    to: evaluationStartedAt
                )
                Self.liveAssistantLogger.notice(
                    "assistant_inference_started sequence=\(basedOnSequence, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) trigger_to_start_ms=\(triggerToStartMilliseconds, privacy: .public)"
                )
                await hub.assistantWorking(
                    basedOnSequence: basedOnSequence,
                    trigger: trigger,
                    triggeredAt: observedAt,
                    startedAt: evaluationStartedAt
                )

                let generation = try await client.generate(
                    apiKey: apiKey,
                    references: references,
                    recentTranscript: recentTranscript,
                    currentPartial: partialTranscript,
                    otherSpeakerText: normalizedText,
                    sessionContext: sessionContext,
                    purpose: purpose,
                    basedOnSequence: basedOnSequence
                )
                await MainActor.run {
                    controller.value?.recordAssistantUsage(generation.usage)
                }
                let completedAt = Date()
                let totalLatencyMilliseconds = Self.milliseconds(
                    from: observedAt,
                    to: completedAt
                )
                Self.liveAssistantLogger.notice(
                    "assistant_inference_completed sequence=\(basedOnSequence, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) generation_ms=\(generation.generationMilliseconds, privacy: .public) total_ms=\(totalLatencyMilliseconds, privacy: .public) suggestion=\(generation.suggestion != nil, privacy: .public)"
                )
                guard !Task.isCancelled else { return }
                let isCurrentRevision = await MainActor.run {
                    controller.value?.assistantReferenceRevision(
                        usesSyntheticReferences: usesSyntheticReferences
                    ) == references?.revision
                }
                guard isCurrentRevision else {
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt
                    )
                    return
                }
                guard !(await hub.suggestionsPaused()) else {
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt
                    )
                    return
                }
                if var suggestion = generation.suggestion {
                    suggestion.trigger = trigger
                    suggestion.triggeredAt = observedAt
                    suggestion.totalLatencyMilliseconds =
                        totalLatencyMilliseconds
                    await hub.assistantSuggested(suggestion)
                } else {
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt
                    )
                }
            } catch is CancellationError {
                Self.liveAssistantLogger.debug(
                    "assistant_check_cancelled trigger=\(trigger.rawValue, privacy: .public)"
                )
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    controller.value?.allowAssistantRetry(requestID: requestID)
                }
                Self.liveAssistantLogger.error("assistant_inference_failed")
                await hub.assistantFailed(error.localizedDescription)
            }
        }
    }

    private func assistantReferenceRevision(
        usesSyntheticReferences: Bool
    ) -> String? {
        if usesSyntheticReferences {
            return syntheticInterviewReferences?.revision
        }
        return referenceLibraryState.snapshot?.revision
    }

    private func allowAssistantRetry(requestID: UUID) {
        guard assistantGenerationRequestID == requestID else { return }
        assistantGenerationIdentity = nil
    }

    private static func milliseconds(from startedAt: Date, to endedAt: Date) -> Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000))
    }

    private func recordAssistantUsage(_ usage: AssistantGenerationUsage) {
        var updated = apiExpenses
        updated.record(usage)
        apiExpenses = updated
        persistAPIExpenses()
        publishCompanionUsage()
    }

    private func startWhisperWarmup() {
        guard
            whisperWarmupTask == nil,
            !whisperPreparation.isInProgress,
            !whisperPreparation.isReady
        else {
            return
        }

        let startedAt = Date()
        whisperPreparation = WhisperPreparationState(
            stage: .checkingCache,
            startedAt: startedAt
        )
        let progressRelay = WhisperPreparationProgressRelay { [weak self] event in
            self?.handleWhisperPreparationEvent(
                event,
                startedAt: startedAt
            )
        }
        whisperWarmupTask = Task(priority: .utility) { [weak self] in
            do {
                try await WhisperTranscriber.shared.prepare { event in
                    progressRelay.send(event)
                }
                await MainActor.run { [weak self] in
                    guard self?.whisperPreparation.startedAt == startedAt else { return }
                    self?.whisperWarmupTask = nil
                    self?.whisperPreparation = WhisperPreparationState(
                        stage: .ready,
                        startedAt: startedAt,
                        finishedAt: Date()
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard self?.whisperPreparation.startedAt == startedAt else { return }
                    self?.whisperWarmupTask = nil
                    self?.whisperPreparation = WhisperPreparationState(
                        stage: .failed(error.localizedDescription),
                        startedAt: startedAt,
                        finishedAt: Date()
                    )
                }
            }
        }
    }

    private func handleWhisperPreparationEvent(
        _ event: WhisperPreparationEvent,
        startedAt: Date
    ) {
        guard
            whisperPreparation.startedAt == startedAt,
            whisperPreparation.isInProgress
        else {
            return
        }

        let stage: WhisperPreparationStage
        switch event {
        case .checkingCache:
            stage = .checkingCache
        case let .downloading(fractionCompleted):
            stage = .downloading(fractionCompleted: fractionCompleted)
        case let .loading(component):
            stage = .loading(component: component)
        }
        whisperPreparation = WhisperPreparationState(
            stage: stage,
            startedAt: startedAt
        )
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

    private func quickDictationContext() throws -> TranscriptionContext {
        let sharedContext = try transcriptionContext(for: .meeting)
        return TranscriptionContext(
            prompt: "",
            keywords: sharedContext.keywords,
            languages: sharedContext.languages,
            delay: .medium
        )
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
            selectedProcessID = nil
            throw PUnderclassError.audio(
                "\(previous.name) stopped or restarted and its new audio process could not be matched. All system audio is now selected; start again."
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
        if !isDictating {
            dictationOverlay.update(microphoneName: microphoneName)
        }

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
                            self.stopCapture()
                            self.present(error)
                        }
                    }
                }
            }
        )
    }

    private func stopImmediately() {
        assistantGenerationTask?.cancel()
        assistantGenerationTask = nil
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
        capturePurpose = nil
        localTrack.socket = .idle
        remoteTrack.socket = .idle
        refinementState = .idle
        publishCompanionSession()
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "Needs attention"
        publishCompanionSession()
    }

    deinit {
        assistantGenerationTask?.cancel()
        whisperWarmupTask?.cancel()
        parakeetWarmupTask?.cancel()
        referenceLibraryService?.stop()
        dictationOverlay.setEnabled(false)
        dictationService?.disable()
        inputDeviceMonitor?.stop()
        outputDeviceMonitor?.stop()
        stopImmediately()
        companionUpdateTail?.cancel()
        companionGateway.stop()
    }
}

private final class WeakMeetingController: @unchecked Sendable {
    weak var value: MeetingController?

    init(_ value: MeetingController) {
        self.value = value
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

private final class WhisperPreparationProgressRelay: @unchecked Sendable {
    private let handler: (WhisperPreparationEvent) -> Void

    init(handler: @escaping (WhisperPreparationEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: WhisperPreparationEvent) {
        DispatchQueue.main.async { [handler] in
            handler(event)
        }
    }
}

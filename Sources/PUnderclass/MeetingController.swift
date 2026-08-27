import AppKit
import CoreAudio
import Foundation
import OSLog
import UniformTypeIdentifiers

final class MeetingController: ObservableObject {
    @Published var apiKeyDraft = ""
    @Published var geminiAPIKeyDraft = ""
    @Published var exaAPIKeyDraft = ""
    @Published var webReferenceURLDraft = ""
    @Published var meetingContextPrompt =
        "An English-language one-on-one technical company meeting. Speakers may have different regional or non-native English accents. Discussion may include software, hardware, APIs, product names, acronyms, numbers, and action items."
    @Published private(set) var interviewContextPrompt =
        InterviewContextDraft.basicDescription
    @Published private(set) var interviewContextSuggestionPhase:
        InterviewContextSuggestionPhase = .idle
    @Published var keywordsText = ""
    @Published var languagesText = "en"
    @Published var delay: TranscriptionDelay = .medium
    @Published var preparationPurpose: CapturePurpose = .meeting
    @Published var assistantAnswerMode: AssistantAnswerMode = .grounded
    @Published var assistantEarlyBridgeEnabled = false
    @Published var assistantDeliveryMode: LiveAssistantDeliveryMode = .verified
    @Published var liveAssistantProvider: LiveAssistantProvider = .openAI
    @Published private(set) var activeAssistantAnswerMode:
        AssistantAnswerMode = .grounded
    @Published private(set) var activeAssistantEarlyBridgeEnabled = false
    @Published private(set) var activeAssistantDeliveryMode:
        LiveAssistantDeliveryMode = .verified
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
    @Published private(set) var activeCaptureUsesHostedTranscription = false
    @Published var statusMessage = "Ready"
    @Published var errorMessage: String?
    @Published var keyStatus = ""
    @Published var geminiKeyStatus = ""
    @Published var exaKeyStatus = ""
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
    @Published private(set) var referencePreparationState =
        ReferencePreparationState()
    @Published private(set) var companionGatewayStatus =
        "Starting companion display server…"
    @Published private(set) var companionGatewayEndpoint: CompanionGatewayEndpoint?
    @Published private(set) var companionGatewayError: String?
    @Published private(set) var latestInterviewArchiveURL: URL?
    @Published private(set) var syntheticInterviewState =
        SyntheticInterviewState.ready(for: .interview)

    private var microphoneCapture: MicrophoneCapture?
    private var processCapture: ProcessTapCapture?
    private var localPipeline: AudioTrackPipeline?
    private var remotePipeline: AudioTrackPipeline?
    private var localClient: (any MeetingAudioTranscribing)?
    private var remoteClient: (any MeetingAudioTranscribing)?
    private var refinementClients: [SpeakerTag: TranscriptRefining] = [:]
    private var refinementStates: [SpeakerTag: SocketState] = [:]
    private var activeContext: TranscriptionContext?
    private var activeSessionID: UUID?
    private var inputDeviceMonitor: DefaultInputDeviceMonitor?
    private var outputDeviceMonitor: DefaultOutputDeviceMonitor?
    private var microphoneRestartWorkItem: DispatchWorkItem?
    private var microphoneCaptureGeneration: UUID?
    private var microphoneRecoveryAttempts = 0
    private var microphoneRecoveryErrorMessage: String?
    private var microphoneSignalStartedAt: Date?
    private var microphoneLastSignalAt: Date?
    private var microphoneSignalErrorMessage: String?
    private var dictationService: HoldToDictateService?
    private var whisperWarmupTask: Task<Void, Never>?
    private var parakeetWarmupTask: Task<Void, Never>?
    private var referenceEmbeddingWarmupTask: Task<Void, Never>?
    private var referenceLibraryService: ReferenceLibraryService?
    private var referencePreparationTask: Task<Void, Never>?
    private var referencePreparationRunID: UUID?
    private var interviewContextSuggestionTask: Task<Void, Never>?
    private var interviewContextSuggestionRunID: UUID?
    private var referencePreparationPersistenceTask: Task<Void, Never>?
    private let companionGateway = CompanionGateway()
    private var companionGatewayAttemptID: UUID?
    private let openAILiveAssistantClient = LiveAssistantClient()
    private let geminiLiveAssistantClient = LiveAssistantClient.gemini()
    private let earlyInterviewBridgeClient = EarlyInterviewBridgeClient()
    private let syntheticInterviewGeneratorClient =
        SyntheticInterviewGeneratorClient()
    private let referenceWebContentClient = ReferenceWebContentClient()
    private let referencePreparationClient = ReferencePreparationClient()
    private let interviewContextSuggestionClient =
        InterviewContextSuggestionClient()
    private var companionUpdateTail: Task<Void, Never>?
    private var assistantGenerationTasks: [UUID: Task<Void, Never>] = [:]
    private var assistantGenerationArbitration =
        AssistantGenerationArbitrationState()
    private var assistantGenerationIdentity: AssistantEvaluationIdentity?
    private var assistantGenerationTurnID: String?
    private var assistantGenerationPrimaryTrigger: CompanionAssistantTrigger?
    private var assistantBridgeTask: Task<Void, Never>?
    private var assistantBridgeRequestID: UUID?
    private var assistantBridgeTurnID: String?
    private var assistantBridgeLatestText = ""
    private var assistantBridgeFormingAttemptCount = 0
    private var assistantBridgePauseAttemptCount = 0
    private var assistantBridgeFinalAttempted = false
    private var activeAssistantBridge: CompanionAssistantBridge?
    private var recentAssistantBridgeTexts: [String] = []
    private var latestRehearsalStory: AssistantRehearsalStoryContext?
    private var activeInterviewArchive: InterviewSessionArchive?
    private var interviewArchiveSaveErrorShown = false
    private let syntheticSpeechPlayer = SyntheticSpeechPlayer()
    private var syntheticInterviewTask: Task<Void, Never>?
    private var syntheticInterviewRunID: UUID?
    private var syntheticInterviewReferences: ReferenceLibrarySnapshot?
    private var activePreparedReferencePack: PreparedReferencePack?
    private let dictationOverlay = QuickDictationOverlayController()
    private let quickDictationHistoryStore: QuickDictationHistoryStore
    private let quickDictationRecoveryStore: QuickDictationRecoveryStore
    private let apiExpenseStore: APIExpenseStore
    private let referencePreparationStore: ReferencePreparationStore
    private let interviewSessionArchiveStore: InterviewSessionArchiveStore
    private let syntheticInterviewScenarioStore: SyntheticInterviewScenarioStore
    private let syntheticMeetingScenarioStore: SyntheticInterviewScenarioStore
    private let documentationDemoMode: DocumentationDemoMode?

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
    static let assistantAnswerModeDefaultsKey =
        "PUnderclass.AssistantAnswerMode"
    static let assistantEarlyBridgeDefaultsKey =
        "PUnderclass.AssistantEarlyBridgeEnabled"
    static let assistantDeliveryModeDefaultsKey =
        "PUnderclass.AssistantDeliveryMode"
    static let liveAssistantProviderDefaultsKey =
        "PUnderclass.LiveAssistantProvider"
    /// Renamed when local-only stopped being the primary gate and became a
    /// privacy override.
    static let legacyLocalOnlyModeDefaultsKey =
        "PUnderclass.LocalOnlyMode"
    private static let liveAssistantLogger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "LiveAssistant"
    )
    private static let audioCaptureLogger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "AudioCapture"
    )

    init(
        quickDictationHistoryStore: QuickDictationHistoryStore = .applicationSupport(),
        quickDictationRecoveryStore: QuickDictationRecoveryStore = .applicationSupport(),
        syntheticInterviewScenarioStore: SyntheticInterviewScenarioStore =
            .applicationSupport(for: .interview),
        syntheticMeetingScenarioStore: SyntheticInterviewScenarioStore =
            .applicationSupport(for: .meeting),
        apiExpenseStore: APIExpenseStore = .applicationSupport(),
        referencePreparationStore: ReferencePreparationStore = .applicationSupport(),
        interviewSessionArchiveStore: InterviewSessionArchiveStore =
            .applicationSupport(),
        documentationDemoMode: DocumentationDemoMode? = nil
    ) {
        self.quickDictationHistoryStore = quickDictationHistoryStore
        self.quickDictationRecoveryStore = quickDictationRecoveryStore
        self.syntheticInterviewScenarioStore = syntheticInterviewScenarioStore
        self.syntheticMeetingScenarioStore = syntheticMeetingScenarioStore
        self.apiExpenseStore = apiExpenseStore
        self.referencePreparationStore = referencePreparationStore
        self.interviewSessionArchiveStore = interviewSessionArchiveStore
        self.documentationDemoMode = documentationDemoMode
        if let documentationDemoMode {
            configureDocumentationDemo(documentationDemoMode)
            return
        }
        // A spend estimate that resets on every launch cannot answer "how much
        // did today cost", so the running total outlives the process.
        apiExpenses = (try? apiExpenseStore.load()) ?? APIExpenseSummary()
        apiKeyDraft = KeychainStore.loadAPIKey()
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? ""
        geminiAPIKeyDraft = KeychainStore.loadGeminiAPIKey()
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
            ?? ""
        exaAPIKeyDraft = KeychainStore.loadExaAPIKey()
            ?? ProcessInfo.processInfo.environment["EXA_API_KEY"]
            ?? ""
        do {
            referencePreparationState = ReferencePreparationState(
                archive: try referencePreparationStore.load()
            )
        } catch {
            errorMessage =
                "Prepared interview evidence could not be loaded: \(error.localizedDescription)"
        }
        interviewContextPrompt = referencePreparationState.interviewContext.text
        latestInterviewArchiveURL = try? interviewSessionArchiveStore
            .mostRecentArchiveURL()
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
        assistantAnswerMode = Self.storedAssistantAnswerMode()
        assistantEarlyBridgeEnabled = assistantAnswerMode == .plausibleRehearsal
            && Self.storedAssistantEarlyBridgeEnabled()
        assistantDeliveryMode = Self.storedAssistantDeliveryMode()
        liveAssistantProvider = Self.storedLiveAssistantProvider()
        // A cloud choice left over from before the key was removed must not
        // break dictation on the next launch.
        refinementEngine = capability.resolvedEngine(preferring: refinementEngine)
        dictationOverlay.setEnabled(dictationPreviewEnabled)
        dictationOverlay.update(
            engine: capability.resolvedEngine(preferring: refinementEngine)
        )
        // Core ML model loading is the longest launch task. Start it before
        // synchronous history and audio-device discovery so those operations
        // overlap instead of delaying Whisper preparation.
        startWhisperWarmup()
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

        configureReferenceLibrary()
        startReferenceEmbeddingWarmupIfNeeded()
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
        guard documentationDemoMode == nil else { return }
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

    private func configureDocumentationDemo(_ mode: DocumentationDemoMode) {
        let now = Date()
        apiKeyDraft = "documentation-demo-not-a-real-key"
        keyStatus = "Synthetic documentation data"
        statusMessage = "Documentation demo · synthetic data only"
        microphoneName = "Demo microphone"
        microphoneAvailable = true
        audioOutputName = "Demo system output"
        audioOutputAvailable = true
        dictationEnabled = true
        dictationPhase = .ready
        dictationPermissions = DictationPermissionState(
            canMonitorKeyboard: true,
            canPasteIntoOtherApps: true,
            canUseMicrophone: true
        )
        quickDictationHistory = [
            QuickDictationHistoryEntry(
                id: UUID(uuidString: "55899823-975C-4AD7-90B4-F870793A9E11")!,
                createdAt: now.addingTimeInterval(-240),
                text: "Draft the release notes and include the compatibility caveat."
            ),
            QuickDictationHistoryEntry(
                id: UUID(uuidString: "613260B7-DA82-4970-8BE1-77C1E093E5DC")!,
                createdAt: now.addingTimeInterval(-3_660),
                text: "Follow up with the design review after lunch."
            ),
            QuickDictationHistoryEntry(
                id: UUID(uuidString: "3D1120B5-E2A4-433D-B81E-F5B309A5A02D")!,
                createdAt: now.addingTimeInterval(-86_400),
                text: "The prototype should remain local-first and work without an account."
            )
        ]
        lastDictation = quickDictationHistory.first?.text ?? ""
        transcript = Self.documentationTranscript(now: now)
        companionGatewayStatus = "Companion display server running"
        companionGatewayEndpoint = CompanionGatewayEndpoint(
            port: CompanionGateway.preferredPort,
            lanAddresses: ["192.168.1.42"]
        )
        companionGatewayError = nil
        preparationPurpose = mode == .interview ? .interview : .meeting
    }

    private static func documentationTranscript(now: Date) -> [TranscriptTurn] {
        [
            TranscriptTurn(
                id: "documentation-meeting-other",
                purpose: .meeting,
                speaker: .other,
                startedAt: now.addingTimeInterval(-150),
                endedAt: now.addingTimeInterval(-142),
                liveText: "Can we keep the first release focused on the local workflow?",
                text: "Can we keep the first release focused on the local workflow?",
                refinement: .refined
            ),
            TranscriptTurn(
                id: "documentation-meeting-you",
                purpose: .meeting,
                speaker: .you,
                startedAt: now.addingTimeInterval(-138),
                endedAt: now.addingTimeInterval(-128),
                liveText: "Yes. Quick Dictation works locally, and hosted features remain optional.",
                text: "Yes. Quick Dictation works locally, and hosted features remain optional.",
                refinement: .refined
            ),
            TranscriptTurn(
                id: "documentation-interview-other",
                purpose: .interview,
                speaker: .other,
                startedAt: now.addingTimeInterval(-90),
                endedAt: now.addingTimeInterval(-82),
                liveText: "How would you make an audio pipeline resilient to a dropped connection?",
                text: "How would you make an audio pipeline resilient to a dropped connection?",
                refinement: .refined
            ),
            TranscriptTurn(
                id: "documentation-interview-you",
                purpose: .interview,
                speaker: .you,
                startedAt: now.addingTimeInterval(-78),
                endedAt: now.addingTimeInterval(-65),
                liveText: "I would preserve finalized local state, reconnect with bounded backoff, and make recovery visible.",
                text: "I would preserve finalized local state, reconnect with bounded backoff, and make recovery visible.",
                refinement: .refined
            )
        ]
    }

    func refreshAudioDevices() {
        guard documentationDemoMode == nil else { return }
        do {
            inputDevices = try CoreAudioUtilities.availableInputDevices()
            outputDevices = try CoreAudioUtilities.availableOutputDevices()
        } catch {
            present(error)
        }

        handleDefaultInputDeviceChange(CoreAudioUtilities.defaultInputDevice())
        handleDefaultOutputDeviceChange(CoreAudioUtilities.defaultOutputDevice())
    }

    static func documentationDemo(
        _ mode: DocumentationDemoMode,
        fileManager: FileManager = .default
    ) -> MeetingController {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "PermanentUnderclass-DocumentationDemo-\(UUID().uuidString)",
            isDirectory: true
        )
        return MeetingController(
            quickDictationHistoryStore: QuickDictationHistoryStore(
                fileURL: rootURL.appendingPathComponent("QuickDictationHistory.json")
            ),
            quickDictationRecoveryStore: QuickDictationRecoveryStore(
                directoryURL: rootURL.appendingPathComponent(
                    "QuickDictationRecoveries",
                    isDirectory: true
                )
            ),
            syntheticInterviewScenarioStore: SyntheticInterviewScenarioStore(
                fileURL: rootURL.appendingPathComponent("SyntheticInterviewScenario.json")
            ),
            syntheticMeetingScenarioStore: SyntheticInterviewScenarioStore(
                fileURL: rootURL.appendingPathComponent("SyntheticMeetingScenario.json")
            ),
            apiExpenseStore: APIExpenseStore(
                fileURL: rootURL.appendingPathComponent("APIExpenses.json")
            ),
            referencePreparationStore: ReferencePreparationStore(
                fileURL: rootURL.appendingPathComponent(
                    "ReferencePreparation.json"
                )
            ),
            interviewSessionArchiveStore: InterviewSessionArchiveStore(
                directoryURL: rootURL.appendingPathComponent(
                    "InterviewSessions",
                    isDirectory: true
                )
            ),
            documentationDemoMode: mode
        )
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
            publishCompanionSession()
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

    func saveGeminiAPIKey() {
        let key = geminiAPIKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !key.isEmpty else {
            geminiKeyStatus = "Enter a Gemini API key before saving."
            return
        }
        do {
            try KeychainStore.saveGeminiAPIKey(key)
            geminiAPIKeyDraft = key
            geminiKeyStatus = "Saved in Keychain"
            publishCompanionSession()
        } catch {
            present(error)
        }
    }

    func saveExaAPIKey() {
        let key = exaAPIKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !key.isEmpty else {
            exaKeyStatus = "Enter an Exa key before saving."
            return
        }
        do {
            try KeychainStore.saveExaAPIKey(key)
            exaAPIKeyDraft = key
            exaKeyStatus = "Saved in Keychain"
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
            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let usesHostedLiveTranscription = capability.isCloudEnabled
            if usesHostedLiveTranscription, key.isEmpty {
                throw PUnderclassError.noAPIKey
            }
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
            activateAssistantAnswerMode(for: purpose)
            prepareCompanionForNewSession()
            let context = try transcriptionContext(for: purpose)
            uniqueRefinementClients().forEach { $0.disconnect() }
            refinementClients.removeAll()
            refinementStates.removeAll()
            markRefiningTurnsLiveOnly(
                "Refinement was interrupted when new live capture started."
            )
            let sessionID = UUID()
            let sessionStartedAt = Date()
            activeSessionID = sessionID
            activeContext = context
            activeCaptureUsesHostedTranscription = usesHostedLiveTranscription
            microphoneRecoveryAttempts = 0
            clearMicrophoneRecoveryError()
            clearMicrophoneSignalError()
            beginInterviewArchive(
                id: sessionID,
                source: .liveCapture,
                startedAt: sessionStartedAt,
                referenceRevision: assistantReferenceStateRevision(
                    usesSyntheticReferences: false,
                    purpose: purpose
                )
            )
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
                apiKey: usesHostedLiveTranscription ? key : nil,
                context: context,
                sessionID: sessionID
            )
            let remoteClient = makeClient(
                speaker: .other,
                purpose: purpose,
                apiKey: usesHostedLiveTranscription ? key : nil,
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
            switch capability.resolvedEngine(preferring: refinementEngine) {
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
                    self?.handleMicrophoneTelemetry(
                        telemetry,
                        sessionID: sessionID
                    )
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

            if !usesHostedLiveTranscription {
                let localModel = capability.resolvedEngine(
                    preferring: refinementEngine
                ).shortLabel
                statusMessage = isLiveAssistantAvailable
                    ? "Listening locally with \(localModel) — suggestions appear after each completed turn"
                    : "Listening locally with \(localModel) — AI suggestions are off"
                publishCompanionSession()
            }
        } catch {
            stopImmediately()
            present(error)
        }
    }

    func stopCapture() {
        guard activeSessionID != nil else { return }
        isListening = false
        finishActiveInterviewArchive()
        statusMessage = "Finalizing transcript…"
        publishCompanionSession()
        microphoneRestartWorkItem?.cancel()
        microphoneRestartWorkItem = nil
        microphoneCaptureGeneration = nil
        microphoneRecoveryAttempts = 0

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
                self?.statusMessage = self?.activeCaptureUsesHostedTranscription == true
                    ? "Stopped — finishing second pass…"
                    : "Stopped — finishing local transcription…"
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

    static func storedAssistantAnswerMode(
        defaults: UserDefaults = .standard
    ) -> AssistantAnswerMode {
        guard
            let rawValue = defaults.string(
                forKey: assistantAnswerModeDefaultsKey
            ),
            let mode = AssistantAnswerMode(rawValue: rawValue)
        else {
            return .grounded
        }
        return mode
    }

    static func storedAssistantEarlyBridgeEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: assistantEarlyBridgeDefaultsKey) as? Bool
            ?? false
    }

    static func storedAssistantDeliveryMode(
        defaults: UserDefaults = .standard
    ) -> LiveAssistantDeliveryMode {
        guard
            let rawValue = defaults.string(
                forKey: assistantDeliveryModeDefaultsKey
            ),
            let mode = LiveAssistantDeliveryMode(rawValue: rawValue)
        else {
            return .verified
        }
        return mode
    }

    static func storeAssistantDeliveryMode(
        _ mode: LiveAssistantDeliveryMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            mode.rawValue,
            forKey: assistantDeliveryModeDefaultsKey
        )
    }

    static func storedLiveAssistantProvider(
        defaults: UserDefaults = .standard
    ) -> LiveAssistantProvider {
        guard
            let rawValue = defaults.string(
                forKey: liveAssistantProviderDefaultsKey
            ),
            let provider = LiveAssistantProvider(rawValue: rawValue)
        else {
            return .openAI
        }
        return provider
    }

    static func storeAssistantPreferences(
        answerMode: AssistantAnswerMode,
        earlyBridgeEnabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            answerMode.rawValue,
            forKey: assistantAnswerModeDefaultsKey
        )
        defaults.set(
            answerMode == .plausibleRehearsal && earlyBridgeEnabled,
            forKey: assistantEarlyBridgeDefaultsKey
        )
    }

    func setAssistantAnswerModePreference(_ mode: AssistantAnswerMode) {
        assistantAnswerMode = mode
        if mode == .grounded {
            assistantEarlyBridgeEnabled = false
        }
        Self.storeAssistantPreferences(
            answerMode: assistantAnswerMode,
            earlyBridgeEnabled: assistantEarlyBridgeEnabled
        )
    }

    func setAssistantEarlyBridgePreference(_ enabled: Bool) {
        assistantEarlyBridgeEnabled = assistantAnswerMode == .plausibleRehearsal
            && enabled
        Self.storeAssistantPreferences(
            answerMode: assistantAnswerMode,
            earlyBridgeEnabled: assistantEarlyBridgeEnabled
        )
    }

    func setAssistantDeliveryModePreference(
        _ mode: LiveAssistantDeliveryMode
    ) {
        assistantDeliveryMode = mode
        Self.storeAssistantDeliveryMode(mode)
    }

    func setLiveAssistantProvider(_ provider: LiveAssistantProvider) {
        guard liveAssistantProvider != provider else { return }
        liveAssistantProvider = provider
        UserDefaults.standard.set(
            provider.rawValue,
            forKey: Self.liveAssistantProviderDefaultsKey
        )
        statusMessage = "Live suggestions will use \(provider.model)"
        publishCompanionSession()
    }

    var hasLiveAssistantAPIKey: Bool {
        !liveAssistantAPIKey.isEmpty
    }

    var isLiveAssistantAvailable: Bool {
        hasLiveAssistantAPIKey && !privacyLockEnabled
    }

    var liveAssistantAccess: FeatureAccess {
        if privacyLockEnabled { return .blockedByPrivacyLock }
        return hasLiveAssistantAPIKey ? .available : .needsAPIKey
    }

    var liveAssistantModel: String {
        liveAssistantProvider.model
    }

    var liveAssistantAPIKeyName: String {
        liveAssistantProvider.keyName
    }

    func liveAssistantLockMessage(for purpose: CapturePurpose) -> String? {
        switch liveAssistantAccess {
        case .available:
            nil
        case .needsAPIKey:
            "Add \(liveAssistantAPIKeyName) to turn on \(purpose.assistantTitle)."
        case .blockedByPrivacyLock:
            "\(purpose.assistantTitle) is off because everything is set to stay on this Mac."
        }
    }

    private var liveAssistantAPIKey: String {
        let draft = switch liveAssistantProvider {
        case .openAI:
            apiKeyDraft
        case .gemini:
            geminiAPIKeyDraft
        }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedLiveAssistantClient: LiveAssistantClient {
        switch liveAssistantProvider {
        case .openAI:
            openAILiveAssistantClient
        case .gemini:
            geminiLiveAssistantClient
        }
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
            statusMessage = "Cloud features are available again"
            publishCompanionSession()
            return
        }
        if isListening {
            stopCapture()
        }
        cancelInterviewContextSuggestion()
        if referencePreparationState.phase.isWorking {
            referencePreparationTask?.cancel()
            referencePreparationTask = nil
            referencePreparationRunID = nil
            referencePreparationState.phase = .idle
            for index in referencePreparationState.webSources.indices
                where referencePreparationState.webSources[index].status
                    == .fetching
            {
                referencePreparationState.webSources[index].status = .pending
                referencePreparationState.webSources[index].detail =
                    "Cancelled by privacy setting"
            }
            persistReferencePreparation()
        }
        if refinementEngine.isCloud {
            selectRefinementEngine(.localWhisper)
        }
        statusMessage = "Everything stays on this Mac"
        publishCompanionSession()
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
            now: now,
            detectDigitalSilence: true
        )
    }

    func localTrack(for purpose: CapturePurpose) -> TrackViewState {
        capturePurpose == purpose ? localTrack : TrackViewState()
    }

    func usesHostedLiveTranscription(for purpose: CapturePurpose) -> Bool {
        if isListening, capturePurpose == purpose {
            return activeCaptureUsesHostedTranscription
        }
        return capability.isCloudEnabled
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
            now: now,
            detectDigitalSilence: true
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
        guard documentationDemoMode == nil else { return }
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
            "PermanentUnderclass reads supported documents locally and watches this folder for changes."
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

    func chooseResumeFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Resume Used for Interview Evidence"
        panel.message = capability.isAvailable(.answerMirror)
            ? "Choose the current resume or CV. Its text will be sent to OpenAI once to draft an editable interview description, then it will be treated as the authoritative resume during evidence preparation."
            : "Choose the current resume or CV. It stays on this Mac while OpenAI features are unavailable and will be treated as the authoritative resume during evidence preparation."
        panel.prompt = "Use Resume"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .rtf, .text]
        panel.directoryURL = referencePreparationState.resumeSource?.fileURL
            .deletingLastPathComponent()
            ?? referenceLibraryState.folderURL
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        do {
            let citationPath = Self.resumeCitationPath(for: fileURL)
            let document = try ReferenceLibraryScanner().loadDocument(
                fileURL: fileURL,
                relativePath: citationPath
            )
            let selectedSource = ReferenceResumeSource(
                filePath: fileURL.standardizedFileURL.path,
                citationPath: citationPath,
                contentDigest: ReferencePreparationDigest.hash([
                    document.content
                ]),
                sourceByteCount: document.sourceByteCount
            )
            let resumeChanged = referencePreparationState.resumeSource
                != selectedSource
            referencePreparationState.resumeSource = selectedSource
            if resumeChanged {
                resetInterviewContextToBasicDescription()
            }
            referencePreparationState.phase = .idle
            persistReferencePreparation()
            statusMessage = "Selected \(fileURL.lastPathComponent) as the interview resume"
            if capability.isAvailable(.answerMirror),
               resumeChanged
                    || referencePreparationState.interviewContext.origin
                        == .basic
            {
                suggestInterviewContextFromResume()
            }
        } catch {
            present(error)
        }
    }

    func revealResumeFile() {
        guard let source = referencePreparationState.resumeSource else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source.fileURL])
    }

    func clearResumeFile() {
        guard !referencePreparationState.phase.isWorking else { return }
        referencePreparationState.resumeSource = nil
        resetInterviewContextToBasicDescription()
        referencePreparationState.phase = .idle
        persistReferencePreparation()
    }

    var canSuggestInterviewContext: Bool {
        referencePreparationState.resumeSource != nil
            && capability.isAvailable(.answerMirror)
            && !isListening
            && !syntheticInterviewState.isActive
            && !referencePreparationState.phase.isWorking
            && !interviewContextSuggestionPhase.isWorking
    }

    func updateInterviewContextPrompt(_ value: String) {
        cancelInterviewContextSuggestion()
        interviewContextPrompt = value
        referencePreparationState.interviewContext = InterviewContextDraft(
            text: value,
            origin: .userEdited
        )
        if !referencePreparationState.phase.isWorking {
            referencePreparationState.phase = .idle
        }
        scheduleReferencePreparationPersistence()
    }

    func suggestInterviewContextFromResume() {
        guard
            canSuggestInterviewContext,
            let source = referencePreparationState.resumeSource
        else {
            return
        }
        let document: ReferenceDocument
        do {
            document = try ReferenceLibraryScanner().loadDocument(
                fileURL: source.fileURL,
                relativePath: source.citationPath
            )
        } catch {
            interviewContextSuggestionPhase = .failed(
                error.localizedDescription
            )
            return
        }
        let resumeDigest = ReferencePreparationDigest.hash([
            document.content
        ])
        referencePreparationState.resumeSource = ReferenceResumeSource(
            filePath: source.filePath,
            citationPath: source.citationPath,
            contentDigest: resumeDigest,
            sourceByteCount: document.sourceByteCount
        )
        persistReferencePreparation()

        cancelInterviewContextSuggestion()
        let runID = UUID()
        interviewContextSuggestionRunID = runID
        interviewContextSuggestionPhase = .generating
        statusMessage = "Drafting an interview description from the resume…"
        let apiKey = apiKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let client = interviewContextSuggestionClient
        interviewContextSuggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let generation = try await client.suggest(
                    apiKey: apiKey,
                    resumeText: document.content
                )
                try Task.checkCancellation()
                guard self.interviewContextSuggestionRunID == runID else {
                    return
                }
                self.interviewContextSuggestionTask = nil
                self.interviewContextSuggestionRunID = nil
                self.recordAssistantUsage(generation.usage)
                guard let suggestion = generation.suggestion else {
                    self.interviewContextSuggestionPhase = .insufficient
                    self.statusMessage =
                        "The basic interview description is still in use"
                    return
                }
                self.interviewContextPrompt = suggestion
                self.referencePreparationState.interviewContext =
                    InterviewContextDraft(
                        text: suggestion,
                        origin: .resumeSuggestion,
                        sourceResumeDigest: resumeDigest
                    )
                self.referencePreparationState.phase = .idle
                self.interviewContextSuggestionPhase = .idle
                self.persistReferencePreparation()
                self.statusMessage =
                    "Drafted an editable interview description from the resume"
            } catch is CancellationError {
                return
            } catch {
                guard self.interviewContextSuggestionRunID == runID else {
                    return
                }
                self.interviewContextSuggestionTask = nil
                self.interviewContextSuggestionRunID = nil
                self.interviewContextSuggestionPhase = .failed(
                    error.localizedDescription
                )
                self.statusMessage =
                    "The basic interview description is still in use"
            }
        }
    }

    private func resetInterviewContextToBasicDescription() {
        cancelInterviewContextSuggestion()
        interviewContextPrompt = InterviewContextDraft.basicDescription
        referencePreparationState.interviewContext = InterviewContextDraft()
    }

    private func cancelInterviewContextSuggestion() {
        interviewContextSuggestionTask?.cancel()
        interviewContextSuggestionTask = nil
        interviewContextSuggestionRunID = nil
        interviewContextSuggestionPhase = .idle
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

    private static func resumeCitationPath(for fileURL: URL) -> String {
        "Selected Resume/\(fileURL.lastPathComponent)"
    }

    func addReferenceWebSource() {
        do {
            let url = try ReferenceWebContentClient.validatedURL(
                webReferenceURLDraft
            )
            guard !referencePreparationState.webSources.contains(where: {
                $0.requestedURL == url.absoluteString
            }) else {
                webReferenceURLDraft = ""
                return
            }
            referencePreparationState.webSources.append(
                ReferenceWebSource(url: url)
            )
            referencePreparationState.phase = .idle
            webReferenceURLDraft = ""
            persistReferencePreparation()
        } catch {
            present(error)
        }
    }

    func removeReferenceWebSource(id: String) {
        guard !referencePreparationState.phase.isWorking else { return }
        referencePreparationState.webSources.removeAll { $0.id == id }
        referencePreparationState.phase = .idle
        persistReferencePreparation()
    }

    func setPreparedReferenceEnabled(id: String, enabled: Bool) {
        guard !referencePreparationState.phase.isWorking else { return }
        guard var pack = referencePreparationState.pack else { return }
        guard let index = pack.cards.firstIndex(where: { $0.id == id }) else {
            return
        }
        pack.cards[index].isEnabled = enabled
        referencePreparationState.pack = pack
        persistReferencePreparation()
    }

    var isInterviewEvidenceCurrent: Bool {
        referencePreparationState.pack?.isCurrent(
            purpose: .interview,
            localReferenceRevision: currentLocalReferenceRevision,
            webSources: referencePreparationState.webSources,
            sessionContext: interviewContextPrompt
        ) == true
    }

    var isInterviewEvidenceResolved: Bool {
        isInterviewEvidenceCurrent
            && referencePreparationState.pack?.sourceManifest?.requiresReview
                != true
    }

    var interviewPreparationReadiness: InterviewPreparationReadiness {
        let pack = referencePreparationState.pack
        return .resolve(
            isAssistantAvailable: capability.isAvailable(.answerMirror),
            hasActiveSession: isListening
                || syntheticInterviewState.isActive,
            isPreparing: referencePreparationState.phase.isWorking,
            hasExplicitResume: referencePreparationState.resumeSource != nil,
            hasInterviewDescription: !interviewContextPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            hasPack: pack != nil,
            isPackCurrent: isInterviewEvidenceCurrent,
            requiresSourceReview: pack?.sourceManifest?.requiresReview == true,
            enabledCardCount: pack?.enabledCardCount ?? 0
        )
    }

    var isInterviewPreparationReady: Bool {
        interviewPreparationReadiness.isReady
    }

    /// Unlike the guided readiness state, this remains true during an active
    /// session so the pack selected at start can continue to be used.
    private var hasReadyInterviewEvidence: Bool {
        referencePreparationState.resumeSource != nil
            && !interviewContextPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            && isInterviewEvidenceResolved
            && (referencePreparationState.pack?.enabledCardCount ?? 0) > 0
    }

    private var currentLocalReferenceRevision: String {
        ReferencePreparationDigest.localSourceRevision(
            folderRevision: referenceLibraryState.snapshot?.revision,
            resumeSource: referencePreparationState.resumeSource
        )
    }

    var canPrepareInterviewEvidence: Bool {
        guard
            !referencePreparationState.phase.isWorking,
            !interviewContextSuggestionPhase.isWorking,
            !isListening,
            !syntheticInterviewState.isActive,
            capability.isAvailable(.answerMirror),
            referencePreparationState.resumeSource != nil,
            !interviewContextPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        else {
            return false
        }
        return true
    }

    func interviewEvidenceReadinessDetail() -> String {
        switch interviewPreparationReadiness {
        case .unavailable:
            return capability.lockMessage(for: .answerMirror)
                ?? "Answer Mirror is unavailable."
        case .activeSession:
            return "Stop the active interview or replay before rebuilding evidence."
        case .preparing:
            return referencePreparationState.phase.title
        case .needsResume:
            return "Choose the current resume you want Answer Mirror to use."
        case .needsInterviewDescription:
            return "Add the visible interview description Answer Mirror should use."
        case .needsEvidence:
            if case let .failed(message) = referencePreparationState.phase {
                return "Preparation failed: \(message)"
            }
            if referencePreparationState.pack == nil {
                return "Build a compact, interview-relevant evidence pack from the selected resume."
            }
            return "Sources or the interview description changed. Rebuild before the next interview."
        case .needsSourceReview:
            return "The selected resume conflicts with another source. Review the source choices before continuing."
        case .needsUsableEvidence:
            return "The sources were read, but none can establish usable candidate experience."
        case let .ready(cardCount):
            let label = cardCount == 1 ? "card" : "cards"
            return "Ready: \(cardCount) evidence \(label) will ground Answer Mirror."
        }
    }

    func prepareInterviewEvidence() {
        guard canPrepareInterviewEvidence else { return }
        let apiKey = apiKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !apiKey.isEmpty else {
            present(PUnderclassError.noAPIKey)
            return
        }

        let explicitResume: ReferenceDocument?
        var resumeSuggestionBecameStale = false
        do {
            if let source = referencePreparationState.resumeSource {
                let document = try ReferenceLibraryScanner().loadDocument(
                    fileURL: source.fileURL,
                    relativePath: source.citationPath
                )
                let refreshedSource = ReferenceResumeSource(
                    filePath: source.filePath,
                    citationPath: source.citationPath,
                    contentDigest: ReferencePreparationDigest.hash([
                        document.content
                    ]),
                    sourceByteCount: document.sourceByteCount
                )
                referencePreparationState.resumeSource = refreshedSource
                resumeSuggestionBecameStale =
                    referencePreparationState.interviewContext.origin
                        == .resumeSuggestion
                    && referencePreparationState.interviewContext
                        .sourceResumeDigest != refreshedSource.contentDigest
                explicitResume = document
            } else {
                explicitResume = nil
            }
        } catch {
            referencePreparationState.phase = .failed(error.localizedDescription)
            persistReferencePreparation()
            present(error)
            return
        }
        if resumeSuggestionBecameStale {
            resetInterviewContextToBasicDescription()
            referencePreparationState.phase = .idle
            persistReferencePreparation()
            statusMessage =
                "The resume changed. Review or regenerate its interview description before preparing."
            return
        }

        referencePreparationTask?.cancel()
        let runID = UUID()
        referencePreparationRunID = runID
        let requestedSources = referencePreparationState.webSources
        let localReferences = referenceLibraryState.snapshot
        let localRevision = currentLocalReferenceRevision
        let sessionContext = interviewContextPrompt
        let exaAPIKey = exaAPIKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let previousCards = referencePreparationState.pack?.cards ?? []

        referencePreparationState.phase = requestedSources.isEmpty
            ? .extracting
            : .fetching
        for index in referencePreparationState.webSources.indices {
            referencePreparationState.webSources[index].status = .fetching
            referencePreparationState.webSources[index].detail = ""
        }
        persistReferencePreparation()
        statusMessage = "Preparing interview evidence…"

        let webClient = referenceWebContentClient
        let preparationClient = referencePreparationClient
        referencePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for source in requestedSources {
                    try Task.checkCancellation()
                    do {
                        let fetched = try await webClient.fetch(
                            url: source.requestedURL,
                            exaAPIKey: exaAPIKey
                        )
                        guard self.referencePreparationRunID == runID else {
                            return
                        }
                        self.updateWebSource(source.id) { updated in
                            updated.resolvedURL = fetched.resolvedURL
                            updated.title = fetched.title
                            updated.content = fetched.content
                            updated.contentDigest = ReferencePreparationDigest.hash([
                                fetched.content
                            ])
                            updated.fetchedAt = fetched.fetchedAt
                            updated.provider = fetched.provider
                            updated.status = .ready
                            updated.detail =
                                "\(fetched.provider.title) · \(fetched.content.count) characters"
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard self.referencePreparationRunID == runID else {
                            return
                        }
                        self.updateWebSource(source.id) { updated in
                            updated.content = ""
                            updated.contentDigest = nil
                            updated.status = Self.webSourceFailureStatus(
                                for: error
                            )
                            updated.detail = error.localizedDescription
                        }
                    }
                    self.persistReferencePreparation()
                }

                try Task.checkCancellation()
                guard self.referencePreparationRunID == runID else { return }
                self.referencePreparationState.phase = .extracting
                let webSources = self.referencePreparationState.webSources
                let combined = try ReferencePreparationClient.combinedReferences(
                    localReferences: localReferences,
                    explicitResume: explicitResume,
                    webSources: webSources
                )
                let webRevision = ReferencePreparationDigest.webSourceRevision(
                    webSources
                )
                let generation = try await preparationClient.prepare(
                    apiKey: apiKey,
                    references: combined,
                    purpose: .interview,
                    sessionContext: sessionContext,
                    localReferenceRevision: localRevision,
                    webSourceRevision: webRevision,
                    explicitResumePath: explicitResume?.relativePath,
                    previousCards: previousCards
                )
                try Task.checkCancellation()
                guard self.referencePreparationRunID == runID else { return }
                self.referencePreparationState.pack = generation.pack
                self.referencePreparationState.phase = .ready
                self.referencePreparationTask = nil
                self.referencePreparationRunID = nil
                self.recordAssistantUsage(generation.usage)
                self.persistReferencePreparation()
                self.statusMessage =
                    "Prepared \(generation.pack.cards.count) interview evidence cards"
            } catch is CancellationError {
                return
            } catch {
                guard self.referencePreparationRunID == runID else { return }
                self.referencePreparationState.phase = .failed(
                    error.localizedDescription
                )
                self.referencePreparationTask = nil
                self.referencePreparationRunID = nil
                self.persistReferencePreparation()
                self.present(error)
            }
        }
    }

    private func updateWebSource(
        _ id: String,
        update: (inout ReferenceWebSource) -> Void
    ) {
        guard let index = referencePreparationState.webSources.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }
        update(&referencePreparationState.webSources[index])
    }

    private static func webSourceFailureStatus(
        for error: Error
    ) -> ReferenceWebSourceStatus {
        guard
            let webError = error as? ReferenceWebContentError,
            case let .allProvidersFailed(exaKeyAvailable, _) = webError,
            !exaKeyAvailable
        else {
            return .failed
        }
        return .keyRequired
    }

    private func persistReferencePreparation() {
        referencePreparationPersistenceTask?.cancel()
        referencePreparationPersistenceTask = nil
        do {
            try referencePreparationStore.save(
                ReferencePreparationArchive(state: referencePreparationState)
            )
        } catch {
            errorMessage =
                "Prepared interview evidence could not be saved: \(error.localizedDescription)"
        }
    }

    private func scheduleReferencePreparationPersistence() {
        referencePreparationPersistenceTask?.cancel()
        referencePreparationPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.persistReferencePreparation()
        }
    }

    func generatedReplayState(
        for purpose: CapturePurpose
    ) -> SyntheticInterviewState {
        guard syntheticInterviewState.purpose == purpose else {
            return .ready(for: purpose)
        }
        return syntheticInterviewState
    }

    private func replayReferences(
        for purpose: CapturePurpose
    ) -> ReferenceLibrarySnapshot? {
        if purpose == .interview {
            guard
                let pack = referencePreparationState.pack,
                hasReadyInterviewEvidence
            else {
                return nil
            }
            return pack.snapshot(
                for: interviewContextPrompt,
                folderURL: referenceLibraryState.snapshot?.folderURL,
                maximumCards: 16
            )
        }
        guard referenceLibraryState.phase == .ready else { return nil }
        return referenceLibraryState.snapshot
    }

    private func replaySourceStateRevision(
        for purpose: CapturePurpose
    ) -> String? {
        // This method is called from SwiftUI readiness rendering. Keep it to
        // persisted metadata; replayReferences performs semantic selection.
        if purpose == .interview {
            guard
                let pack = referencePreparationState.pack,
                hasReadyInterviewEvidence
            else {
                return nil
            }
            return "prepared:\(pack.revision)"
        }
        guard
            referenceLibraryState.phase == .ready,
            let snapshot = referenceLibraryState.snapshot,
            !snapshot.documents.isEmpty
        else {
            return nil
        }
        return "library:\(snapshot.revision)"
    }

    func canStartGeneratedReplay(for purpose: CapturePurpose) -> Bool {
        guard
            !syntheticInterviewState.isActive,
            !isListening,
            !isDictationBusy,
            capability.isCloudEnabled,
            isLiveAssistantAvailable,
            replaySourceStateRevision(for: purpose) != nil
        else {
            return false
        }
        return true
    }

    func canStartWebSearchTest() -> Bool {
        !syntheticInterviewState.isActive
            && !isListening
            && !isDictationBusy
            && isLiveAssistantAvailable
    }

    func webSearchTestReadinessDetail() -> String {
        if let message = liveAssistantLockMessage(for: .interview) {
            return message
        }
        if syntheticInterviewState.isActive {
            return "Stop the generated replay before running the web-search test."
        }
        if isListening {
            return "Stop live capture before running the web-search test."
        }
        if isDictationBusy {
            return "Finish Quick Dictation before running the web-search test."
        }
        return "Asks one audible, time-sensitive CUDA question and requires hosted web search."
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
        if let message = liveAssistantLockMessage(for: purpose) {
            return "\(message) Generated replays use the selected provider for their response cues."
        }
        if purpose == .interview,
           referencePreparationState.resumeSource == nil
        {
            return "Choose the current resume in Prepare Interview before generating an interview."
        }
        if purpose == .interview,
           interviewContextPrompt.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty
        {
            return "Add an interview description in Prepare Interview before generating an interview."
        }
        if purpose == .interview,
           referencePreparationState.pack != nil,
           !isInterviewEvidenceCurrent
        {
            return "Rebuild the prepared interview evidence after the source or interview-description change."
        }
        if purpose == .interview,
           referencePreparationState.pack?.sourceManifest?.requiresReview == true
        {
            return "Choose the current resume explicitly and rebuild before generating an interview."
        }
        if purpose == .interview,
           let pack = referencePreparationState.pack,
           hasReadyInterviewEvidence
        {
            let label = pack.enabledCardCount == 1 ? "card" : "cards"
            return "Ready to generate from \(pack.enabledCardCount) prepared evidence \(label); the matching scenario is cached for repeatable reruns."
        }
        if purpose == .interview,
           let pack = referencePreparationState.pack,
           isInterviewEvidenceResolved,
           pack.enabledCardCount == 0
        {
            return "Prepared sources contain no candidate evidence to generate an interview from."
        }
        if purpose == .interview,
           (referencePreparationState.resumeSource != nil
                || !referencePreparationState.webSources.isEmpty)
        {
            return "Prepare the configured resume and web sources before generating an interview."
        }
        if
            referenceLibraryState.phase == .ready,
            let references = referenceLibraryState.snapshot,
            !references.documents.isEmpty
        {
            let count = references.documents.count
            let label = count == 1 ? "source" : "sources"
            return "Ready to generate from \(count) indexed \(label); the matching scenario is cached for repeatable reruns."
        }
        switch referenceLibraryState.phase {
        case .notConfigured:
            return "Choose a reference folder; its indexed documents will drive every question and response."
        case .scanning:
            return "Waiting for the reference folder to finish indexing…"
        case .failed:
            return "Fix the reference-folder error before generating the replay."
        case .ready:
            return "The reference folder has no supported readable documents."
        }
    }

    func openCompanionDisplay() {
        guard let url = companionGatewayEndpoint?.loopbackURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyCompanionLANAddress() {
        guard
            let address = companionGatewayEndpoint?.preferredLANURL?.absoluteString
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    func refreshCompanionGatewayEndpoint() {
        guard documentationDemoMode == nil else { return }
        guard let endpoint = companionGatewayEndpoint else { return }
        companionGatewayEndpoint = CompanionGatewayEndpoint(port: endpoint.port)
    }

    func restartCompanionGateway() {
        companionGateway.stop()
        startCompanionGateway()
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
        if let message = liveAssistantLockMessage(for: purpose) {
            present(PUnderclassError.audio(message))
            return
        }
        let apiKey = apiKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            let references = replayReferences(for: purpose),
            !references.documents.isEmpty
        else {
            present(SyntheticInterviewError.referencesUnavailable)
            return
        }
        guard let sourceStateRevision = replaySourceStateRevision(for: purpose)
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
        activateAssistantAnswerMode(for: purpose)
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
        beginInterviewArchive(
            id: runID,
            source: .syntheticInterview,
            startedAt: Date(),
            referenceRevision: references.revision
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
                    scenario.referenceRevision == references.revision,
                    self.replaySourceStateRevision(for: purpose)
                        == sourceStateRevision
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
                    runID: runID,
                    webSearchMode: LiveAssistantWebSearchMode.defaultMode(
                        for: purpose
                    )
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
    func startWebSearchTest() {
        guard !syntheticInterviewState.isActive else { return }
        guard !isListening else {
            present(
                PUnderclassError.audio(
                    "Stop live capture before starting the web-search test."
                )
            )
            return
        }
        guard !isDictationBusy else {
            present(
                PUnderclassError.audio(
                    "Finish Quick Dictation before starting the web-search test."
                )
            )
            return
        }
        if let message = liveAssistantLockMessage(for: .interview) {
            present(PUnderclassError.audio(message))
            return
        }

        let scenario = SyntheticInterviewScenario.webSearchTest()
        let runID = UUID()
        syntheticInterviewRunID = runID
        syntheticInterviewReferences = nil
        capturePurpose = .interview
        activeAssistantAnswerMode = .grounded
        activeAssistantEarlyBridgeEnabled = false
        activeAssistantDeliveryMode = .verified
        prepareCompanionForNewSession()
        localTrack = TrackViewState()
        remoteTrack = TrackViewState()
        refinementState = .idle
        syntheticInterviewState = SyntheticInterviewState(
            purpose: .interview,
            isGenerating: false,
            isRunning: true,
            hasRun: true,
            title: "Starting live web-search test",
            detail: "The interviewer will ask one current-information question; watch Answer Mirror search and return clickable sources.",
            scenarioName: scenario.name,
            referenceRevision: scenario.referenceRevision,
            currentTurn: 0,
            totalTurns: scenario.turns.count
        )
        beginInterviewArchive(
            id: runID,
            source: .syntheticInterview,
            startedAt: Date(),
            referenceRevision: scenario.referenceRevision
        )
        statusMessage = "Live web-search test running"
        publishCompanionSession()
        openCompanionDisplay()

        syntheticInterviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runSyntheticInterview(
                    scenario,
                    runID: runID,
                    webSearchMode: .required
                )
            } catch is CancellationError {
                self.finishSyntheticInterview(
                    runID: runID,
                    title: "Web-search test stopped",
                    detail: "The test stopped before the sourced cue completed."
                )
            } catch {
                self.finishSyntheticInterview(
                    runID: runID,
                    title: "Web-search test failed",
                    detail: error.localizedDescription
                )
                self.present(error)
            }
        }
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
        runID: UUID,
        webSearchMode: LiveAssistantWebSearchMode
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
            let earlyBridgePauseSeconds = Double(
                RealtimeTranscriptionClient
                    .earlyBridgePauseSilenceChunkCount * 20
            ) / 1_000
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
            try await Self.sleep(seconds: earlyBridgePauseSeconds)
            if AssistantEvaluationPolicy.shouldEvaluate(
                speaker: turn.speaker,
                purpose: scenario.purpose
            ) {
                scheduleEarlyInterviewBridge(
                    turnID: turnID,
                    sourceText: turn.text,
                    speaker: turn.speaker,
                    purpose: scenario.purpose,
                    opportunity: .speechPause
                )
            }
            try await Self.sleep(
                seconds: max(
                    0,
                    partialPauseSeconds - earlyBridgePauseSeconds
                )
            )
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
                    observedAt: endedAt,
                    webSearchMode: webSearchMode
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
                purpose: scenario.purpose,
                webSearchMode: webSearchMode
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
            title: webSearchMode == .required
                ? "Web-search test question complete"
                : "\(scenario.purpose.title) replay complete",
            detail: webSearchMode == .required
                ? "The forced hosted search was triggered. Keep Answer Mirror open for the sourced cue and public links."
                : "All \(scenario.turns.count) audible turns generated from \(scenario.referenceDocumentCount) reference documents were replayed."
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
        scheduleEarlyInterviewBridge(
            turnID: id,
            sourceText: text,
            speaker: speaker,
            purpose: syntheticInterviewState.purpose
        )
    }

    @MainActor
    private func finishSyntheticTurn(
        id: String,
        speaker: SpeakerTag,
        text: String,
        startedAt: Date,
        endedAt: Date,
        purpose: CapturePurpose,
        webSearchMode: LiveAssistantWebSearchMode
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
            scheduleEarlyInterviewBridge(
                turnID: id,
                sourceText: text,
                speaker: speaker,
                purpose: purpose,
                opportunity: .finalizedTurn
            )
            scheduleLiveAssistant(
                trigger: .finalizedTurn,
                turnID: id,
                sourceText: text,
                speaker: speaker,
                purpose: purpose,
                observedAt: endedAt,
                webSearchMode: webSearchMode
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
        closeActiveInterviewArchive()
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

    func revealLatestInterviewArchive() {
        guard let latestInterviewArchiveURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            latestInterviewArchiveURL
        ])
    }

    private func makeClient(
        speaker: SpeakerTag,
        purpose: CapturePurpose,
        apiKey: String?,
        context: TranscriptionContext,
        sessionID: UUID
    ) -> any MeetingAudioTranscribing {
        let stateHandler: (SocketState) -> Void = { [weak self] state in
            guard let self, self.activeSessionID == sessionID else { return }
            if speaker == .you {
                self.localTrack.socket = state
            } else {
                self.remoteTrack.socket = state
            }
            if case let .failed(message) = state {
                self.errorMessage = "\(speaker.rawValue) transcription: \(message)"
            }
        }

        guard let apiKey else {
            return LocalTurnTranscriptionClient(
                label: speaker.rawValue,
                onState: stateHandler,
                onTurn: {
                    [weak self] itemID, startedAt, endedAt, pcm16Audio in
                    self?.receiveCapturedTurn(
                        itemID: itemID,
                        liveText: "",
                        startedAt: startedAt,
                        endedAt: endedAt,
                        pcm16Audio: pcm16Audio,
                        speaker: speaker,
                        purpose: purpose,
                        sessionID: sessionID
                    )
                }
            )
        }

        return RealtimeTranscriptionClient(
            apiKey: apiKey,
            context: context,
            label: speaker.rawValue,
            onState: stateHandler,
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
                self.scheduleEarlyInterviewBridge(
                    turnID: "\(speaker.rawValue)-\(itemID)",
                    sourceText: text,
                    speaker: speaker,
                    purpose: purpose
                )
            },
            onFinal: { [weak self] itemID, text, startedAt, endedAt, pcm16Audio in
                self?.receiveCapturedTurn(
                    itemID: itemID,
                    liveText: text,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    pcm16Audio: pcm16Audio,
                    speaker: speaker,
                    purpose: purpose,
                    sessionID: sessionID
                )
            },
            onEarlyBridgePause: { [weak self] _ in
                guard
                    let self,
                    self.activeSessionID == sessionID,
                    EarlyInterviewBridgeEvaluationPolicy.shouldEvaluate(
                        speaker: speaker,
                        purpose: purpose,
                        answerMode: self.activeAssistantAnswerMode,
                        isEnabled: self.activeAssistantEarlyBridgeEnabled
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
                self.scheduleEarlyInterviewBridge(
                    turnID: "\(speaker.rawValue)-\(itemID)",
                    sourceText: text,
                    speaker: speaker,
                    purpose: purpose,
                    opportunity: .speechPause
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

    private func receiveCapturedTurn(
        itemID: String,
        liveText: String,
        startedAt: Date,
        endedAt: Date?,
        pcm16Audio: Data,
        speaker: SpeakerTag,
        purpose: CapturePurpose,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID else { return }
        let normalizedLiveText = liveText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedLiveText.isEmpty || !pcm16Audio.isEmpty else { return }

        let transcriptID = "\(speaker.rawValue)-\(itemID)"
        let refinement: TranscriptRefinementState = pcm16Audio.isEmpty
            ? .liveOnly("No buffered audio was available for the final pass.")
            : .refining
        let turn = TranscriptTurn(
            id: transcriptID,
            purpose: purpose,
            speaker: speaker,
            startedAt: startedAt,
            endedAt: endedAt,
            liveText: normalizedLiveText,
            text: normalizedLiveText,
            refinement: refinement
        )
        transcript.removeAll { $0.id == transcriptID }
        transcript.append(turn)
        transcript.sort {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt < $1.startedAt
        }

        // Local capture has no provisional text. Its first companion event is
        // published when Whisper or Parakeet returns the completed transcript.
        if !normalizedLiveText.isEmpty {
            publishCompanionFinal(turn)
            if AssistantEvaluationPolicy.shouldEvaluate(
                speaker: speaker,
                purpose: purpose
            ) {
                scheduleEarlyInterviewBridge(
                    turnID: transcriptID,
                    sourceText: normalizedLiveText,
                    speaker: speaker,
                    purpose: purpose,
                    opportunity: .finalizedTurn
                )
                scheduleLiveAssistant(
                    trigger: .finalizedTurn,
                    turnID: transcriptID,
                    sourceText: normalizedLiveText,
                    speaker: speaker,
                    purpose: purpose,
                    observedAt: endedAt ?? Date()
                )
            }
        }

        guard
            !pcm16Audio.isEmpty,
            let refinementClient = refinementClients[speaker],
            let activeContext
        else {
            return
        }
        let recentTranscript = transcript
            .filter {
                $0.purpose == purpose
                    && $0.id != transcriptID
                    && !$0.text.isEmpty
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
            let lostLocalTranscript = transcript.contains { turn in
                guard turn.liveText.isEmpty else { return false }
                guard case .refining = turn.refinement else { return false }
                return speaker == nil || turn.speaker == speaker
            }
            markRefiningTurnsLiveOnly(message, speaker: speaker)
            let track = speaker.map { "\($0.rawValue) " } ?? ""
            errorMessage = lostLocalTranscript
                ? "\(track)local transcription: \(message)"
                : "\(track)final transcription: \(message) Live transcription continues."
        }

        if
            !isListening,
            refinementStates[.you] == .idle,
            refinementStates[.other] == .idle
        {
            statusMessage = activeCaptureUsesHostedTranscription
                ? "Stopped — transcript refinement complete"
                : "Stopped — local transcript complete"
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
        let hadLiveText = !transcript[index].liveText.isEmpty
        transcript[index].text = text
        transcript[index].refinement = .refined
        if hadLiveText {
            publishCompanionRevision(transcript[index])
        } else {
            let completedTurn = transcript[index]
            publishCompanionFinal(completedTurn)
            if
                isLiveAssistantAvailable,
                AssistantEvaluationPolicy.shouldEvaluate(
                    speaker: completedTurn.speaker,
                    purpose: purpose
                )
            {
                scheduleLiveAssistant(
                    trigger: .finalizedTurn,
                    turnID: transcriptID,
                    sourceText: text,
                    speaker: completedTurn.speaker,
                    purpose: purpose,
                    observedAt: Date()
                )
            }
        }
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
        transcript[index].refinement = transcript[index].liveText.isEmpty
            ? .failed(message)
            : .liveOnly(message)
    }

    private func markRefiningTurnsLiveOnly(
        _ message: String,
        speaker: SpeakerTag? = nil
    ) {
        for index in transcript.indices {
            guard case .refining = transcript[index].refinement else { continue }
            if let speaker, transcript[index].speaker != speaker { continue }
            transcript[index].refinement = transcript[index].liveText.isEmpty
                ? .failed(message)
                : .liveOnly(message)
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
        let attemptID = UUID()
        companionGatewayAttemptID = attemptID
        companionGatewayEndpoint = nil
        companionGatewayError = nil
        companionGatewayStatus = "Starting companion display server…"
        companionGateway.start(
            onReady: { [weak self] endpoint in
                DispatchQueue.main.async {
                    guard self?.companionGatewayAttemptID == attemptID else {
                        return
                    }
                    self?.companionGatewayEndpoint = endpoint
                    self?.companionGatewayError = nil
                    self?.companionGatewayStatus =
                        "Companion display server running"
                }
            },
            onFailure: { [weak self] message in
                DispatchQueue.main.async {
                    guard self?.companionGatewayAttemptID == attemptID else {
                        return
                    }
                    self?.companionGatewayEndpoint = nil
                    self?.companionGatewayError = message
                    self?.companionGatewayStatus =
                        "Companion display server unavailable"
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
        closeActiveInterviewArchive()
        cancelAssistantGenerations()
        assistantBridgeTask?.cancel()
        assistantBridgeTask = nil
        assistantBridgeRequestID = nil
        assistantBridgeTurnID = nil
        assistantBridgeLatestText = ""
        assistantBridgeFormingAttemptCount = 0
        assistantBridgePauseAttemptCount = 0
        assistantBridgeFinalAttempted = false
        activeAssistantBridge = nil
        recentAssistantBridgeTexts = []
        latestRehearsalStory = nil
        enqueueCompanionUpdate { hub in
            await hub.clearTranscript()
        }
    }

    private func activateAssistantAnswerMode(for purpose: CapturePurpose) {
        activeAssistantAnswerMode = purpose == .interview
            ? assistantAnswerMode
            : .grounded
        activeAssistantEarlyBridgeEnabled = purpose == .interview
            && assistantAnswerMode == .plausibleRehearsal
            && assistantEarlyBridgeEnabled
        activeAssistantDeliveryMode = purpose == .interview
            && assistantAnswerMode == .grounded
            && liveAssistantProvider == .openAI
            ? assistantDeliveryMode
            : .verified
        activePreparedReferencePack = purpose == .interview
            && hasReadyInterviewEvidence
            ? referencePreparationState.pack
            : nil
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
        let answerMode = purpose == .interview
            ? activeAssistantAnswerMode
            : .grounded
        let earlyBridgeEnabled = activeAssistantEarlyBridgeEnabled
        let deliveryMode = purpose == .interview
            ? activeAssistantDeliveryMode
            : .verified
        let assistantAvailable = isSyntheticSession
            || isLiveAssistantAvailable
        enqueueCompanionUpdate { hub in
            await hub.updateSession(
                isListening: listening,
                status: status,
                purpose: purpose,
                source: source,
                title: title,
                isPreparingSyntheticInterview: isPreparingSyntheticInterview,
                answerMode: answerMode,
                earlyBridgeEnabled: earlyBridgeEnabled,
                deliveryMode: deliveryMode,
                assistantAvailable: assistantAvailable
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
        recordInterviewTranscriptTurn(projected)
        enqueueCompanionUpdate { hub in
            await hub.appendFinal(projected)
        }
    }

    private func publishCompanionRevision(_ turn: TranscriptTurn) {
        let projected = companionTurn(turn)
        recordInterviewTranscriptTurn(projected)
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
            assistantModelCalls: apiExpenses.assistantModelCalls,
            assistantGroundingRepairAttempts:
                apiExpenses.assistantGroundingRepairAttempts,
            assistantGroundingRepairSuccesses:
                apiExpenses.assistantGroundingRepairSuccesses,
            assistantGroundingRepairMilliseconds:
                apiExpenses.assistantGroundingRepairMilliseconds,
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

    private func scheduleEarlyInterviewBridge(
        turnID: String,
        sourceText: String,
        speaker: SpeakerTag,
        purpose: CapturePurpose,
        opportunity: EarlyInterviewBridgeEvaluationPolicy.Opportunity =
            .formingTranscript
    ) {
        guard EarlyInterviewBridgeEvaluationPolicy.shouldEvaluate(
            speaker: speaker,
            purpose: purpose,
            answerMode: activeAssistantAnswerMode,
            isEnabled: activeAssistantEarlyBridgeEnabled
        ) else {
            return
        }
        let normalizedText = sourceText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedText.isEmpty else { return }

        if assistantBridgeTurnID != turnID {
            cancelAssistantGenerations()
            assistantBridgeTask?.cancel()
            assistantBridgeTask = nil
            assistantBridgeRequestID = nil
            assistantBridgeTurnID = turnID
            assistantBridgeLatestText = ""
            assistantBridgeFormingAttemptCount = 0
            assistantBridgePauseAttemptCount = 0
            assistantBridgeFinalAttempted = false
            activeAssistantBridge = nil
            enqueueCompanionUpdate { hub in
                await hub.assistantSupersededForNewTurn()
            }
        }
        assistantBridgeLatestText = normalizedText

        guard activeAssistantBridge == nil else { return }

        let isLocalOnly = privacyLockEnabled
        let apiKey = capability.isAvailable(.answerMirror)
            ? apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard !isLocalOnly, !apiKey.isEmpty else { return }

        if opportunity != .formingTranscript, assistantBridgeTask != nil {
            assistantBridgeTask?.cancel()
            assistantBridgeTask = nil
            assistantBridgeRequestID = nil
        }
        guard assistantBridgeTask == nil else { return }

        let attempt: Int
        switch opportunity {
        case .formingTranscript:
            guard
                assistantBridgeFormingAttemptCount
                    < EarlyInterviewBridgeEvaluationPolicy
                        .maximumFormingTranscriptAttemptsPerTurn
            else {
                return
            }
            attempt = assistantBridgeFormingAttemptCount
            assistantBridgeFormingAttemptCount += 1
        case .speechPause:
            guard
                assistantBridgePauseAttemptCount
                    < EarlyInterviewBridgeEvaluationPolicy
                        .maximumSpeechPauseAttemptsPerTurn
            else {
                return
            }
            attempt = assistantBridgePauseAttemptCount
            assistantBridgePauseAttemptCount += 1
        case .finalizedTurn:
            guard !assistantBridgeFinalAttempted else { return }
            assistantBridgeFinalAttempted = true
            attempt = 0
        }

        let requestID = UUID()
        assistantBridgeRequestID = requestID
        let delayMilliseconds =
            EarlyInterviewBridgeEvaluationPolicy.delayMilliseconds(
                for: opportunity,
                attempt: attempt
            )
        let recentTranscript = transcript
            .filter { $0.purpose == purpose && $0.id != turnID }
            .suffix(4)
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        let recentBridges = Array(recentAssistantBridgeTexts.suffix(4))
        let sessionContext = contextPrompt(for: purpose).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let pendingCompanionUpdates = companionUpdateTail
        let hub = companionGateway.hub
        let client = earlyInterviewBridgeClient
        let controller = WeakMeetingController(self)

        Self.liveAssistantLogger.notice(
            "assistant_bridge_scheduled turn_id=\(turnID, privacy: .public) opportunity=\(opportunity.rawValue, privacy: .public) attempt=\(attempt + 1, privacy: .public) delay_ms=\(delayMilliseconds, privacy: .public) model=\(EarlyInterviewBridgeClient.model, privacy: .public) service_tier=\(EarlyInterviewBridgeClient.serviceTier, privacy: .public)"
        )

        assistantBridgeTask = Task {
            do {
                if delayMilliseconds > 0 {
                    try await Task.sleep(
                        for: .milliseconds(delayMilliseconds)
                    )
                }
                guard !Task.isCancelled else { return }
                await pendingCompanionUpdates?.value
                guard !(await hub.suggestionsPaused()) else {
                    _ = await MainActor.run {
                        controller.value?.completeAssistantBridgeRequest(
                            requestID: requestID,
                            attemptedText: nil,
                            retryIfTextChanged: false,
                            opportunity: opportunity
                        )
                    }
                    return
                }
                let latestTextForRequest = await MainActor.run {
                    controller.value?.assistantBridgeSourceText(
                        requestID: requestID,
                        turnID: turnID
                    )
                }
                guard let latestText = latestTextForRequest else {
                    return
                }

                let generation = try await client.generate(
                    apiKey: apiKey,
                    currentPartial: latestText,
                    recentTranscript: recentTranscript,
                    recentBridges: recentBridges,
                    sessionContext: sessionContext,
                    opportunity: opportunity
                )
                await MainActor.run {
                    controller.value?.recordAssistantUsage(generation.usage)
                }
                guard !Task.isCancelled else { return }
                guard !(await hub.suggestionsPaused()) else {
                    _ = await MainActor.run {
                        controller.value?.completeAssistantBridgeRequest(
                            requestID: requestID,
                            attemptedText: latestText,
                            retryIfTextChanged: false,
                            opportunity: opportunity
                        )
                    }
                    return
                }

                if let text = generation.bridge {
                    let bridge = CompanionAssistantBridge(
                        id: UUID().uuidString.lowercased(),
                        topicID: turnID,
                        sourceText: latestText,
                        text: text,
                        generatedAt: Date(),
                        generationMilliseconds:
                            generation.generationMilliseconds
                    )
                    let accepted = await MainActor.run {
                        controller.value?.acceptAssistantBridge(
                            bridge,
                            requestID: requestID
                        ) ?? false
                    }
                    guard accepted else { return }
                    await hub.assistantBridged(bridge)
                    Self.liveAssistantLogger.notice(
                        "assistant_bridge_completed turn_id=\(turnID, privacy: .public) opportunity=\(opportunity.rawValue, privacy: .public) attempt=\(attempt + 1, privacy: .public) outcome=bridge model=\(EarlyInterviewBridgeClient.model, privacy: .public) generation_ms=\(generation.generationMilliseconds, privacy: .public)"
                    )
                    return
                }

                let retryText = await MainActor.run {
                    controller.value?.completeAssistantBridgeRequest(
                        requestID: requestID,
                        attemptedText: latestText,
                        retryIfTextChanged:
                            opportunity == .formingTranscript,
                        opportunity: opportunity
                    )
                }
                Self.liveAssistantLogger.notice(
                    "assistant_bridge_completed turn_id=\(turnID, privacy: .public) opportunity=\(opportunity.rawValue, privacy: .public) attempt=\(attempt + 1, privacy: .public) outcome=not_ready model=\(EarlyInterviewBridgeClient.model, privacy: .public) generation_ms=\(generation.generationMilliseconds, privacy: .public)"
                )
                if let retryText {
                    await MainActor.run {
                        controller.value?.scheduleEarlyInterviewBridge(
                            turnID: turnID,
                            sourceText: retryText,
                            speaker: speaker,
                            purpose: purpose,
                            opportunity: .formingTranscript
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                _ = await MainActor.run {
                    controller.value?.completeAssistantBridgeRequest(
                        requestID: requestID,
                        attemptedText: nil,
                        retryIfTextChanged: false,
                        opportunity: opportunity
                    )
                }
                let errorType = String(describing: type(of: error))
                Self.liveAssistantLogger.error(
                    "assistant_bridge_failed turn_id=\(turnID, privacy: .public) opportunity=\(opportunity.rawValue, privacy: .public) attempt=\(attempt + 1, privacy: .public) error_type=\(errorType, privacy: .public)"
                )
            }
        }
    }

    private func assistantBridgeSourceText(
        requestID: UUID,
        turnID: String
    ) -> String? {
        guard
            assistantBridgeRequestID == requestID,
            assistantBridgeTurnID == turnID,
            activeAssistantBridge == nil
        else {
            return nil
        }
        return assistantBridgeLatestText
    }

    @discardableResult
    private func completeAssistantBridgeRequest(
        requestID: UUID,
        attemptedText: String?,
        retryIfTextChanged: Bool,
        opportunity: EarlyInterviewBridgeEvaluationPolicy.Opportunity
    ) -> String? {
        guard assistantBridgeRequestID == requestID else { return nil }
        assistantBridgeTask = nil
        assistantBridgeRequestID = nil
        guard
            retryIfTextChanged,
            opportunity == .formingTranscript,
            activeAssistantBridge == nil,
            assistantBridgeFormingAttemptCount
                < EarlyInterviewBridgeEvaluationPolicy
                    .maximumFormingTranscriptAttemptsPerTurn,
            let attemptedText,
            assistantBridgeLatestText != attemptedText
        else {
            return nil
        }
        return assistantBridgeLatestText
    }

    private func acceptAssistantBridge(
        _ bridge: CompanionAssistantBridge,
        requestID: UUID
    ) -> Bool {
        guard
            assistantBridgeRequestID == requestID,
            assistantBridgeTurnID == bridge.topicID,
            activeAssistantEarlyBridgeEnabled
        else {
            return false
        }
        assistantBridgeTask = nil
        assistantBridgeRequestID = nil
        activeAssistantBridge = bridge
        recentAssistantBridgeTexts.append(bridge.text)
        if recentAssistantBridgeTexts.count > 4 {
            recentAssistantBridgeTexts.removeFirst(
                recentAssistantBridgeTexts.count - 4
            )
        }
        recordInterviewBridge(bridge)
        return true
    }

    private func retireAssistantBridge(for turnID: String) {
        guard assistantBridgeTurnID == turnID else { return }
        assistantBridgeTask?.cancel()
        assistantBridgeTask = nil
        assistantBridgeRequestID = nil
        activeAssistantBridge = nil
    }

    private func scheduleLiveAssistant(
        trigger: CompanionAssistantTrigger,
        turnID: String,
        sourceText: String,
        speaker: SpeakerTag,
        purpose: CapturePurpose,
        observedAt: Date = Date(),
        webSearchMode: LiveAssistantWebSearchMode? = nil
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
        let answerMode = purpose == .interview
            ? activeAssistantAnswerMode
            : .grounded
        let deliveryMode = purpose == .interview
            ? activeAssistantDeliveryMode
            : .verified
        let client = selectedLiveAssistantClient
        let resolvedWebSearchMode = webSearchMode
            ?? LiveAssistantWebSearchMode.defaultMode(for: purpose)
        let resolvedDeliveryMode = LiveAssistantClient.resolvedDeliveryMode(
            requested: deliveryMode,
            supportsInstantText: client.supportsInstantText,
            purpose: purpose,
            trigger: trigger,
            webSearchMode: resolvedWebSearchMode,
            answerMode: answerMode
        )
        let isSameTurn = assistantGenerationTurnID == turnID
        if
            trigger == .finalizedTurn,
            isSameTurn,
            assistantGenerationArbitration.hasPublishedSuggestion
        {
            Self.liveAssistantLogger.debug(
                "assistant_check_coalesced trigger=\(trigger.rawValue, privacy: .public) turn_id=\(turnID, privacy: .public) reason=suggestion_already_available"
            )
            return
        }

        let startsFinalizedTurnHedge = AssistantGenerationHedgePolicy
            .shouldStartFinalizedTurnHedge(
                trigger: trigger,
                resolvedDeliveryMode: resolvedDeliveryMode,
                isSameTurn: isSameTurn,
                primaryTrigger: assistantGenerationPrimaryTrigger,
                arbitration: assistantGenerationArbitration
            )
        let repeatsFinalAfterNoCue = trigger == .finalizedTurn
            && isSameTurn
            && !assistantGenerationArbitration.hasActiveRequest
            && !assistantGenerationArbitration.hasPublishedSuggestion
        if
            !startsFinalizedTurnHedge,
            assistantGenerationIdentity == identity,
            !repeatsFinalAfterNoCue
        {
            Self.liveAssistantLogger.debug(
                "assistant_check_coalesced trigger=\(trigger.rawValue, privacy: .public) turn_id=\(turnID, privacy: .public) reason=duplicate_identity"
            )
            return
        }

        let requestID = UUID()
        if startsFinalizedTurnHedge {
            guard assistantGenerationArbitration.startHedge(requestID) else {
                Self.liveAssistantLogger.debug(
                    "assistant_check_coalesced trigger=\(trigger.rawValue, privacy: .public) turn_id=\(turnID, privacy: .public) reason=hedge_already_active"
                )
                return
            }
            assistantGenerationIdentity = identity
        } else {
            let requestIDsToCancel = assistantGenerationArbitration
                .startPrimary(requestID)
            cancelAssistantGenerationTasks(requestIDsToCancel)
            assistantGenerationIdentity = identity
            assistantGenerationTurnID = turnID
            assistantGenerationPrimaryTrigger = trigger
        }
        // The assistant is a hosted model; local-only mode withholds the
        // selected provider's key rather than sending the transcript off-Mac.
        let isLocalOnly = privacyLockEnabled
        let apiKey = isLocalOnly ? "" : liveAssistantAPIKey
        let assistantProvider = liveAssistantProvider
        let assistantAPIKeyName = liveAssistantAPIKeyName
        let usesSyntheticReferences = syntheticInterviewState.isRunning
        let references = assistantReferences(
            usesSyntheticReferences: usesSyntheticReferences,
            purpose: purpose,
            question: normalizedText
        )
        let referenceStateRevision = assistantReferenceStateRevision(
            usesSyntheticReferences: usesSyntheticReferences,
            purpose: purpose
        )
        let recentTranscript = transcript
            .filter { $0.purpose == purpose && $0.id != turnID }
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
        let previousRehearsalStory = answerMode == .plausibleRehearsal
            ? latestRehearsalStory
            : nil
        let pendingCompanionUpdates = companionUpdateTail
        let hub = companionGateway.hub
        let controller = WeakMeetingController(self)
        let delayMilliseconds = AssistantEvaluationPolicy.delayMilliseconds(
            for: trigger
        )
        let speechPauseMilliseconds = trigger == .partialTranscript
            ? AssistantEvaluationPolicy.partialSpeechPauseMilliseconds
            : 0

        Self.liveAssistantLogger.notice(
            "assistant_check_scheduled trigger=\(trigger.rawValue, privacy: .public) trigger_speaker=\(speaker.rawValue, privacy: .public) answer_mode=\(answerMode.rawValue, privacy: .public) speech_pause_ms=\(speechPauseMilliseconds, privacy: .public) schedule_delay_ms=\(delayMilliseconds, privacy: .public) hedge=\(startsFinalizedTurnHedge, privacy: .public)"
        )

        let generationTask = Task {
            defer {
                DispatchQueue.main.async {
                    controller.value?.assistantGenerationRequestEnded(
                        requestID
                    )
                }
            }
            var evaluationSequence: Int?
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
                            : "Add \(assistantAPIKeyName) to turn on \(purpose.assistantTitle).",
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
                    controller.value?.assistantReferenceStateRevision(
                        usesSyntheticReferences: usesSyntheticReferences,
                        purpose: purpose
                    )
                }
                guard currentRevision == referenceStateRevision else {
                    Self.liveAssistantLogger.notice(
                        "assistant_check_skipped reason=reference_revision_changed"
                    )
                    return
                }

                let basedOnSequence = await hub.currentWatermark()
                evaluationSequence = basedOnSequence
                let evaluationStartedAt = Date()
                let usefulnessDeadline: ContinuousClock.Instant?
                if purpose == .interview {
                    let remainingMilliseconds =
                        LiveAssistantUsefulnessPolicy
                            .remainingInterviewLatencyMilliseconds(
                                observedAt: observedAt,
                                now: evaluationStartedAt
                            )
                    guard remainingMilliseconds > 0 else {
                        Self.liveAssistantLogger.notice(
                            "assistant_inference_skipped sequence=\(basedOnSequence, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) outcome=\(CompanionInferenceOutcome.timedOut.rawValue, privacy: .public) reason=usefulness_deadline_elapsed"
                        )
                        let shouldPublish = await MainActor.run {
                            controller.value?
                                .finishAssistantGenerationWithoutSuggestion(
                                    requestID: requestID
                                ) == true
                        }
                        guard shouldPublish else { return }
                        await hub.assistantFinishedWithoutSuggestion(
                            basedOnSequence: basedOnSequence,
                            trigger: trigger,
                            triggeredAt: observedAt,
                            completedAt: evaluationStartedAt,
                            outcome: .timedOut,
                            preserveBridge: true
                        )
                        return
                    }
                    usefulnessDeadline = ContinuousClock.now
                        + .milliseconds(remainingMilliseconds)
                } else {
                    usefulnessDeadline = nil
                }
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
                    basedOnSequence: basedOnSequence,
                    trigger: trigger,
                    webSearchMode: webSearchMode,
                    answerMode: answerMode,
                    previousRehearsalStory: previousRehearsalStory,
                    usefulnessDeadline: usefulnessDeadline,
                    deliveryMode: deliveryMode,
                    onInstantText: { update in
                        guard !Task.isCancelled else { return }
                        let isActiveRequest = await MainActor.run {
                            controller.value?
                                .isAssistantGenerationRequestActive(
                                    requestID
                                ) == true
                        }
                        guard isActiveRequest else { return }
                        guard !(await hub.suggestionsPaused()) else { return }
                        _ = await hub.assistantDrafted(
                            CompanionAssistantDraft(
                                id: "instant-\(turnID)",
                                basedOnSequence: basedOnSequence,
                                topicID: turnID,
                                question: normalizedText,
                                text: update.text,
                                generatedAt: Date(),
                                generationMilliseconds:
                                    update.elapsedMilliseconds,
                                firstRenderableTextMilliseconds:
                                    update.firstRenderableTextMilliseconds,
                                trigger: trigger
                            )
                        )
                    }
                )
                await MainActor.run {
                    controller.value?.recordAssistantUsage(generation.usage)
                }
                let completedAt = Date()
                if
                    purpose == .interview,
                    !LiveAssistantUsefulnessPolicy.isInterviewCueUseful(
                        observedAt: observedAt,
                        completedAt: completedAt
                    )
                {
                    Self.liveAssistantLogger.notice(
                        "assistant_inference_completed sequence=\(basedOnSequence, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) outcome=\(CompanionInferenceOutcome.timedOut.rawValue, privacy: .public) total_ms=\(Self.milliseconds(from: observedAt, to: completedAt), privacy: .public) reason=usefulness_deadline_elapsed_after_response"
                    )
                    let shouldPublish = await MainActor.run {
                        controller.value?
                            .finishAssistantGenerationWithoutSuggestion(
                                requestID: requestID
                            ) == true
                    }
                    guard shouldPublish else { return }
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt,
                        outcome: .timedOut,
                        preserveBridge: true
                    )
                    return
                }
                let totalLatencyMilliseconds = Self.milliseconds(
                    from: observedAt,
                    to: completedAt
                )
                let grounding = generation.suggestion?.grounding.rawValue
                    ?? "none"
                Self.liveAssistantLogger.notice(
                    "assistant_inference_completed sequence=\(basedOnSequence, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) outcome=\(generation.outcome.rawValue, privacy: .public) grounding=\(grounding, privacy: .public) answer_mode=\(answerMode.rawValue, privacy: .public) delivery_mode=\(generation.deliveryMode.rawValue, privacy: .public) provider=\(assistantProvider.rawValue, privacy: .public) model=\(client.configuredModel, privacy: .public) reasoning_effort=\(client.configuredReasoningEffort.rawValue, privacy: .public) model_calls=\(generation.usage.requestCount, privacy: .public) repair_attempts=\(generation.usage.groundingRepairAttempts, privacy: .public) repair_ms=\(generation.usage.groundingRepairMilliseconds, privacy: .public) response_headers_ms=\(generation.latencyMilestones.responseHeadersMilliseconds ?? -1, privacy: .public) first_event_ms=\(generation.latencyMilestones.firstEventMilliseconds ?? -1, privacy: .public) first_text_ms=\(generation.latencyMilestones.firstTextDeltaMilliseconds ?? -1, privacy: .public) first_renderable_ms=\(generation.latencyMilestones.firstRenderableTextMilliseconds ?? -1, privacy: .public) validated_cue_ms=\(generation.latencyMilestones.validatedCueMilliseconds, privacy: .public) generation_ms=\(generation.generationMilliseconds, privacy: .public) total_ms=\(totalLatencyMilliseconds, privacy: .public)"
                )
                guard !Task.isCancelled else { return }
                let isCurrentRevision = await MainActor.run {
                    controller.value?.assistantReferenceStateRevision(
                        usesSyntheticReferences: usesSyntheticReferences,
                        purpose: purpose
                    ) == referenceStateRevision
                }
                guard isCurrentRevision else {
                    let shouldPublish = await MainActor.run {
                        controller.value?
                            .finishAssistantGenerationWithoutSuggestion(
                                requestID: requestID
                            ) == true
                    }
                    guard shouldPublish else { return }
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt,
                        outcome: .cancelled
                    )
                    return
                }
                guard !(await hub.suggestionsPaused()) else {
                    let shouldPublish = await MainActor.run {
                        controller.value?
                            .finishAssistantGenerationWithoutSuggestion(
                                requestID: requestID
                            ) == true
                    }
                    guard shouldPublish else { return }
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt,
                        outcome: .cancelled
                    )
                    return
                }
                if var suggestion = generation.suggestion {
                    suggestion.trigger = trigger
                    suggestion.triggeredAt = observedAt
                    suggestion.totalLatencyMilliseconds =
                        totalLatencyMilliseconds
                    suggestion.topicID = turnID
                    suggestion.inferenceOutcome = generation.outcome
                    let completedSuggestion = suggestion
                    let accepted = await MainActor.run {
                        guard
                            controller.value?
                                .claimAssistantGenerationSuggestion(
                                    requestID: requestID
                                ) == true
                        else {
                            return false
                        }
                        controller.value?.retireAssistantBridge(for: turnID)
                        controller.value?.recordAssistantSuggestion(
                            completedSuggestion
                        )
                        return true
                    }
                    guard accepted else { return }
                    await hub.assistantSuggested(
                        completedSuggestion,
                        outcome: generation.outcome
                    )
                } else {
                    let shouldPublish = await MainActor.run {
                        let shouldPublish = controller.value?
                            .finishAssistantGenerationWithoutSuggestion(
                                requestID: requestID
                            ) == true
                        if shouldPublish, trigger == .finalizedTurn {
                            controller.value?.retireAssistantBridge(for: turnID)
                        }
                        return shouldPublish
                    }
                    guard shouldPublish else { return }
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt,
                        outcome: generation.outcome
                    )
                }
            } catch is CancellationError {
                let shouldPublish = await MainActor.run {
                    controller.value?
                        .finishAssistantGenerationWithoutSuggestion(
                            requestID: requestID
                        ) == true
                }
                if shouldPublish, let evaluationSequence {
                    _ = await hub.assistantCancelled(
                        basedOnSequence: evaluationSequence
                    )
                }
                Self.liveAssistantLogger.debug(
                    "assistant_check_cancelled trigger=\(trigger.rawValue, privacy: .public) outcome=\(CompanionInferenceOutcome.cancelled.rawValue, privacy: .public)"
                )
                return
            } catch {
                guard !Task.isCancelled else { return }
                let liveError = (error as? LiveAssistantFailure)?.cause
                    ?? error as? LiveAssistantError
                await MainActor.run {
                    if let failure = error as? LiveAssistantFailure {
                        controller.value?.recordAssistantUsage(failure.usage)
                    }
                }
                if liveError == .usefulnessDeadlineExceeded {
                    let completedAt = Date()
                    let basedOnSequence: Int
                    if let evaluationSequence {
                        basedOnSequence = evaluationSequence
                    } else {
                        basedOnSequence = await hub.currentWatermark()
                    }
                    Self.liveAssistantLogger.notice(
                        "assistant_inference_completed sequence=\(basedOnSequence, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) outcome=\(CompanionInferenceOutcome.timedOut.rawValue, privacy: .public) total_ms=\(Self.milliseconds(from: observedAt, to: completedAt), privacy: .public)"
                    )
                    let shouldPublish = await MainActor.run {
                        controller.value?
                            .finishAssistantGenerationWithoutSuggestion(
                                requestID: requestID
                            ) == true
                    }
                    guard shouldPublish else { return }
                    await hub.assistantFinishedWithoutSuggestion(
                        basedOnSequence: basedOnSequence,
                        trigger: trigger,
                        triggeredAt: observedAt,
                        completedAt: completedAt,
                        outcome: .timedOut,
                        preserveBridge: true
                    )
                    return
                }
                let outcome: CompanionInferenceOutcome =
                    liveError == .invalidGrounding
                        ? .invalidGrounding
                        : .failed
                let errorType = String(describing: type(of: error))
                Self.liveAssistantLogger.error(
                    "assistant_inference_failed trigger=\(trigger.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) error_type=\(errorType, privacy: .public)"
                )
                let shouldPublish = await MainActor.run {
                    controller.value?
                        .finishAssistantGenerationWithoutSuggestion(
                            requestID: requestID,
                            allowRetry: true
                        ) == true
                }
                guard shouldPublish else { return }
                await hub.assistantFailed(
                    error.localizedDescription,
                    outcome: outcome
                )
            }
        }
        assistantGenerationTasks[requestID] = generationTask
    }

    private func assistantReferenceStateRevision(
        usesSyntheticReferences: Bool,
        purpose: CapturePurpose
    ) -> String? {
        if usesSyntheticReferences {
            return syntheticInterviewReferences?.revision
        }
        guard purpose == .interview else {
            return referenceLibraryState.snapshot?.revision
        }
        if let activePreparedReferencePack {
            return "prepared:\(activePreparedReferencePack.revision)"
        }
        if let pack = referencePreparationState.pack,
           hasReadyInterviewEvidence
        {
            return "prepared:\(pack.revision)"
        }
        return nil
    }

    private func assistantReferences(
        usesSyntheticReferences: Bool,
        purpose: CapturePurpose,
        question: String
    ) -> ReferenceLibrarySnapshot? {
        if usesSyntheticReferences {
            return syntheticInterviewReferences
        }
        guard purpose == .interview else {
            return referenceLibraryState.snapshot
        }
        if let activePreparedReferencePack {
            return activePreparedReferencePack.snapshot(
                for: question,
                folderURL: referenceLibraryState.snapshot?.folderURL
            )
        }
        if let pack = referencePreparationState.pack,
           hasReadyInterviewEvidence
        {
            return pack.snapshot(
                for: question,
                folderURL: referenceLibraryState.snapshot?.folderURL
            )
        }
        return nil
    }

    private func recordAssistantSuggestion(
        _ suggestion: CompanionAssistantSuggestion
    ) {
        recordInterviewSuggestion(suggestion)
        if let story = AssistantRehearsalStoryContext(suggestion: suggestion) {
            latestRehearsalStory = story
        }
    }

    private func beginInterviewArchive(
        id: UUID,
        source: CompanionSessionSource,
        startedAt: Date,
        referenceRevision: String?
    ) {
        guard capturePurpose == .interview else { return }
        activeInterviewArchive = InterviewSessionArchive(
            id: id,
            source: source,
            startedAt: startedAt,
            answerMode: activeAssistantAnswerMode,
            earlyBridgeEnabled: activeAssistantEarlyBridgeEnabled,
            sessionContext: contextPrompt(for: .interview),
            referenceRevision: referenceRevision
        )
        interviewArchiveSaveErrorShown = false
        persistActiveInterviewArchive()
    }

    private func recordInterviewTranscriptTurn(
        _ turn: CompanionTranscriptTurn
    ) {
        guard activeInterviewArchive != nil else { return }
        activeInterviewArchive?.upsertTranscriptTurn(turn)
        persistActiveInterviewArchive()
    }

    private func recordInterviewBridge(_ bridge: CompanionAssistantBridge) {
        guard activeInterviewArchive != nil else { return }
        activeInterviewArchive?.appendBridge(bridge)
        persistActiveInterviewArchive()
    }

    private func recordInterviewSuggestion(
        _ suggestion: CompanionAssistantSuggestion
    ) {
        guard activeInterviewArchive != nil else { return }
        activeInterviewArchive?.appendSuggestion(suggestion)
        persistActiveInterviewArchive()
    }

    private func finishActiveInterviewArchive(at date: Date = Date()) {
        guard activeInterviewArchive != nil else { return }
        activeInterviewArchive?.finish(at: date)
        persistActiveInterviewArchive()
    }

    private func closeActiveInterviewArchive(at date: Date = Date()) {
        finishActiveInterviewArchive(at: date)
        activeInterviewArchive = nil
    }

    private func persistActiveInterviewArchive() {
        guard let activeInterviewArchive else { return }
        do {
            latestInterviewArchiveURL = try interviewSessionArchiveStore.save(
                activeInterviewArchive
            )
            interviewArchiveSaveErrorShown = false
        } catch {
            Self.liveAssistantLogger.error(
                "interview_archive_save_failed error=\(error.localizedDescription, privacy: .public)"
            )
            guard !interviewArchiveSaveErrorShown else { return }
            interviewArchiveSaveErrorShown = true
            errorMessage =
                "The interview session archive could not be saved: \(error.localizedDescription)"
        }
    }

    private func cancelAssistantGenerations() {
        _ = assistantGenerationArbitration.reset()
        let tasks = assistantGenerationTasks.values
        assistantGenerationTasks.removeAll()
        tasks.forEach { $0.cancel() }
        assistantGenerationIdentity = nil
        assistantGenerationTurnID = nil
        assistantGenerationPrimaryTrigger = nil
    }

    private func cancelAssistantGenerationTasks(
        _ requestIDs: Set<UUID>
    ) {
        for requestID in requestIDs {
            assistantGenerationTasks.removeValue(forKey: requestID)?.cancel()
        }
    }

    private func isAssistantGenerationRequestActive(
        _ requestID: UUID
    ) -> Bool {
        assistantGenerationArbitration.contains(requestID)
    }

    private func claimAssistantGenerationSuggestion(
        requestID: UUID
    ) -> Bool {
        let claim = assistantGenerationArbitration.claimSuggestion(
            from: requestID
        )
        guard claim.isAccepted else { return false }
        cancelAssistantGenerationTasks(claim.requestIDsToCancel)
        return true
    }

    private func finishAssistantGenerationWithoutSuggestion(
        requestID: UUID,
        allowRetry: Bool = false
    ) -> Bool {
        let shouldPublish = assistantGenerationArbitration
            .finishWithoutSuggestion(requestID: requestID)
        assistantGenerationTasks.removeValue(forKey: requestID)
        if shouldPublish, allowRetry {
            assistantGenerationIdentity = nil
        }
        return shouldPublish
    }

    private func assistantGenerationRequestEnded(_ requestID: UUID) {
        assistantGenerationArbitration.requestEnded(requestID)
        assistantGenerationTasks.removeValue(forKey: requestID)
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
        whisperWarmupTask = Task(priority: .userInitiated) { [weak self] in
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

    private func startReferenceEmbeddingWarmupIfNeeded() {
        guard
            referenceEmbeddingWarmupTask == nil,
            referencePreparationState.pack?.preparationVersion
                == PreparedReferencePack.currentPreparationVersion
        else {
            return
        }
        referenceEmbeddingWarmupTask = Task.detached(priority: .utility) {
            _ = PreparedReferenceEmbedding.vector(
                for: "technical interview evidence"
            )
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

        if previousDeviceID != device?.id {
            microphoneRecoveryAttempts = 0
            clearMicrophoneRecoveryError()
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
            let warning =
                "The microphone disconnected. Remote audio is still being captured; reconnect it or select another input device."
            microphoneRecoveryErrorMessage = warning
            errorMessage = warning
            statusMessage = "Microphone disconnected — remote audio is still running"
            publishCompanionSession()
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

    private func scheduleMicrophoneRestart(
        sessionID: UUID,
        message: String,
        delay: TimeInterval = 0.28
    ) {
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
            deadline: .now() + delay,
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
        microphoneSignalStartedAt = Date()
        microphoneLastSignalAt = nil
        clearMicrophoneSignalError()
        let capture = MicrophoneCapture()
        microphoneCapture = capture
        capture.start(
            onBuffer: { buffer in
                localPipeline.submit(buffer)
            },
            onFirstBuffer: { [weak self, weak capture] in
                DispatchQueue.main.async {
                    guard
                        let self,
                        let capture,
                        self.activeSessionID == sessionID,
                        self.microphoneCaptureGeneration == generation,
                        self.microphoneCapture === capture
                    else {
                        return
                    }
                    if self.microphoneRecoveryAttempts > 0 {
                        Self.audioCaptureLogger.notice(
                            "microphone_recovery_succeeded attempts=\(self.microphoneRecoveryAttempts, privacy: .public)"
                        )
                    }
                    self.microphoneRecoveryAttempts = 0
                    self.clearMicrophoneRecoveryError()
                    self.statusMessage = self.captureListeningStatusMessage()
                    self.publishCompanionSession()
                }
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
            onStall: { [weak self, weak capture] in
                DispatchQueue.main.async {
                    guard
                        let self,
                        let capture,
                        self.activeSessionID == sessionID,
                        self.microphoneCaptureGeneration == generation,
                        self.microphoneCapture === capture
                    else {
                        return
                    }
                    self.recoverStalledMicrophone(sessionID: sessionID)
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
                        if capture.hasReceivedBuffer {
                            self.microphoneRecoveryAttempts = 0
                            self.clearMicrophoneRecoveryError()
                            self.statusMessage =
                                self.captureListeningStatusMessage()
                        } else {
                            self.statusMessage =
                                "Checking \(self.microphoneName) for audio…"
                        }
                        self.publishCompanionSession()

                    case let .failure(error):
                        capture.stop()
                        if self.microphoneCapture === capture {
                            self.microphoneCapture = nil
                        }
                        if isSwitch {
                            self.recoverMicrophoneAfterFailure(
                                sessionID: sessionID,
                                detail: error.localizedDescription
                            )
                        } else {
                            self.stopCapture()
                            self.present(error)
                        }
                    }
                }
            }
        )
    }

    private func recoverStalledMicrophone(sessionID: UUID) {
        recoverMicrophoneAfterFailure(
            sessionID: sessionID,
            detail: "No audio buffers arrived for \(Int(AudioCaptureLivenessPolicy.bufferTimeout)) seconds."
        )
    }

    private func recoverMicrophoneAfterFailure(
        sessionID: UUID,
        detail: String
    ) {
        guard
            isListening,
            activeSessionID == sessionID,
            selectedInputDeviceID != nil
        else {
            return
        }

        microphoneRecoveryAttempts += 1
        let delay = AudioCaptureRecoveryPolicy.meetingRestartDelay(
            after: microphoneRecoveryAttempts
        )
        let warning =
            "The microphone stopped delivering audio. Remote audio is still being captured while PermanentUnderclass reconnects \(microphoneName)."
        microphoneRecoveryErrorMessage = warning
        errorMessage = warning
        statusMessage = "Recovering microphone…"
        localTrack.telemetry.sourceFormat =
            "No microphone packets · retry \(microphoneRecoveryAttempts)"
        Self.audioCaptureLogger.error(
            "microphone_stalled attempt=\(self.microphoneRecoveryAttempts, privacy: .public) retry_delay_ms=\(Int(delay * 1_000), privacy: .public) detail=\(detail, privacy: .public)"
        )
        publishCompanionSession()
        scheduleMicrophoneRestart(
            sessionID: sessionID,
            message: "Recovering microphone…",
            delay: delay
        )
    }

    private func clearMicrophoneRecoveryError() {
        if errorMessage == microphoneRecoveryErrorMessage {
            errorMessage = nil
        }
        microphoneRecoveryErrorMessage = nil
    }

    private func handleMicrophoneTelemetry(
        _ telemetry: TrackTelemetry,
        sessionID: UUID,
        now: Date = Date()
    ) {
        guard isListening, activeSessionID == sessionID else { return }
        localTrack.telemetry = telemetry

        if telemetry.peak > 0 {
            microphoneLastSignalAt = telemetry.lastSignalAt ?? now
            if microphoneSignalErrorMessage != nil {
                let signalWarningWasVisible =
                    errorMessage == microphoneSignalErrorMessage
                clearMicrophoneSignalError()
                if signalWarningWasVisible {
                    statusMessage = captureListeningStatusMessage()
                    publishCompanionSession()
                }
            }
            return
        }

        let signalReference = microphoneLastSignalAt
            ?? microphoneSignalStartedAt
        guard
            let signalReference,
            now.timeIntervalSince(signalReference)
                > AudioStreamHealth.defaultSignalStaleAfter,
            microphoneSignalErrorMessage == nil
        else {
            return
        }

        let warning =
            "Audio packets are arriving from \(microphoneName), but they contain only digital silence. Check LINE or system mute and the selected input route."
        microphoneSignalErrorMessage = warning
        errorMessage = warning
        statusMessage = "No microphone signal — check mute and input routing"
        Self.audioCaptureLogger.error("microphone_digital_silence")
        publishCompanionSession()
    }

    private func clearMicrophoneSignalError() {
        if errorMessage == microphoneSignalErrorMessage {
            errorMessage = nil
        }
        microphoneSignalErrorMessage = nil
    }

    private func captureListeningStatusMessage() -> String {
        if activeCaptureUsesHostedTranscription {
            return "Listening on \(microphoneName) — headphones required"
        }
        let model = capability.resolvedEngine(
            preferring: refinementEngine
        ).shortLabel
        return "Listening locally with \(model) — headphones required"
    }

    private func stopImmediately() {
        closeActiveInterviewArchive()
        cancelAssistantGenerations()
        assistantBridgeTask?.cancel()
        assistantBridgeTask = nil
        assistantBridgeRequestID = nil
        assistantBridgeTurnID = nil
        assistantBridgeLatestText = ""
        assistantBridgeFormingAttemptCount = 0
        assistantBridgePauseAttemptCount = 0
        assistantBridgeFinalAttempted = false
        activeAssistantBridge = nil
        recentAssistantBridgeTexts = []
        latestRehearsalStory = nil
        microphoneRestartWorkItem?.cancel()
        microphoneRestartWorkItem = nil
        microphoneCaptureGeneration = nil
        microphoneRecoveryAttempts = 0
        microphoneSignalStartedAt = nil
        microphoneLastSignalAt = nil
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
        activePreparedReferencePack = nil
        activeCaptureUsesHostedTranscription = false
        activeAssistantAnswerMode = .grounded
        activeAssistantEarlyBridgeEnabled = false
        activeAssistantDeliveryMode = .verified
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
        assistantGenerationTasks.values.forEach { $0.cancel() }
        assistantBridgeTask?.cancel()
        referencePreparationTask?.cancel()
        referenceEmbeddingWarmupTask?.cancel()
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

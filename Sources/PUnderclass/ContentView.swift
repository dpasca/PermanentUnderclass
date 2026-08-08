import AppKit
import CoreAudio
import SwiftUI

struct ContentView: View {
    private enum AppTab: Hashable {
        case quickDictation
        case meeting
        case interview
    }

    @ObservedObject var controller: MeetingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// Dictation leads: it is the part that works with no account, no key, and
    /// no configuration.
    @State private var selectedTab: AppTab = .quickDictation

    var body: some View {
        VStack(spacing: 0) {
            sharedHeader
            Divider()

            TabView(selection: $selectedTab) {
                QuickDictationHistoryView(controller: controller)
                    .tabItem {
                        Label("Quick Dictation", systemImage: "mic.badge.plus")
                    }
                    .badge(controller.quickDictationHistory.count)
                    .tag(AppTab.quickDictation)

                meetingTab
                    .tabItem {
                        Label("Meeting", systemImage: "waveform")
                    }
                    .tag(AppTab.meeting)

                interviewTab
                    .tabItem {
                        Label("Interview", systemImage: "person.crop.rectangle")
                    }
                    .tag(AppTab.interview)
            }
        }
        .frame(minWidth: 1_000, minHeight: 760)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            controller.refreshDictationPermissions()
            controller.refreshAudioDevices()
            controller.refreshProcesses()
        }
    }

    /// Opens the Settings scene at a specific section. `openSettings` is the
    /// only reliable way to present it; the controller just records where to
    /// land.
    private func showSettings(_ section: SettingsSection) {
        controller.requestSettings(section)
        openSettings()
    }

    private var meetingTab: some View {
        captureTab(for: .meeting)
    }

    private var interviewTab: some View {
        captureTab(for: .interview)
    }

    private func captureTab(for purpose: CapturePurpose) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 12) {
                    captureControlPanel(for: purpose)
                    audioRoutePanel(for: purpose)
                }
                .locked(
                    liveFeature(for: purpose),
                    access: controller.access(to: liveFeature(for: purpose)),
                    onResolve: showSettings
                )

                preparationAccessPanel(for: purpose)

                generatedReplayPanel(for: purpose)
                    .locked(
                        replayFeature(for: purpose),
                        access: controller.access(to: replayFeature(for: purpose)),
                        onResolve: showSettings
                    )

                if let error = controller.errorMessage {
                    errorBanner(error)
                }

                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack(spacing: 16) {
                        TrackCard(
                            title: "MICROPHONE INPUT",
                            systemImage: "mic.fill",
                            subtitle: controller.microphoneName,
                            color: .blue,
                            state: controller.localTrack(for: purpose),
                            health: controller.captureMicrophoneHealth(
                                for: purpose,
                                at: timeline.date
                            )
                        )
                        TrackCard(
                            title: purpose == .meeting
                                ? "MEETING AUDIO"
                                : "INTERVIEWER AUDIO",
                            systemImage: controller.selectedProcessID == nil
                                ? "speaker.wave.2.fill"
                                : "macwindow.on.rectangle",
                            subtitle: selectedSystemAudioName,
                            color: .purple,
                            state: controller.remoteTrack(for: purpose),
                            health: controller.captureSystemAudioHealth(
                                for: purpose,
                                at: timeline.date
                            )
                        )
                    }
                }

                transcriptPanel(for: purpose)
                    .frame(minHeight: 180)
            }
            .padding(16)
        }
    }

    private func liveFeature(for purpose: CapturePurpose) -> CloudFeature {
        purpose == .meeting ? .meetingCapture : .answerMirror
    }

    private func replayFeature(for purpose: CapturePurpose) -> CloudFeature {
        purpose == .meeting ? .mockMeeting : .mockInterview
    }

    private var sharedHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PUnderclass")
                    .font(.system(size: 22, weight: .semibold))
                Text(visibleStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                sharedMicrophoneMenu(
                    health: controller.microphoneHealth(at: timeline.date)
                )
            }
            modelMenu
            apiEstimateButton

            Button {
                showSettings(.general)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.background)
    }

    /// Meeting and interview share capture plumbing, while the declared purpose
    /// selects the labels and model-backed assistant behavior.
    private func captureControlPanel(
        for purpose: CapturePurpose
    ) -> some View {
        let isActive = controller.isListening
            && controller.capturePurpose == purpose

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    purpose == .meeting ? "Meeting capture" : "Live interview",
                    systemImage: purpose == .meeting
                        ? "person.2.fill"
                        : "person.crop.rectangle"
                )
                    .font(.headline)
                Circle()
                    .fill(captureStatusColor(for: purpose))
                    .frame(width: 8, height: 8)
                Text(captureStatusLabel(for: purpose))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(
                    purpose == .meeting
                        ? "Open Meeting Assistant"
                        : "Open Answer Mirror",
                    action: controller.openCompanionDisplay
                )
                Label("Headphones required", systemImage: "headphones")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Button("Settings…") { showSettings(.general) }
                Button("Finish My Turn", action: controller.finalizeLocalTurn)
                    .disabled(!isActive)
                Button {
                    handlePrimaryCaptureAction(for: purpose)
                } label: {
                    Label(
                        primaryCaptureActionTitle(for: purpose),
                        systemImage: isActive ? "stop.fill" : "waveform"
                    )
                    .frame(minWidth: 108)
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive ? .red : .accentColor)
                .disabled(
                    controller.syntheticInterviewState.isActive
                        && controller.syntheticInterviewState.purpose == purpose
                )
            }

            HStack(spacing: 8) {
                Text(captureDescription(for: purpose))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                // Kept from the removed pipeline panel: when turns stop being
                // refined, this is the only place that says why.
                Text("Final pass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SocketBadge(
                    state: controller.capturePurpose == purpose
                        ? controller.refinementState
                        : .idle,
                    color: .green
                )
            }
        }
        .padding(12)
        .background(
            isActive
                ? Color.red.opacity(0.10)
                : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive
                        ? Color.red.opacity(0.75)
                        : Color.secondary.opacity(0.25),
                    lineWidth: isActive ? 2 : 1
                )
        }
    }

    private func captureStatusLabel(for purpose: CapturePurpose) -> String {
        if controller.syntheticInterviewState.isActive {
            return controller.syntheticInterviewState.purpose == purpose
                ? "Replay running"
                : "\(controller.syntheticInterviewState.purpose.title) replay running"
        }
        if controller.isListening {
            return controller.capturePurpose == purpose
                ? "Listening"
                : "\(controller.capturePurpose?.title ?? "Live capture") running"
        }
        return controller.access(to: liveFeature(for: purpose)).isAvailable
            ? "Ready"
            : "Needs setup"
    }

    private func captureStatusColor(for purpose: CapturePurpose) -> Color {
        if controller.syntheticInterviewState.isActive
            || (controller.isListening && controller.capturePurpose != purpose)
        {
            return .orange
        }
        if controller.isListening { return .red }
        return controller.access(to: liveFeature(for: purpose)).isAvailable
            ? .green
            : .secondary
    }

    private func captureDescription(for purpose: CapturePurpose) -> String {
        switch purpose {
        case .meeting:
            "Captures both sides and grounds Meeting Assistant response cues in your reference material."
        case .interview:
            "Captures both sides and sends interviewer moments to Answer Mirror for concise response cues."
        }
    }

    private func primaryCaptureActionTitle(
        for purpose: CapturePurpose
    ) -> String {
        if controller.syntheticInterviewState.isActive {
            return controller.syntheticInterviewState.purpose == purpose
                ? "Replay Running"
                : "Open \(controller.syntheticInterviewState.purpose.title)"
        }
        if controller.isListening {
            return controller.capturePurpose == purpose
                ? "Stop"
                : "Open \(controller.capturePurpose?.title ?? "Capture")"
        }
        return "Start \(purpose.title)"
    }

    private func handlePrimaryCaptureAction(for purpose: CapturePurpose) {
        if controller.syntheticInterviewState.isActive {
            selectedTab = controller.syntheticInterviewState.purpose == .meeting
                ? .meeting
                : .interview
        } else if controller.isListening {
            if controller.capturePurpose == purpose {
                controller.stopCapture()
            } else {
                selectedTab = controller.capturePurpose == .interview
                    ? .interview
                    : .meeting
            }
        } else {
            controller.startCapture(for: purpose)
        }
    }

    private func sharedMicrophoneMenu(health: AudioStreamHealth) -> some View {
        Menu {
            if controller.inputDevices.isEmpty {
                Text("No compatible microphones found")
            } else {
                ForEach(controller.inputDevices) { device in
                    Button {
                        controller.selectInputDevice(device.id)
                    } label: {
                        if device.id == controller.selectedInputDeviceID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(microphoneHealthColor(health))
                VStack(alignment: .leading, spacing: 1) {
                    Text("MICROPHONE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(controller.microphoneName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: 220)
            .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.blue.opacity(0.20), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .help("Shared microphone for Quick Dictation, meetings, and interviews")
    }

    /// A chooser, not a signpost. Clicking the thing that names the current
    /// model should let you change it, the same way the microphone menu beside
    /// it works.
    private var modelMenu: some View {
        let active = controller.resolvedDictationEngine
        return Menu {
            ForEach(TranscriptRefinementEngine.allCases) { engine in
                let isLocked = engine.isCloud
                    && !controller.capability.isCloudEnabled
                Button {
                    controller.selectRefinementEngine(engine)
                } label: {
                    if engine == active {
                        Label(menuTitle(for: engine, isLocked: isLocked),
                              systemImage: "checkmark")
                    } else {
                        Text(menuTitle(for: engine, isLocked: isLocked))
                    }
                }
                .disabled(
                    isLocked
                        || controller.isListening
                        || controller.isDictationBusy
                )
            }

            Divider()

            if !controller.capability.isCloudEnabled {
                Button("Set Up OpenAI…") { showSettings(.openAI) }
            }
            Button("Dictation Settings…") { showSettings(.dictation) }
            Button("How It Works…") { showSettings(.howItWorks) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: active.isCloud ? "cloud" : "desktopcomputer")
                    .foregroundStyle(active.isCloud ? .blue : .green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TRANSCRIBED BY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("\(active.accuracyTitle) · \(active.shortLabel)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: 215)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.secondary.opacity(0.20), lineWidth: 1)
            }
        }
        // `.borderlessButton` flattens a multi-line label to its first line,
        // which would hide the very thing this control reports.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which model finalizes captured turns and transcribes Quick Dictation")
        // No explicit accessibility label: this menu style nests several
        // wrapper elements, and a custom label is inherited by each of them,
        // so VoiceOver would announce the same control four times. The visible
        // text already reads as "Transcribed by, Accurate · Whisper".
    }

    private func menuTitle(
        for engine: TranscriptRefinementEngine,
        isLocked: Bool
    ) -> String {
        let base = "\(engine.accuracyTitle) · \(engine.shortLabel)"
        guard isLocked else { return base }
        return "\(base) (needs OpenAI key)"
    }

    /// A running cost is meaningless to someone with no key, so it only
    /// appears once there is spending to report.
    @ViewBuilder
    private var apiEstimateButton: some View {
        if controller.capability.hasAPIKey {
            Button {
                showSettings(.openAI)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "dollarsign.circle")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("API ESTIMATE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(controller.apiExpenses.displayCost)
                                .font(.callout.monospacedDigit().weight(.semibold))
                            Text(controller.apiExpenses.accumulationDescription())
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.green.opacity(0.20), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .help("Estimated OpenAI spending \(controller.apiExpenses.accumulationDescription())")
        }
    }

    private func microphoneHealthColor(_ health: AudioStreamHealth) -> Color {
        switch health {
        case .healthy:
            .green
        case .checking, .dropping, .permissionRequired:
            .orange
        case .unavailable, .noData:
            .red
        case .ready:
            .blue
        }
    }

    private var visibleStatusMessage: String {
        switch selectedTab {
        case .meeting:
            controller.syntheticInterviewState.isActive
                && controller.syntheticInterviewState.purpose == .meeting
                ? controller.syntheticInterviewState.title
                : controller.statusMessage
        case .interview:
            controller.syntheticInterviewState.isActive
                && controller.syntheticInterviewState.purpose == .interview
                ? controller.syntheticInterviewState.title
                : controller.statusMessage
        case .quickDictation:
            "Quick Dictation · \(controller.dictationPhase.label)"
        }
    }

    private func preparationAccessPanel(
        for purpose: CapturePurpose
    ) -> some View {
        let state = controller.referenceLibraryState
        let snapshot = state.snapshot

        return Button {
            controller.preparationPurpose = purpose
            openWindow(id: PUnderclassWindow.preparation)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "checklist")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prepare " + purpose.title)
                        .font(.title3.weight(.semibold))
                    Text(
                        purpose == .meeting
                            ? "Add a brief, exact terms, languages, and reference documents for transcription and Meeting Assistant."
                            : "Add role context, exact terms, languages, and reference documents for transcription and Answer Mirror."
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 5) {
                    Text("Session guidance + references")
                        .font(.callout.weight(.medium))
                    if let folderURL = state.folderURL {
                        Text(referenceSummary(snapshot: snapshot, folderURL: folderURL))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No folder selected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Label("Open Setup…", systemImage: "arrow.up.right.square")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .foregroundStyle(.white)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.accentColor.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .accessibilityLabel("Prepare \(purpose.title)")
    }

    private func generatedReplayPanel(
        for purpose: CapturePurpose
    ) -> some View {
        let state = controller.generatedReplayState(for: purpose)
        let otherReplayPurpose = controller.syntheticInterviewState.isActive
            && controller.syntheticInterviewState.purpose != purpose
            ? controller.syntheticInterviewState.purpose
            : nil

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(state.title)
                        .font(.callout.weight(.semibold))
                    Text("GENERATED \(purpose.title.uppercased()) REPLAY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.indigo)
                }
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if state.isActive {
                    if state.isGenerating {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 360)
                    } else {
                        ProgressView(value: state.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 360)
                    }
                } else {
                    Text(
                        otherReplayPurpose.map {
                            "A generated \($0.title.lowercased()) replay is already running."
                        } ?? controller.generatedReplayReadinessDetail(
                            for: purpose
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text(
                    purpose == .interview
                        ? "5 GROUNDED EXCHANGES · 1 LIVE WEB CHECK"
                        : "5 GROUNDED EXCHANGES · ASSISTANT PAUSE 800 ms"
                )
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Open Assistant", action: controller.openCompanionDisplay)
                    if let otherReplayPurpose {
                        Button("Open \(otherReplayPurpose.title)") {
                            selectedTab = otherReplayPurpose == .meeting
                                ? .meeting
                                : .interview
                        }
                    } else if state.isActive {
                        Button("Stop Replay", action: controller.stopGeneratedReplay)
                            .tint(.red)
                    } else {
                        if purpose == .interview {
                            Button {
                                controller.startWebSearchTest()
                            } label: {
                                Label("Test Web Search", systemImage: "globe")
                            }
                            .disabled(!controller.canStartWebSearchTest())
                            .help(controller.webSearchTestReadinessDetail())
                        }
                        Button(purpose == .meeting ? "New Scenario" : "New Questions") {
                            controller.openCompanionDisplay()
                            controller.regenerateGeneratedReplay(for: purpose)
                        }
                        .disabled(!controller.canStartGeneratedReplay(for: purpose))
                        Button {
                            controller.openCompanionDisplay()
                            controller.startGeneratedReplay(for: purpose)
                        } label: {
                            Label("Run Replay", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(!controller.canStartGeneratedReplay(for: purpose))
                    }
                }
            }
        }
        .padding(11)
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.indigo.opacity(0.25), lineWidth: 1)
        }
    }

    private func audioRoutePanel(for purpose: CapturePurpose) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(purpose.title) audio route", systemImage: "waveform")
                .font(.headline)

            AudioDeviceRow(
                title: "SYSTEM OUTPUT",
                name: controller.audioOutputName,
                systemImage: "speaker.wave.2.fill",
                isConnected: controller.audioOutputAvailable,
                devices: controller.outputDevices,
                selectedDeviceID: controller.selectedOutputDeviceID,
                onSelect: controller.selectOutputDevice
            )

            Divider()

            HStack(spacing: 8) {
                Image(
                    systemName: controller.selectedProcessID == nil
                        ? "speaker.wave.2.fill"
                        : "macwindow.on.rectangle"
                )
                    .foregroundStyle(.purple)
                    .frame(width: 20)
                Picker("Audio to transcribe", selection: $controller.selectedProcessID) {
                    Text("All system audio (default)").tag(Optional<UInt32>.none)
                    ForEach(controller.processes) { process in
                        Text(process.displayName).tag(Optional(process.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(controller.isListening)
                .help("Capture all system audio, or limit transcription to one app")

                Button {
                    controller.refreshProcesses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh app-specific audio sources")
                .disabled(controller.isListening)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                controller.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func transcriptPanel(
        for purpose: CapturePurpose
    ) -> some View {
        let turns = controller.transcript(for: purpose)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(purpose.title) transcript", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Button("Copy") { controller.copyTranscript(for: purpose) }
                    .disabled(turns.isEmpty)
                Button("Export…") { controller.exportTranscript(for: purpose) }
                    .disabled(turns.isEmpty)
                Button("Clear") { controller.clearTranscript(for: purpose) }
                    .disabled(turns.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if turns.isEmpty {
                        ContentUnavailableView(
                            "No \(purpose.title.lowercased()) transcript yet",
                            systemImage: "waveform",
                            description: Text(
                                "Finalized \(purpose.title.lowercased()) turns appear here in chronological order."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(turns) { turn in
                            TranscriptRow(turn: turn)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.separator.opacity(0.6), lineWidth: 1)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func referenceSummary(
        snapshot: ReferenceLibrarySnapshot?,
        folderURL: URL
    ) -> String {
        guard let snapshot else {
            return (folderURL.path as NSString).abbreviatingWithTildeInPath
        }
        let documentLabel = snapshot.documents.count == 1 ? "document" : "documents"
        let ignored = snapshot.ignoredFileCount > 0
            ? " · \(snapshot.ignoredFileCount) unsupported ignored"
            : ""
        return "\(snapshot.documents.count) \(documentLabel) · \(compactCharacterCount(snapshot.totalCharacters)) chars · rev \(snapshot.revision.prefix(8))\(ignored)"
    }

    private func compactCharacterCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return String(count)
    }

    private var selectedSystemAudioName: String {
        guard let selectedProcessID = controller.selectedProcessID else {
            return "All system audio"
        }
        return controller.processes.first(where: { $0.id == selectedProcessID })?.name
            ?? "Selected app unavailable"
    }
}

struct AudioDeviceRow: View {
    let title: String
    let name: String
    let systemImage: String
    let devices: [AudioDeviceOption]
    let selectedDeviceID: AudioObjectID?
    let onSelect: (AudioObjectID) -> Void
    private let health: AudioStreamHealth?
    private let isConnected: Bool?

    init(
        title: String,
        name: String,
        systemImage: String,
        health: AudioStreamHealth,
        devices: [AudioDeviceOption],
        selectedDeviceID: AudioObjectID?,
        onSelect: @escaping (AudioObjectID) -> Void
    ) {
        self.title = title
        self.name = name
        self.systemImage = systemImage
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.onSelect = onSelect
        self.health = health
        isConnected = nil
    }

    init(
        title: String,
        name: String,
        systemImage: String,
        isConnected: Bool,
        devices: [AudioDeviceOption],
        selectedDeviceID: AudioObjectID?,
        onSelect: @escaping (AudioObjectID) -> Void
    ) {
        self.title = title
        self.name = name
        self.systemImage = systemImage
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID
        self.onSelect = onSelect
        health = nil
        self.isConnected = isConnected
    }

    var body: some View {
        HStack(spacing: 7) {
            AudioDeviceMenu(
                title: title,
                name: name,
                systemImage: systemImage,
                color: iconColor,
                devices: devices,
                selectedDeviceID: selectedDeviceID,
                onSelect: onSelect
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .help(name)
            }
            Spacer(minLength: 6)
            if let health {
                AudioHealthBadge(health: health)
            } else if let isConnected {
                ConnectionBadge(isConnected: isConnected)
            }
        }
    }

    private var iconColor: Color {
        health == nil ? .indigo : .blue
    }
}

private struct AudioDeviceMenu: View {
    let title: String
    let name: String
    let systemImage: String
    let color: Color
    let devices: [AudioDeviceOption]
    let selectedDeviceID: AudioObjectID?
    let onSelect: (AudioObjectID) -> Void

    var body: some View {
        Menu {
            if devices.isEmpty {
                Text("No compatible devices found")
            } else {
                ForEach(devices) { device in
                    Button {
                        onSelect(device.id)
                    } label: {
                        if device.id == selectedDeviceID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Choose \(title.lowercased())")
        .help("Choose \(title.lowercased()). Current device: \(name)")
    }
}

private struct ConnectionBadge: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(isConnected ? "Connected" : "Not connected")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

private struct AudioHealthBadge: View {
    let health: AudioStreamHealth

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(health.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize()
        .help(health.detail)
    }

    private var color: Color {
        switch health {
        case .healthy:
            .green
        case .checking, .dropping, .permissionRequired:
            .orange
        case .unavailable, .noData:
            .red
        case .ready:
            .secondary
        }
    }
}

private struct TrackCard: View {
    let title: String
    let systemImage: String
    let subtitle: String
    let color: Color
    let state: TrackViewState
    let health: AudioStreamHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: systemImage)
                        .font(.callout.bold())
                        .foregroundStyle(color)
                    Text(subtitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    AudioHealthBadge(health: health)
                    HStack(spacing: 4) {
                        Text("Transcription")
                        SocketBadge(state: state.socket, color: color)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            WaveformView(samples: state.telemetry.waveform, color: color)
                .frame(height: 44)

            HStack(spacing: 10) {
                LevelBar(label: "RMS", value: state.telemetry.rms, color: color)
                LevelBar(label: "PEAK", value: state.telemetry.peak, color: color)
            }

            Text(state.partialTranscript.isEmpty ? "Waiting for speech…" : state.partialTranscript)
                .font(.body)
                .foregroundStyle(state.partialTranscript.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .textSelection(.enabled)

            HStack {
                Text(state.telemetry.sourceFormat)
                    .lineLimit(1)
                Spacer()
                Text("Signal \(signalLevel)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Text(health.detail)
                    .lineLimit(1)
                Spacer()
                Text("\(state.telemetry.packets) packets")
                Text("·")
                Text("\(state.telemetry.droppedBuffers) dropped")
                    .foregroundStyle(state.telemetry.droppedBuffers > 0 ? .orange : .secondary)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var signalLevel: String {
        guard state.telemetry.packets > 0 else { return "—" }
        guard state.telemetry.rms > 0.000_01 else { return "silent" }
        let decibels = 20 * log10(Double(state.telemetry.rms))
        return "\(Int(decibels.rounded())) dB"
    }
}

enum WaveformNormalization {
    case absolute
    case adaptive
}

enum WaveformDisplayNormalizer {
    static func adaptiveSamples(
        _ samples: [Float],
        targetRMS: Float = 0.30,
        maximumGain: Float = 24,
        noiseFloor: Float = 0.000_2
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let recent = samples.suffix(180).filter(\.isFinite)
        guard !recent.isEmpty else {
            return Array(repeating: 0, count: samples.count)
        }

        let meanSquare = recent.reduce(Float(0)) { sum, sample in
            sum + sample * sample
        } / Float(recent.count)
        let rms = sqrt(meanSquare)
        guard rms >= noiseFloor else {
            return Array(repeating: 0, count: samples.count)
        }

        let gain = min(maximumGain, max(1, targetRMS / rms))
        return samples.map { sample in
            guard sample.isFinite else { return 0 }
            return max(-1, min(1, sample * gain))
        }
    }
}

struct WaveformView: View {
    let samples: [Float]
    let color: Color
    let normalization: WaveformNormalization

    init(
        samples: [Float],
        color: Color,
        normalization: WaveformNormalization = .absolute
    ) {
        self.samples = samples
        self.color = color
        self.normalization = normalization
    }

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: middle))
            baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

            let displaySamples = normalizedSamples
            guard displaySamples.count > 1 else { return }
            var path = Path()
            for (index, sample) in displaySamples.enumerated() {
                let x = CGFloat(index) / CGFloat(displaySamples.count - 1) * size.width
                let clamped = max(-1, min(1, CGFloat(sample)))
                let y = middle - clamped * middle * 0.9
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    private var normalizedSamples: [Float] {
        switch normalization {
        case .absolute:
            samples
        case .adaptive:
            WaveformDisplayNormalizer.adaptiveSamples(samples)
        }
    }
}

struct LevelBar: View {
    let label: String
    let value: Float
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            ProgressView(value: Double(min(1, max(0, value))))
                .tint(color)
        }
    }
}

private struct SocketBadge: View {
    let state: SocketState
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
            Text(state.label)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(state.detail ?? state.label)
    }

    private var indicatorColor: Color {
        switch state {
        case .connected: color
        case .connecting: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }
}

private struct TranscriptRow: View {
    let turn: TranscriptTurn

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(turn.speaker.displayName(for: turn.purpose).uppercased())
                .font(.callout.bold())
                .foregroundStyle(turn.speaker == .you ? .blue : .purple)
                .frame(
                    width: turn.purpose == .interview ? 92 : 52,
                    alignment: .leading
                )
            Text(turn.startedAt, style: .time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(turn.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TranscriptRefinementBadge(state: turn.refinement)
                }
                if case .refined = turn.refinement, turn.liveText != turn.text {
                    Text("Live: \(turn.liveText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptRefinementBadge: View {
    let state: TranscriptRefinementState

    var body: some View {
        Group {
            switch state {
            case .refining:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refining")
                }
            case .refined:
                Label("Refined", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .liveOnly:
                Label("Live only", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        switch state {
        case .refining:
            "The live transcript is visible while the captured turn audio is transcribed again."
        case .refined:
            "This text is the result of the audio-native second pass."
        case let .liveOnly(message):
            message ?? "Only the live transcription result is available."
        }
    }
}

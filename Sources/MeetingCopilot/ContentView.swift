import AppKit
import CoreAudio
import SwiftUI

struct ContentView: View {
    private enum AppTab: Hashable {
        case meeting
        case quickDictation
    }

    @ObservedObject var controller: MeetingController
    @State private var contextExpanded = false
    @State private var expenseExpanded = false
    @State private var modelPipelineExpanded = false
    @State private var sharedSettingsExpanded = false
    @State private var selectedTab: AppTab = .meeting

    var body: some View {
        VStack(spacing: 0) {
            sharedHeader
            Divider()

            TabView(selection: $selectedTab) {
                meetingTab
                    .tabItem {
                        Label("Meeting", systemImage: "waveform")
                    }
                    .tag(AppTab.meeting)

                QuickDictationHistoryView(controller: controller)
                    .tabItem {
                        Label("Quick Dictation", systemImage: "mic.badge.plus")
                    }
                    .badge(controller.quickDictationHistory.count)
                    .tag(AppTab.quickDictation)
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

    private var meetingTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                meetingHeader
                mainControls
                syntheticInterviewPanel

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
                            state: controller.localTrack,
                            health: controller.meetingMicrophoneHealth(at: timeline.date)
                        )
                        TrackCard(
                            title: "MEETING AUDIO",
                            systemImage: controller.selectedProcessID == nil
                                ? "speaker.wave.2.fill"
                                : "macwindow.on.rectangle",
                            subtitle: selectedMeetingAudioName,
                            color: .purple,
                            state: controller.remoteTrack,
                            health: controller.meetingAudioHealth(at: timeline.date)
                        )
                    }
                }

                transcriptPanel
                    .frame(minHeight: 180)
                contextPanel
            }
            .padding(16)
        }
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
            modelPipelineButton
            apiEstimateButton

            Button {
                sharedSettingsExpanded.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Shared transcription settings")
            .accessibilityLabel("Shared transcription settings")
            .overlay(alignment: .topTrailing) {
                if controller.apiKeyDraft.isEmpty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                }
            }
            .popover(isPresented: $sharedSettingsExpanded, arrowEdge: .bottom) {
                SharedTranscriptionSettingsPopover(controller: controller)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.background)
    }

    private var meetingHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Meeting Capture", systemImage: "person.2.fill")
                    .font(.system(size: 24, weight: .semibold))
                Text("Capture both sides of a meeting and build a refined transcript.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Headphones required", systemImage: "headphones")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            Button("Finish My Turn", action: controller.finalizeLocalTurn)
                .disabled(!controller.isListening)
            Button {
                if controller.isListening {
                    controller.stopMeeting()
                } else {
                    controller.startMeeting()
                }
            } label: {
                Label(
                    controller.isListening ? "Stop" : "Start Listening",
                    systemImage: controller.isListening ? "stop.fill" : "waveform"
                )
                .frame(minWidth: 115)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isListening ? .red : .accentColor)
            .disabled(controller.syntheticInterviewState.isActive)
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
        .help("Shared microphone for Meeting and Quick Dictation")
    }

    private var modelPipelineButton: some View {
        Button {
            modelPipelineExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 0) {
                    Text("ACTIVE MODELS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("MEETING LIVE · \(RealtimeTranscriptionClient.model)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    Text("FINAL + DICTATION · \(controller.refinementEngine.title)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(width: 265)
            .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.green.opacity(0.20), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Show every transcription model, stage, and responsibility")
        .accessibilityLabel("Active transcription models and pipeline")
        .popover(isPresented: $modelPipelineExpanded, arrowEdge: .bottom) {
            TranscriptionPipelinePopover(controller: controller)
        }
    }

    private var apiEstimateButton: some View {
        Button {
            expenseExpanded = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("API ESTIMATE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(controller.apiExpenses.displayCost)
                        .font(.callout.monospacedDigit().weight(.semibold))
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
        .help("Estimated transcription cost and assistant token usage since reset")
        .popover(isPresented: $expenseExpanded, arrowEdge: .bottom) {
            APIExpensePopover(
                summary: controller.apiExpenses,
                onReset: controller.resetAPIExpenses
            )
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
            controller.statusMessage
        case .quickDictation:
            "Quick Dictation · \(controller.dictationPhase.label)"
        }
    }

    private var syntheticInterviewPanel: some View {
        let state = controller.syntheticInterviewState

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(state.title)
                        .font(.callout.weight(.semibold))
                    Text("DOCUMENT-GROUNDED REPLAY")
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
                    Text(controller.syntheticInterviewReadinessDetail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text("3 GROUNDED Q&A · AUDIO PAUSE 800 ms")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Open Assistant", action: controller.openCompanionDisplay)
                    if state.isActive {
                        Button("Stop Replay", action: controller.stopSyntheticInterview)
                            .tint(.red)
                    } else {
                        Button("New Questions") {
                            controller.openCompanionDisplay()
                            controller.regenerateSyntheticInterview()
                        }
                        .disabled(!controller.canStartSyntheticInterview)
                        Button {
                            controller.openCompanionDisplay()
                            controller.startSyntheticInterview()
                        } label: {
                            Label("Run Interview", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(!controller.canStartSyntheticInterview)
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

    private var mainControls: some View {
        HStack(alignment: .top, spacing: 12) {
            meetingModelPanel
            meetingAudioRoutePanel
                .frame(width: 390)
        }
    }

    private var meetingModelPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Meeting model pipeline", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Text("Final connection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SocketBadge(state: controller.refinementState, color: .green)
            }

            HStack(alignment: .center, spacing: 8) {
                TranscriptionStageCard(
                    stage: "STAGE 1 · LIVE",
                    modelName: RealtimeTranscriptionClient.model,
                    role: "Streaming text · both audio tracks",
                    detail: "",
                    badge: "FIXED",
                    systemImage: "bolt.horizontal.fill",
                    color: .blue
                )
                TranscriptionPipelineConnector(label: "TURN\nENDS")
                TranscriptionStageCard(
                    stage: "STAGE 2 · FINAL",
                    modelName: controller.refinementEngine.modelName,
                    role: "\(controller.refinementEngine.title) · completed turns",
                    detail: "",
                    badge: "SELECTED",
                    systemImage: controller.refinementEngine.systemImage,
                    color: .green
                )
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var meetingAudioRoutePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Meeting audio route", systemImage: "waveform")
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

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Transcript", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Button("Copy", action: controller.copyTranscript)
                    .disabled(controller.transcript.isEmpty)
                Button("Export…", action: controller.exportTranscript)
                    .disabled(controller.transcript.isEmpty)
                Button("Clear", action: controller.clearTranscript)
                    .disabled(controller.transcript.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if controller.transcript.isEmpty {
                        ContentUnavailableView(
                            "No final transcript yet",
                            systemImage: "waveform",
                            description: Text("Finalized speech turns appear here in chronological order.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(controller.transcript) { turn in
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

    private var contextPanel: some View {
        DisclosureGroup(isExpanded: $contextExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                referenceMaterialPanel

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Meeting context")
                            .font(.callout.weight(.medium))
                        TextEditor(text: $controller.topicPrompt)
                            .font(.body)
                            .frame(minHeight: 64)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.separator.opacity(0.7), lineWidth: 1)
                            }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Terminology — one literal term per line")
                            .font(.callout.weight(.medium))
                        TextEditor(text: $controller.keywordsText)
                            .font(.body)
                            .frame(minHeight: 64)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.separator.opacity(0.7), lineWidth: 1)
                            }
                    }
                }

                HStack {
                    Text("Terminology and the API key are shared with cloud Quick Dictation; expected languages also guide Local Whisper.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Shared Settings…") {
                        sharedSettingsExpanded = true
                    }
                    Spacer()
                    Picker("Accuracy / latency", selection: $controller.delay) {
                        ForEach(TranscriptionDelay.allCases) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    .frame(width: 180)
                    Button("Apply Context", action: controller.applyContext)
                }
                Text("For specialized discussions, add exact vocabulary before the meeting—for example CUDA, thread block, and warp. Medium is the recommended starting point for balanced accuracy and latency.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            Label(
                "References and meeting context",
                systemImage: "slider.horizontal.3"
            )
                .font(.headline)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var referenceMaterialPanel: some View {
        let state = controller.referenceLibraryState
        let snapshot = state.snapshot

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Label("Reference material", systemImage: "folder.fill")
                    .font(.callout.weight(.semibold))
                Spacer()
                if state.phase == .scanning {
                    ProgressView()
                        .controlSize(.small)
                } else if state.phase == .ready {
                    Circle()
                        .fill(state.isWatching ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                }
                Text(state.phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: state.folderURL == nil ? "folder.badge.plus" : "folder")
                    .font(.title3)
                    .foregroundStyle(state.folderURL == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    if let folderURL = state.folderURL {
                        Text(folderURL.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(referenceSummary(snapshot: snapshot, folderURL: folderURL))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help((folderURL.path as NSString).abbreviatingWithTildeInPath)
                    } else {
                        Text("Choose one folder for resumes, project notes, and other context.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                if state.folderURL != nil {
                    Button("Reveal", action: controller.revealReferenceFolder)
                    Button {
                        controller.rescanReferenceFolder()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan reference material now")
                    Button("Change…", action: controller.chooseReferenceFolder)
                    Button {
                        controller.clearReferenceFolder()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Stop using this reference folder")
                } else {
                    Button("Choose Folder…", action: controller.chooseReferenceFolder)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(9)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }

            if case let .failed(message) = state.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else if let snapshot, !snapshot.issues.isEmpty {
                Text(
                    "Indexed with \(snapshot.issues.count) warning"
                        + (snapshot.issues.count == 1 ? "" : "s")
                        + ": \(snapshot.issues[0].relativePath) — \(snapshot.issues[0].message)"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help(snapshot.issues.map { "\($0.relativePath): \($0.message)" }.joined(separator: "\n"))
            }

            HStack(spacing: 8) {
                Image(systemName: "display")
                    .foregroundStyle(.green)
                Text(controller.companionGatewayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Open Live Assistant", action: controller.openCompanionDisplay)
            }

            Text("The Mac ingests PDF, RTF, Markdown, and common UTF-8 text files at launch and after folder changes. Reference contents and the API key stay out of the display client.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private var selectedMeetingAudioName: String {
        guard let selectedProcessID = controller.selectedProcessID else {
            return "All system audio"
        }
        return controller.processes.first(where: { $0.id == selectedProcessID })?.name
            ?? "Selected app unavailable"
    }
}

private struct SharedTranscriptionSettingsPopover: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Shared Transcription Settings", systemImage: "gearshape")
                        .font(.title3.weight(.semibold))
                    Text("These settings apply to both Meeting and Quick Dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    AudioDeviceRow(
                        title: "MICROPHONE INPUT",
                        name: controller.microphoneName,
                        systemImage: "mic.fill",
                        health: controller.microphoneHealth(at: timeline.date),
                        devices: controller.inputDevices,
                        selectedDeviceID: controller.selectedInputDeviceID,
                        onSelect: controller.selectInputDevice
                    )
                }

                Divider()

                SelectableTranscriptionModelPicker(controller: controller)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Expected languages")
                        .font(.headline)
                    TextField("Languages, e.g. en, ja", text: $controller.languagesText)
                        .textFieldStyle(.roundedBorder)
                    Text(
                        "Quick Dictation uses this immediately. Meeting uses it when a session starts or when meeting context is applied."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenAI API key")
                        .font(.headline)
                    HStack {
                        SecureField("API key", text: $controller.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(controller.saveAPIKey)
                        Button("Save to Keychain", action: controller.saveAPIKey)
                    }
                    if !controller.keyStatus.isEmpty {
                        Text(controller.keyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "The long-lived key stays in this Mac’s Keychain. Use an internal short-lived-token broker before deployment."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .frame(width: 590, height: 500)
    }

}

private struct APIExpensePopover: View {
    let summary: APIExpenseSummary
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("OpenAI usage estimate", systemImage: "dollarsign.circle")
                        .font(.headline)
                    Text("Since the last reset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary.displayCost)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.green)
            }

            Divider()

            expenseRow(
                title: RealtimeTranscriptionClient.model,
                detail: "Live · \(durationText(summary.liveAudioSeconds))",
                cost: summary.liveCostUSD,
                color: .blue
            )
            expenseRow(
                title: RealtimeRefinementClient.model,
                detail: "Final + cloud dictation · \(durationText(summary.finalAudioSeconds))",
                cost: summary.finalCostUSD,
                color: .purple
            )
            HStack(spacing: 9) {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(InterviewWingmanClient.model)
                        .font(.subheadline.weight(.medium))
                    Text(
                        "Scenario + Answer Mirror · \(summary.assistantGenerations) generations · "
                            + "\(summary.assistantInputTokens) input / "
                            + "\(summary.assistantOutputTokens) output / "
                            + "\(summary.assistantReasoningTokens) reasoning tokens"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("usage")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            expenseRow(
                title: "Local Whisper Large v3",
                detail: "Runs on this Mac",
                cost: 0,
                color: .green
            )
            expenseRow(
                title: "Local Parakeet",
                detail: "Faster lightweight local option",
                cost: 0,
                color: .green
            )

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text(measurementDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "Rates configured \(APIExpenseSummary.pricingEffectiveAt): "
                        + "$0.017/min live and $0.0045/min final. "
                        + "Assistant tokens are tracked but excluded from the total until a rate is configured. "
                        + "The OpenAI invoice is the source of truth."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Reset Counter") {
                    onReset()
                }
                .disabled(
                    summary.totalAudioSeconds == 0
                        && summary.assistantGenerations == 0
                )
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func expenseRow(
        title: String,
        detail: String,
        cost: Double,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.monospaced().weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(displayCost(cost))
                .font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private var measurementDetail: String {
        guard summary.serverReportedRecords + summary.estimatedRecords > 0 else {
            return "Usage appears after OpenAI completes a transcription turn."
        }
        if summary.estimatedRecords == 0 {
            return "Calculated from server-reported transcription duration."
        }
        return "Uses server-reported duration when available; "
            + "\(summary.estimatedRecords) completed turn(s) use submitted PCM duration."
    }

    private func durationText(_ seconds: Double) -> String {
        String(format: "%.1f min", seconds / 60)
    }

    private func displayCost(_ value: Double) -> String {
        String(format: value < 0.01 ? "$%.4f" : "$%.2f", value)
    }
}

struct ModelChoiceButton: View {
    let engine: TranscriptRefinementEngine
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: engine.systemImage)
                    Text(engine.title)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.green : Color.secondary)
                }
                Text(engine.modelName)
                    .font(.caption.monospaced().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(engine.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(
                isSelected ? Color.green.opacity(0.10) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? Color.green.opacity(0.8) : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isSelected ? 0.55 : 1)
        .accessibilityLabel("Final pass and Quick Dictation: \(engine.title), \(engine.modelName)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .help(
            isDisabled
                ? "Stop the active workflow before changing this model."
                : engine.purpose
        )
    }
}

private struct AudioDeviceRow: View {
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
            Text(turn.speaker.rawValue.uppercased())
                .font(.callout.bold())
                .foregroundStyle(turn.speaker == .you ? .blue : .purple)
                .frame(width: 52, alignment: .leading)
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

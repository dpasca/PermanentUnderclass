import AppKit
import CoreAudio
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: MeetingController
    @State private var contextExpanded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                mainControls
                dictationBar

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
                            state: controller.isDictating
                                ? TrackViewState(telemetry: controller.dictationTelemetry)
                                : controller.localTrack,
                            health: controller.microphoneHealth(at: timeline.date)
                        )
                        TrackCard(
                            title: "MEETING APP AUDIO",
                            systemImage: "macwindow.on.rectangle",
                            subtitle: selectedProcessName,
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
        .frame(minWidth: 1_000, minHeight: 760)
        .onAppear {
            contextExpanded = controller.apiKeyDraft.isEmpty
        }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PUnderclass")
                    .font(.system(size: 24, weight: .semibold))
                Text(controller.statusMessage)
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
        }
    }

    private var mainControls: some View {
        HStack(alignment: .top, spacing: 12) {
            modelPanel
            audioRoutePanel
                .frame(width: 390)
        }
    }

    private var modelPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Transcription models", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Text("Final")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SocketBadge(state: controller.refinementState, color: .green)
            }

            HStack(alignment: .center, spacing: 10) {
                Text("LIVE")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                    .frame(width: 42, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(RealtimeTranscriptionClient.model)
                        .font(.callout.monospaced().weight(.semibold))
                    Text("Fast streaming text for both audio sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("ALWAYS ON")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.11), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .center, spacing: 7) {
                Text("FINAL")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .frame(width: 42, alignment: .leading)
                ForEach(TranscriptRefinementEngine.allCases) { engine in
                    ModelChoiceButton(
                        engine: engine,
                        isSelected: controller.refinementEngine == engine,
                        isDisabled: controller.isListening || controller.isDictationBusy,
                        action: { controller.selectRefinementEngine(engine) }
                    )
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                parakeetWarmupHint(at: timeline.date)
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

    @ViewBuilder
    private func parakeetWarmupHint(at date: Date) -> some View {
        if let hint = controller.parakeetPreparation.hint(at: date) {
            HStack(spacing: 6) {
                if let fraction = controller.parakeetPreparation.downloadFraction {
                    ProgressView(value: fraction)
                        .frame(width: 54)
                } else if controller.parakeetPreparation.isInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else if controller.parakeetPreparation.isReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(hint)
                    .lineLimit(1)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(
                controller.parakeetPreparation.isFailed ? Color.orange : Color.secondary
            )
            .padding(.leading, 52)
            .help(hint)
        }
    }

    private var audioRoutePanel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 6) {
                Label("Audio devices", systemImage: "waveform")
                    .font(.headline)

                AudioDeviceRow(
                    title: "MICROPHONE INPUT",
                    name: controller.microphoneName,
                    systemImage: "mic.fill",
                    health: controller.microphoneHealth(at: timeline.date),
                    devices: controller.inputDevices,
                    selectedDeviceID: controller.selectedInputDeviceID,
                    onSelect: controller.selectInputDevice
                )

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
                    Image(systemName: "macwindow.on.rectangle")
                        .foregroundStyle(.purple)
                        .frame(width: 20)
                    Picker("Meeting app", selection: $controller.selectedProcessID) {
                        Text("Select meeting audio").tag(Optional<UInt32>.none)
                        ForEach(controller.processes) { process in
                            Text(process.displayName).tag(Optional(process.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(controller.isListening)

                    Button {
                        controller.refreshProcesses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh meeting audio sources")
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
    }

    private var dictationBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("Quick Dictation", systemImage: "mic.badge.plus")
                    .font(.headline)
                Circle()
                    .fill(dictationColor)
                    .frame(width: 8, height: 8)
                Text(controller.dictationPhase.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if controller.isDictating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text("Hold ⌘ + ⌥")
                    .font(.callout.monospaced().weight(.semibold))
                Button(
                    controller.dictationPermissions.allGranted
                        ? "Check Access"
                        : "Grant Access",
                    action: controller.requestDictationPermissions
                )
                Toggle(
                    "Screen preview",
                    isOn: Binding(
                        get: { controller.dictationPreviewEnabled },
                        set: controller.setDictationPreviewEnabled
                    )
                )
                .toggleStyle(.switch)
                .fixedSize()
                .help("Show a floating waveform and dictated-text preview near the bottom of the screen")
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { controller.dictationEnabled },
                        set: controller.setDictationEnabled
                    )
                )
                .toggleStyle(.switch)
                .fixedSize()
            }

            if controller.dictationEnabled {
                HStack(spacing: 10) {
                    Text(controller.microphoneName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    WaveformView(
                        samples: controller.dictationTelemetry.waveform,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(height: 24)
                    LevelBar(
                        label: "RMS",
                        value: controller.dictationTelemetry.rms,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(width: 150)
                    LevelBar(
                        label: "PEAK",
                        value: controller.dictationTelemetry.peak,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(width: 150)
                    Text("\(controller.dictationTelemetry.packets) packets")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
            }

            if let detail = controller.dictationPhase.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else if !controller.dictationPermissions.allGranted {
                Text("\(controller.dictationPermissions.detail) Grant access in System Settings, then quit and reopen PUnderclass.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !controller.lastDictation.isEmpty {
                Text("Last: \(controller.lastDictation)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else {
                Text("Keep both modifiers held while speaking; release either one to transcribe and paste into the focused app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            controller.isDictating
                ? Color.red.opacity(0.10)
                : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            if controller.isDictating {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.red.opacity(0.75), lineWidth: 2)
            }
        }
    }

    private var dictationColor: Color {
        switch controller.dictationPhase {
        case .off:
            .secondary
        case .needsPermission, .preparing, .transcribing:
            .orange
        case .ready:
            .green
        case .recording:
            .red
        case .failed:
            .orange
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
                HStack {
                    SecureField("OpenAI API key", text: $controller.apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save to Keychain", action: controller.saveAPIKey)
                    if !controller.keyStatus.isEmpty {
                        Text(controller.keyStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

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
                    TextField("Languages, e.g. en, ja", text: $controller.languagesText)
                        .textFieldStyle(.roundedBorder)
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
                Text("Prototype security: the long-lived key stays in this Mac’s Keychain. Use an internal short-lived-token broker before deployment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            Label("Context, accuracy and API", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var selectedProcessName: String {
        controller.processes.first(where: { $0.id == controller.selectedProcessID })?.name
            ?? "No meeting app selected"
    }
}

private struct ModelChoiceButton: View {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
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
        .accessibilityLabel("Final transcript: \(engine.title), \(engine.modelName)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .help(isDisabled ? "Stop listening before changing the final model." : engine.purpose)
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

private struct LevelBar: View {
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

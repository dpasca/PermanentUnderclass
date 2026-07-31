import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: MeetingController
    @State private var contextExpanded = false

    var body: some View {
        VStack(spacing: 16) {
            header
            setupBar
            dictationBar

            if let error = controller.errorMessage {
                errorBanner(error)
            }

            HStack(spacing: 16) {
                TrackCard(
                    title: "YOU",
                    subtitle: controller.microphoneName,
                    color: .blue,
                    state: controller.localTrack
                )
                TrackCard(
                    title: "OTHER",
                    subtitle: selectedProcessName,
                    color: .purple,
                    state: controller.remoteTrack
                )
            }

            transcriptPanel
            contextPanel
        }
        .padding(20)
        .frame(minWidth: 1_000, minHeight: 720)
        .onAppear {
            contextExpanded = controller.apiKeyDraft.isEmpty
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            controller.refreshDictationPermissions()
            controller.refreshProcesses()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Meeting Copilot")
                    .font(.system(size: 26, weight: .semibold))
                Text(controller.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("FINAL")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            SocketBadge(state: controller.refinementState, color: .green)
            Label("HEADPHONES", systemImage: "headphones")
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

    private var setupBar: some View {
        HStack(spacing: 10) {
            Text("Meeting app")
                .font(.callout.weight(.medium))
            Picker("Meeting app", selection: $controller.selectedProcessID) {
                Text("Select an audio process").tag(Optional<UInt32>.none)
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
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(controller.isListening)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var dictationBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("Quick Dictation", systemImage: "keyboard.badge.ellipsis")
                    .font(.headline)
                Circle()
                    .fill(dictationColor)
                    .frame(width: 8, height: 8)
                Text(controller.dictationPhase.label)
                    .font(.body)
                    .foregroundStyle(.secondary)
                if controller.isDictating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text("Hold ⌘ + ⌥")
                    .font(.body.monospaced().weight(.semibold))
                Button(
                    controller.dictationPermissions.allGranted
                        ? "Check Access"
                        : "Grant Access",
                    action: controller.requestDictationPermissions
                )
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
                HStack(spacing: 12) {
                    Text(controller.microphoneName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    WaveformView(
                        samples: controller.dictationTelemetry.waveform,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(height: 28)
                    LevelBar(
                        label: "RMS",
                        value: controller.dictationTelemetry.rms,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(width: 170)
                    LevelBar(
                        label: "PEAK",
                        value: controller.dictationTelemetry.peak,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(width: 170)
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
                Text("\(controller.dictationPermissions.detail) Grant access in System Settings, then quit and reopen Meeting Copilot.")
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
        .padding(12)
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
                    Picker("Final transcript", selection: $controller.refinementEngine) {
                        ForEach(TranscriptRefinementEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .frame(width: 230)
                    .disabled(controller.isListening)
                    Button("Apply Context", action: controller.applyContext)
                }
                Text("For specialized discussions, add exact vocabulary before the meeting—for example CUDA, thread block, and warp. Medium is the recommended starting point for balanced accuracy and latency.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(controller.refinementEngine.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if controller.refinementEngine == .localParakeet {
                    Text("The first local run downloads and compiles the Parakeet model, then keeps it warm inside Meeting Copilot. No MacParakeet app or process is used.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Prototype security: the long-lived key stays in this Mac’s Keychain. Use an internal short-lived-token broker before deployment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            Label("Transcription context and API", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var selectedProcessName: String {
        controller.processes.first(where: { $0.id == controller.selectedProcessID })?.name
            ?? "Selected app output"
    }
}

private struct TrackCard: View {
    let title: String
    let subtitle: String
    let color: Color
    let state: TrackViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.bold())
                        .foregroundStyle(color)
                    Text(subtitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                SocketBadge(state: state.socket, color: color)
            }

            WaveformView(samples: state.telemetry.waveform, color: color)
                .frame(height: 64)

            HStack(spacing: 10) {
                LevelBar(label: "RMS", value: state.telemetry.rms, color: color)
                LevelBar(label: "PEAK", value: state.telemetry.peak, color: color)
            }

            Text(state.partialTranscript.isEmpty ? "Waiting for speech…" : state.partialTranscript)
                .font(.body)
                .foregroundStyle(state.partialTranscript.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                .textSelection(.enabled)

            HStack {
                Text(state.telemetry.sourceFormat)
                Spacer()
                Text("\(state.telemetry.packets) packets")
                Text("·")
                Text("\(state.telemetry.droppedBuffers) dropped")
                    .foregroundStyle(state.telemetry.droppedBuffers > 0 ? .orange : .secondary)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WaveformView: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: middle))
            baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

            guard samples.count > 1 else { return }
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let x = CGFloat(index) / CGFloat(samples.count - 1) * size.width
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

import SwiftUI

struct MicrophoneInputTestButton: View {
    @ObservedObject var controller: MeetingController
    @State private var isPresented = false

    var body: some View {
        Button("Test Microphone…", systemImage: "waveform") {
            isPresented = true
        }
        .disabled(
            controller.isListening || controller.isDictating
                || controller.syntheticInterviewState.isActive
        )
        .sheet(isPresented: $isPresented) {
            MicrophoneInputTestView(controller: controller)
        }
    }
}

struct MicrophoneInputTestView: View {
    @ObservedObject var controller: MeetingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test Microphone")
                .font(.title2.bold())
            Text("Speak normally and watch the input level. Audio stays on this Mac and is discarded after the test.")
                .foregroundStyle(.secondary)

            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                let state = controller.microphoneTestState
                let health = state.health(at: timeline.date)
                VStack(alignment: .leading, spacing: 12) {
                    AudioDeviceRow(
                        title: "MICROPHONE INPUT",
                        name: state.microphoneName,
                        systemImage: "mic.fill",
                        health: health,
                        devices: controller.inputDevices,
                        selectedDeviceID: controller.selectedInputDeviceID,
                        onSelect: controller.selectInputDevice
                    )
                    WaveformView(
                        samples: state.telemetry.waveform,
                        color: .accentColor,
                        normalization: .adaptive
                    )
                    .frame(height: 70)
                    ProgressView(
                        "Input level",
                        value: Double(min(1, state.telemetry.rms * 8))
                    )
                    .accessibilityValue(levelDescription(state.telemetry.rms))
                    HStack {
                        Text(levelDescription(state.telemetry.rms))
                        Spacer()
                        Text("\(state.telemetry.packets) audio packets")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Text(statusMessage(state: state, health: health))
                        .foregroundStyle(
                            state.errorMessage != nil || health == .noSignal
                                || health == .noData ? .orange : .primary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            HStack {
                Button("Microphone Settings…") {
                    HoldToDictateService.openMicrophoneSettings()
                }
                Spacer()
                if controller.microphoneTestState.isRunning {
                    Button("Stop Test", action: controller.stopMicrophoneTest)
                } else {
                    Button("Test Again", action: controller.startMicrophoneTest)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 530)
        .onAppear(perform: controller.startMicrophoneTest)
        .onDisappear {
            controller.stopMicrophoneTest()
            controller.refreshDictationPermissions()
        }
    }

    private func levelDescription(_ rms: Float) -> String {
        guard rms > 0 else { return "No input signal" }
        return String(format: "%.1f dBFS", 20 * log10(rms))
    }

    private func statusMessage(
        state: MicrophoneInputTestState,
        health: AudioStreamHealth
    ) -> String {
        if let error = state.errorMessage { return error }
        guard state.isRunning else { return "Test stopped." }
        switch health {
        case .noSignal:
            return "The microphone is sending only silence. Check its mute switch and input volume. For a Bluetooth headset, reconnect it or try the built-in microphone using the input menu above."
        case .healthy where state.telemetry.lastSignalAt != nil:
            return "Input signal detected. The level should move as you speak."
        case .healthy:
            return "Audio is arriving. Speak to check the input signal…"
        default:
            return health.detail
        }
    }
}

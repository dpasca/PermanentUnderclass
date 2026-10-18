import AVFAudio
import Foundation

protocol MicrophoneInputCapturing: AnyObject {
    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onFirstBuffer: @escaping () -> Void,
        onStall: @escaping () -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    )
    func stop()
}

extension CaptureSessionMicrophoneCapture: MicrophoneInputCapturing {}

struct MicrophoneInputTestState: Equatable {
    var isRunning = false
    var microphoneName = "Selected microphone"
    var telemetry = TrackTelemetry()
    var errorMessage: String?

    func health(at now: Date = Date()) -> AudioStreamHealth {
        guard errorMessage == nil else { return .noData }
        return AudioStreamHealth.evaluate(
            sourceAvailable: true,
            isMonitoring: isRunning,
            telemetry: telemetry,
            now: now,
            detectDigitalSilence: true,
            signalStaleAfter: 2
        )
    }
}

/// Exercises the same capture and conversion path as dictation without loading
/// a speech model, monitoring the keyboard, saving audio, or sending it online.
final class MicrophoneInputTest {
    private let makeCapture: () -> any MicrophoneInputCapturing
    private let onUpdate: (MicrophoneInputTestState) -> Void
    private var capture: (any MicrophoneInputCapturing)?
    private var pipeline: AudioTrackPipeline?
    private var generation: UUID?
    private(set) var state = MicrophoneInputTestState()

    init(
        makeCapture: @escaping () -> any MicrophoneInputCapturing = {
            CaptureSessionMicrophoneCapture()
        },
        onUpdate: @escaping (MicrophoneInputTestState) -> Void
    ) {
        self.makeCapture = makeCapture
        self.onUpdate = onUpdate
    }

    func start(microphoneName: String) {
        stop()
        let generation = UUID()
        self.generation = generation
        state = MicrophoneInputTestState(
            isRunning: true,
            microphoneName: microphoneName,
            telemetry: TrackTelemetry(monitoringStartedAt: Date())
        )
        onUpdate(state)

        let pipeline = AudioTrackPipeline(
            label: "PUnderclass.Audio.MicrophoneTest",
            onChunk: { _ in },
            onTelemetry: { [weak self] telemetry in
                guard let self, self.generation == generation else { return }
                self.state.telemetry = telemetry
                self.onUpdate(self.state)
            }
        )
        self.pipeline = pipeline
        let capture = makeCapture()
        self.capture = capture
        capture.start(
            onBuffer: { pipeline.submit($0) },
            onFirstBuffer: {},
            onStall: { [weak self] in
                DispatchQueue.main.async {
                    self?.fail(
                        "No audio arrived from the microphone. Reconnect it or choose another input, then test again.",
                        generation: generation
                    )
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    switch result {
                    case let .success(name):
                        self.state.microphoneName = name
                        self.onUpdate(self.state)
                    case let .failure(error):
                        self.fail(error.localizedDescription, generation: generation)
                    }
                }
            }
        )
    }

    func stop() {
        generation = nil
        capture?.stop()
        capture = nil
        pipeline?.finish()
        pipeline = nil
        guard state.isRunning else { return }
        state.isRunning = false
        onUpdate(state)
    }

    private func fail(_ message: String, generation: UUID) {
        guard self.generation == generation else { return }
        stop()
        state.errorMessage = message
        onUpdate(state)
    }

    deinit {
        capture?.stop()
    }
}

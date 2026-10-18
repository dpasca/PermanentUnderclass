import AVFAudio
import XCTest
@testable import PUnderclass

final class MicrophoneInputTestTests: XCTestCase {
    func testDigitalSilenceIsDifferentFromMissingAudioAndRecoversWithSignal() {
        let now = Date(timeIntervalSince1970: 100)
        var state = MicrophoneInputTestState(
            isRunning: true,
            telemetry: TrackTelemetry(monitoringStartedAt: now.addingTimeInterval(-3))
        )
        XCTAssertEqual(state.health(at: now), .noData)

        state.telemetry.packets = 100
        state.telemetry.lastPacketAt = now
        XCTAssertEqual(state.health(at: now), .noSignal)

        state.telemetry.lastSignalAt = now
        XCTAssertEqual(state.health(at: now), .healthy)

        state.isRunning = false
        XCTAssertEqual(state.health(at: now), .ready)
    }

    @MainActor
    func testCaptureExercisesDictationConversionAndDistinguishesZeroSamples() async throws {
        let capture = TestMicrophoneCapture()
        let silence = expectation(description: "Converted silent audio")
        let signal = expectation(description: "Converted microphone signal")
        var receivedSilence = false
        var receivedSignal = false
        let test = MicrophoneInputTest(makeCapture: { capture }) { state in
            if state.telemetry.packets > 0, !receivedSilence {
                receivedSilence = true
                XCTAssertEqual(state.telemetry.peak, 0)
                XCTAssertNil(state.telemetry.lastSignalAt)
                silence.fulfill()
            }
            if state.telemetry.peak > 0, !receivedSignal {
                receivedSignal = true
                signal.fulfill()
            }
        }
        test.start(microphoneName: "Test input")
        XCTAssertTrue(test.state.isRunning)
        XCTAssertEqual(test.state.health(), .checking)
        capture.completion?(.success("Actual input"))

        // The real pipeline publishes at 50 ms intervals.
        try await Task.sleep(for: .milliseconds(70))
        capture.onBuffer?(try audioBuffer(amplitude: 0))
        await fulfillment(of: [silence], timeout: 2)
        XCTAssertEqual(test.state.microphoneName, "Actual input")

        try await Task.sleep(for: .milliseconds(70))
        capture.onBuffer?(try audioBuffer(amplitude: 0.25))
        await fulfillment(of: [signal], timeout: 2)
        XCTAssertEqual(test.state.health(), .healthy)
        XCTAssertGreaterThan(test.state.telemetry.bytes, 0)
        test.stop()
        XCTAssertFalse(test.state.isRunning)
        XCTAssertTrue(capture.wasStopped)
    }

    @MainActor
    func testDeniedPermissionStopsTestAndPreservesActionableError() async {
        let capture = TestMicrophoneCapture()
        let failure = expectation(description: "Permission failure")
        let test = MicrophoneInputTest(makeCapture: { capture }) { state in
            if state.errorMessage != nil { failure.fulfill() }
        }
        test.start(microphoneName: "Test input")
        capture.completion?(.failure(PUnderclassError.audio("Enable microphone access.")))
        await fulfillment(of: [failure], timeout: 2)
        XCTAssertFalse(test.state.isRunning)
        XCTAssertTrue(capture.wasStopped)
        XCTAssertEqual(test.state.errorMessage, "Enable microphone access.")
        XCTAssertEqual(test.state.health(), .noData)
    }

    @MainActor
    func testStalledCaptureStopsAndOffersInputRecovery() async {
        let capture = TestMicrophoneCapture()
        let failure = expectation(description: "Missing audio failure")
        let test = MicrophoneInputTest(makeCapture: { capture }) { state in
            if state.errorMessage != nil { failure.fulfill() }
        }
        test.start(microphoneName: "Test input")
        capture.onStall?()
        await fulfillment(of: [failure], timeout: 2)
        XCTAssertFalse(test.state.isRunning)
        XCTAssertTrue(capture.wasStopped)
        XCTAssertTrue(test.state.errorMessage?.contains("choose another input") == true)
    }

    @MainActor
    func testChangingInputIgnoresPreviousCaptureCallbacks() async {
        let first = TestMicrophoneCapture()
        let second = TestMicrophoneCapture()
        var captures = [first, second]
        let started = expectation(description: "Replacement input started")
        let test = MicrophoneInputTest(makeCapture: { captures.removeFirst() }) { state in
            if state.isRunning, state.microphoneName == "Actual replacement" {
                started.fulfill()
            }
        }
        test.start(microphoneName: "First input")
        test.start(microphoneName: "Replacement input")
        XCTAssertTrue(first.wasStopped)

        first.completion?(.failure(PUnderclassError.audio("Old permission failure")))
        first.onStall?()
        second.completion?(.success("Actual replacement"))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(test.state.isRunning)
        XCTAssertNil(test.state.errorMessage)
        XCTAssertFalse(second.wasStopped)
        test.stop()
    }

    @MainActor
    func testClosingDuringStartupIgnoresLatePermissionDecision() async {
        let capture = TestMicrophoneCapture()
        let drained = expectation(description: "Main queue callbacks drained")
        let test = MicrophoneInputTest(makeCapture: { capture }, onUpdate: { _ in })
        test.start(microphoneName: "Test input")
        test.stop()
        capture.completion?(.success("Late input"))
        capture.onStall?()
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertFalse(test.state.isRunning)
        XCTAssertEqual(test.state.microphoneName, "Test input")
        XCTAssertNil(test.state.errorMessage)
    }

    private func audioBuffer(amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        buffer.frameLength = 2_400
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }
        return buffer
    }
}

private final class TestMicrophoneCapture: MicrophoneInputCapturing {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onStall: (() -> Void)?
    var completion: ((Result<String, Error>) -> Void)?
    var wasStopped = false

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onFirstBuffer: @escaping () -> Void,
        onStall: @escaping () -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        self.onBuffer = onBuffer
        self.onStall = onStall
        self.completion = completion
    }

    func stop() {
        wasStopped = true
    }
}

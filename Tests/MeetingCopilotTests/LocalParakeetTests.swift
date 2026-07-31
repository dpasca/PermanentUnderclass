import AVFAudio
import Foundation
import XCTest
@testable import MeetingCopilot

final class LocalParakeetTests: XCTestCase {
    func testSyntheticTechnicalSpeechRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["RUN_PARAKEET_LIVE_TESTS"] == "1" else {
            throw XCTSkip(
                "Set RUN_PARAKEET_LIVE_TESTS=1 to run the local model integration test."
            )
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-copilot-parakeet-\(UUID().uuidString).aiff")
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let speechProcess = Process()
        speechProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speechProcess.arguments = [
            "-o", audioURL.path,
            """
            Hello, hello, how do you do? What kind of API are we using here? \
            CUDA has grids and then blocks, and under blocks are threads, \
            which are organized as warps.
            """
        ]
        try speechProcess.run()
        speechProcess.waitUntilExit()
        XCTAssertEqual(speechProcess.terminationStatus, 0)

        let file = try AVAudioFile(forReading: audioURL)
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: source)

        let lock = NSLock()
        var pcm16Audio = Data()
        let pipeline = AudioTrackPipeline(
            label: "MeetingCopilotTests.ParakeetAudio",
            onChunk: { chunk in
                lock.lock()
                pcm16Audio.append(chunk)
                lock.unlock()
            },
            onTelemetry: { _ in }
        )
        pipeline.submit(source)
        pipeline.finish()

        lock.lock()
        let capturedAudio = pcm16Audio
        lock.unlock()
        XCTAssertFalse(capturedAudio.isEmpty)

        let connected = expectation(description: "Local Parakeet model prepared")
        let refined = expectation(description: "Local Parakeet transcript returned")
        var transcript = ""
        let client = ParakeetRefinementClient(
            onState: { state in
                if state == .connected {
                    connected.fulfill()
                }
                if case let .failed(message) = state {
                    XCTFail("Local Parakeet preparation failed: \(message)")
                }
            },
            onRefined: { _, text in
                transcript = text
                refined.fulfill()
            },
            onFailure: { _, message in
                XCTFail("Local Parakeet transcription failed: \(message)")
            }
        )

        client.connect()
        client.refine(
            RealtimeRefinementRequest(
                transcriptID: "local-test",
                speaker: .you,
                pcm16Audio: capturedAudio,
                context: TranscriptionContext(
                    prompt: "A technical software discussion.",
                    keywords: ["CUDA", "grid", "thread block", "warp"],
                    languages: ["en"],
                    delay: .medium
                ),
                recentTranscript: ""
            )
        )

        wait(for: [connected, refined], timeout: 300)
        client.disconnect()

        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("CUDA"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("grids"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("blocks"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("threads"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("warps"))
    }
}

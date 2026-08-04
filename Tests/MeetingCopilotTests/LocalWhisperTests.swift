import AVFAudio
import Foundation
import XCTest
@testable import MeetingCopilot

final class LocalWhisperTests: XCTestCase {
    func testSyntheticTechnicalSpeechRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["RUN_WHISPER_LIVE_TESTS"] == "1" else {
            throw XCTSkip(
                "Set RUN_WHISPER_LIVE_TESTS=1 to run the local Whisper integration test."
            )
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-copilot-whisper-\(UUID().uuidString).aiff")
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let speechProcess = Process()
        speechProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speechProcess.arguments = [
            "-o", audioURL.path,
            """
            Um, we are debugging WhisperKit and AV Audio Converter. The CUDA kernel uses \
            thread blocks, warps, and a Core ML fallback. Uh, keep the API identifier exact.
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
        let audioPipeline = AudioTrackPipeline(
            label: "MeetingCopilotTests.WhisperAudio",
            onChunk: { chunk in
                lock.withLock {
                    pcm16Audio.append(chunk)
                }
            },
            onTelemetry: { _ in }
        )
        audioPipeline.submit(source)
        audioPipeline.finish()

        let capturedAudio = lock.withLock { pcm16Audio }
        XCTAssertGreaterThan(capturedAudio.count, 48_000)
        print("Local Whisper captured PCM16 bytes: \(capturedAudio.count)")
        let whisperSamples = try WhisperTranscriber.audioSamples(
            from: capturedAudio
        )
        let peak = whisperSamples.map(abs).max() ?? 0
        let rms = sqrt(
            whisperSamples.reduce(0) { $0 + $1 * $1 }
                / Float(max(1, whisperSamples.count))
        )
        print(
            "Local Whisper samples: \(whisperSamples.count), RMS: \(rms), peak: \(peak)"
        )
        XCTAssertGreaterThan(whisperSamples.count, 16_000)
        XCTAssertGreaterThan(rms, 0.001)

        let request = RealtimeRefinementRequest(
            transcriptID: "local-whisper-test",
            speaker: .you,
            pcm16Audio: capturedAudio,
            context: TranscriptionContext(
                prompt: "A multilingual technical software discussion.",
                keywords: [
                    "WhisperKit",
                    "AVAudioConverter",
                    "CUDA",
                    "thread block",
                    "warp",
                    "Core ML"
                ],
                languages: ["en"],
                delay: .medium,
                outputStyle: .cleanDictation
            ),
            recentTranscript: ""
        )
        let preparationStartedAt = Date()
        try await WhisperTranscriber.shared.prepare()
        print(
            "Local Whisper preparation: \(Date().timeIntervalSince(preparationStartedAt))s"
        )
        let transcriptionStartedAt = Date()
        let transcript = try await WhisperTranscriber.shared.transcribe(request)

        print(
            "Local Whisper transcription: \(Date().timeIntervalSince(transcriptionStartedAt))s"
        )
        print("Local Whisper transcript: \(transcript)")
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("WhisperKit"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("CUDA"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("thread blocks"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("warps"))
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("Core ML"))
    }
}

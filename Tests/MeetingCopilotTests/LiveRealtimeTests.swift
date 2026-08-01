import AVFAudio
import Foundation
import XCTest
@testable import MeetingCopilot

final class LiveRealtimeTests: XCTestCase {
    func testSyntheticSpeechRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["RUN_OPENAI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_OPENAI_LIVE_TESTS=1 to run the network integration test.")
        }
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-copilot-\(UUID().uuidString).aiff")
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let speechProcess = Process()
        speechProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speechProcess.arguments = [
            "-o", audioURL.path,
            "PUnderclass realtime transcription test."
        ]
        try speechProcess.run()
        speechProcess.waitUntilExit()
        XCTAssertEqual(speechProcess.terminationStatus, 0)

        let file = try AVAudioFile(forReading: audioURL)
        let speech = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: speech)

        let silence = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * 4)
            )
        )
        silence.frameLength = silence.frameCapacity
        let silenceBuffers = UnsafeMutableAudioBufferListPointer(
            silence.mutableAudioBufferList
        )
        for audioBuffer in silenceBuffers {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }

        let connected = expectation(description: "Realtime WebSocket connected")
        let transcribed = expectation(description: "Synthetic speech transcribed")
        let refinerConnected = expectation(description: "Refinement WebSocket connected")
        let refined = expectation(description: "Synthetic speech refined")
        var finalTranscript = ""
        var refinedTranscript = ""
        var didSendAudio = false
        var didReportRefinerConnection = false

        let context = TranscriptionContext(
            prompt: "A synthetic integration test.",
            keywords: ["PUnderclass"],
            languages: ["en"],
            delay: .low
        )
        var client: RealtimeTranscriptionClient!
        var refiner: RealtimeRefinementClient!
        let pipeline = AudioTrackPipeline(
            label: "MeetingCopilotTests.LiveAudio",
            onChunk: { data in
                client.sendAudio(data)
            },
            onTelemetry: { _ in }
        )
        client = RealtimeTranscriptionClient(
            apiKey: key,
            context: context,
            label: "LiveTest",
            onState: { state in
                if state == .connected, !didSendAudio {
                    didSendAudio = true
                    connected.fulfill()
                    pipeline.submit(speech)
                    pipeline.submit(silence)
                }
                if case let .failed(message) = state {
                    XCTFail("Realtime connection failed: \(message)")
                }
            },
            onPartial: { _, _ in },
            onFinal: { itemID, text, _, _, pcm16Audio in
                finalTranscript = text
                transcribed.fulfill()
                XCTAssertFalse(pcm16Audio.isEmpty)
                refiner.refine(
                    RealtimeRefinementRequest(
                        transcriptID: itemID,
                        speaker: .you,
                        pcm16Audio: pcm16Audio,
                        context: context,
                        recentTranscript: ""
                    )
                )
            }
        )
        refiner = RealtimeRefinementClient(
            apiKey: key,
            onState: { state in
                if state == .connected, !didReportRefinerConnection {
                    didReportRefinerConnection = true
                    refinerConnected.fulfill()
                }
                if case let .failed(message) = state {
                    XCTFail("Refinement connection failed: \(message)")
                }
            },
            onRefined: { _, text in
                refinedTranscript = text
                refined.fulfill()
            },
            onFailure: { _, message in
                XCTFail("Refinement failed: \(message)")
            }
        )

        refiner.connect()
        client.connect()
        wait(
            for: [connected, transcribed, refinerConnected, refined],
            timeout: 45
        )
        pipeline.finish()
        client.disconnect()
        refiner.disconnect()
        XCTAssertFalse(finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(refinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

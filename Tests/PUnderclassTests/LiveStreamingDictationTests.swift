import AVFAudio
import Foundation
import XCTest
@testable import PUnderclass

/// Exercises the streamed dictation path against the real API. This is the only
/// place the 16 kHz wire format, the mid-recording segment commits, and the
/// transcript reassembly are checked end to end.
final class LiveStreamingDictationTests: XCTestCase {
    func testStreamedDictationTranscribesWhileRecording() throws {
        guard ProcessInfo.processInfo.environment["RUN_OPENAI_LIVE_TESTS"] == "1"
        else {
            throw XCTSkip(
                "Set RUN_OPENAI_LIVE_TESTS=1 to run the network integration test."
            )
        }
        let key = try XCTUnwrap(
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        )

        // Two spoken phrases separated by silence, so the segment scheduler has
        // a real pause to cut on rather than only hitting the length ceiling.
        let firstPhrase = try Self.synthesizedPCM16(
            "The quick brown fox jumps over the lazy dog."
        )
        let secondPhrase = try Self.synthesizedPCM16(
            "Pack my box with five dozen liquor jugs."
        )
        let pause = Data(
            count: QuickDictationStreamPolicy.captureBytesPerSecond
        )

        let connected = expectation(description: "Transcription socket connected")
        let completed = expectation(description: "Streamed dictation completed")
        var partials: [String] = []
        var finalText = ""
        var failure: String?
        var didStart = false

        var client: RealtimeRefinementClient!
        client = RealtimeRefinementClient(
            apiKey: key,
            label: "LiveStreamTest",
            onState: { state in
                if state == .connected, !didStart {
                    didStart = true
                    connected.fulfill()
                }
                if case let .failed(message) = state {
                    failure = message
                }
            },
            onRefined: { _, _ in },
            onFailure: { _, message in
                failure = message
            },
            onStreamPartial: { _, text in
                partials.append(text)
            },
            onStreamCompleted: { _, text in
                finalText = text
                completed.fulfill()
            },
            onStreamFailed: { _, message in
                failure = message
                completed.fulfill()
            }
        )

        client.connect()
        wait(for: [connected], timeout: 30)

        let streamID = "dictation-live-\(UUID().uuidString)"
        client.beginStream(
            DictationStreamStart(
                streamID: streamID,
                context: TranscriptionContext(
                    prompt: "A synthetic integration test.",
                    keywords: [],
                    languages: ["en"],
                    delay: .medium
                )
            )
        )

        // Feed the audio in real-world sized chunks rather than one blob.
        Self.feed(firstPhrase, to: client, streamID: streamID)
        Self.feed(pause, to: client, streamID: streamID)
        client.commitStreamSegment(streamID: streamID)
        Self.feed(secondPhrase, to: client, streamID: streamID)
        client.finishStream(streamID: streamID)

        wait(for: [completed], timeout: 60)
        client.disconnect()

        XCTAssertNil(failure)
        let transcript = finalText.lowercased()
        XCTAssertTrue(
            transcript.contains("quick brown fox"),
            "First segment missing from transcript: \(finalText)"
        )
        XCTAssertTrue(
            transcript.contains("liquor jugs"),
            "Second segment missing from transcript: \(finalText)"
        )
        // Live text must arrive before the dictation ends, otherwise the
        // overlay has nothing to show while the user is still speaking.
        XCTAssertFalse(partials.isEmpty)
    }

    private static func feed(
        _ pcm16: Data,
        to client: RealtimeRefinementClient,
        streamID: String
    ) {
        // ~100 ms of 24 kHz capture audio per call.
        let chunkBytes = QuickDictationStreamPolicy.captureBytesPerSecond / 10
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + chunkBytes, pcm16.count)
            client.appendStream(
                streamID: streamID,
                pcm16Audio: pcm16.subdata(in: offset..<end)
            )
            offset = end
        }
    }

    /// Renders text to 24 kHz mono PCM16, matching what capture produces.
    private static func synthesizedPCM16(_ text: String) throws -> Data {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("punderclass-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let speech = Process()
        speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speech.arguments = ["-o", audioURL.path, text]
        try speech.run()
        speech.waitUntilExit()
        guard speech.terminationStatus == 0 else {
            throw PUnderclassError.audio("say failed")
        }

        let file = try AVAudioFile(forReading: audioURL)
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: source)

        let targetFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(RealtimeRefinementClient.captureSampleRate),
                channels: 1,
                interleaved: true
            )
        )
        let converter = try XCTUnwrap(
            AVAudioConverter(from: file.processingFormat, to: targetFormat)
        )
        let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
        let converted = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(source.frameLength) * ratio + 1_024
                )
            )
        )
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }

        let channel = try XCTUnwrap(converted.int16ChannelData)
        return Data(
            bytes: channel[0],
            count: Int(converted.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

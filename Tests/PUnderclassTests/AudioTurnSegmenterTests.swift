import Foundation
import XCTest
@testable import PUnderclass

final class AudioTurnSegmenterTests: XCTestCase {
    func testOrdinaryPauseDoesNotSplitOneSpokenTurn() {
        var segmenter = AudioTurnSegmenter()
        var now = Date(timeIntervalSince1970: 1_000)
        var completedTurns: [SegmentedAudioTurn] = []

        func append(_ chunk: Data) -> AudioTurnSegmentationResult {
            now = now.addingTimeInterval(0.02)
            let result = segmenter.append(chunk, receivedAt: now)
            if let completedTurn = result.completedTurn {
                completedTurns.append(completedTurn)
            }
            return result
        }

        for _ in 0..<15 {
            _ = append(pcmChunk(amplitude: 0))
        }
        for _ in 0..<8 {
            _ = append(pcmChunk(amplitude: 6_000))
        }

        var earlyBridgePauseEvents = 0
        var assistantPauseEvents = 0
        for _ in 0..<100 {
            let result = append(pcmChunk(amplitude: 0))
            if result.earlyBridgePauseAt != nil {
                earlyBridgePauseEvents += 1
            }
            if result.speechPauseAt != nil {
                assistantPauseEvents += 1
            }
        }
        XCTAssertTrue(completedTurns.isEmpty)
        XCTAssertEqual(earlyBridgePauseEvents, 1)
        XCTAssertEqual(assistantPauseEvents, 1)

        for _ in 0..<8 {
            _ = append(pcmChunk(amplitude: 6_000))
        }
        for _ in 0..<AudioTurnSegmenter.speechEndSilenceChunkCount {
            _ = append(pcmChunk(amplitude: 0))
        }

        XCTAssertEqual(completedTurns.count, 1)
        XCTAssertFalse(completedTurns[0].pcm16Audio.isEmpty)
        XCTAssertGreaterThan(
            completedTurns[0].capturedByteCount,
            completedTurns[0].pcm16Audio.count
        )
    }

    func testManualFinishEmitsThePendingTurnWithoutWaitingForSilence() {
        var segmenter = AudioTurnSegmenter()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let speech = pcmChunk(amplitude: 7_000)

        _ = segmenter.append(speech, receivedAt: startedAt)
        _ = segmenter.append(
            speech,
            receivedAt: startedAt.addingTimeInterval(0.02)
        )
        let endedAt = startedAt.addingTimeInterval(0.5)
        let turn = segmenter.finish(at: endedAt)

        XCTAssertNotNil(turn)
        XCTAssertEqual(turn?.endedAt, endedAt)
        XCTAssertFalse(turn?.pcm16Audio.isEmpty ?? true)
        XCTAssertNil(segmenter.finish(at: endedAt))
    }

    func testSilenceAloneDoesNotCreateATurn() {
        var segmenter = AudioTurnSegmenter()
        let silence = pcmChunk(amplitude: 0)
        let now = Date(timeIntervalSince1970: 3_000)

        for index in 0..<300 {
            let result = segmenter.append(
                silence,
                receivedAt: now.addingTimeInterval(Double(index) * 0.02)
            )
            XCTAssertNil(result.completedTurn)
        }
        XCTAssertNil(segmenter.finish(at: now.addingTimeInterval(10)))
    }

    func testLocalClientProducesATurnWithoutAnAPIKeyOrNetworkSession() {
        let connected = expectation(description: "Local client connected")
        let transcribedTurn = expectation(description: "Local turn emitted")
        var capturedAudio = Data()
        let client = LocalTurnTranscriptionClient(
            label: "Test",
            onState: { state in
                if state == .connected {
                    connected.fulfill()
                }
            },
            onTurn: { _, _, _, pcm16Audio in
                capturedAudio = pcm16Audio
                transcribedTurn.fulfill()
            }
        )

        client.connect()
        wait(for: [connected], timeout: 1)
        client.sendAudio(pcmChunk(amplitude: 7_000))
        client.sendAudio(pcmChunk(amplitude: 7_000))
        client.commitPendingAudio()
        wait(for: [transcribedTurn], timeout: 1)

        XCTAssertFalse(capturedAudio.isEmpty)
        client.disconnect()
    }

    private func pcmChunk(amplitude: Int16) -> Data {
        let samples = [Int16](repeating: amplitude, count: 480)
        return samples.withUnsafeBytes { Data($0) }
    }
}

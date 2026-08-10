import Foundation

/// The audio-facing part of Meeting and Interview capture. A hosted client can
/// stream words while someone speaks; the local implementation emits complete
/// buffered turns for Whisper or Parakeet instead.
protocol MeetingAudioTranscribing: AnyObject {
    func connect()
    func sendAudio(_ pcm16: Data)
    func updateContext(_ context: TranscriptionContext)
    func commitPendingAudio()
    func disconnect()
}

struct SegmentedAudioTurn {
    let startedAt: Date
    let endedAt: Date
    let pcm16Audio: Data
    let capturedByteCount: Int
}

struct AudioTurnSegmentationResult {
    var streamingChunks: [Data] = []
    var speechPauseAt: Date?
    var completedTurn: SegmentedAudioTurn?
}

/// Provider-neutral voice activity and turn buffering shared by the hosted
/// streaming client and fully local meeting capture. Keeping one segmenter is
/// important: switching away from OpenAI must not bring back shorter pause
/// boundaries and the spurious punctuation they cause.
struct AudioTurnSegmenter {
    static let assistantPauseSilenceChunkCount = 40
    static let speechEndSilenceChunkCount = 150

    private static let preRollChunkCount = 15
    private static let speechOnsetChunkCount = 2
    private static let retainedPostRollChunkCount = 10
    private static let bytesPerChunk = 960

    private var preRoll: [Data] = []
    private var consecutiveVoicedChunks = 0
    private var silentChunks = 0
    private var hasPublishedSpeechPause = false
    private var noiseFloor: Float = 0.001
    private var activeTurnStartedAt: Date?
    private var lastVoicedAt: Date?
    private var activeTurnAudio = Data()
    private var activeTurnLastVoicedByteCount = 0

    mutating func append(
        _ data: Data,
        receivedAt: Date
    ) -> AudioTurnSegmentationResult {
        var result = AudioTurnSegmentationResult()
        let rms = Self.rms(of: data)
        let threshold = max(0.004, noiseFloor * 3.5)
        let isVoiced = rms >= threshold

        if activeTurnStartedAt != nil {
            result.streamingChunks = [data]
            activeTurnAudio.append(data)
            if isVoiced {
                silentChunks = 0
                hasPublishedSpeechPause = false
                lastVoicedAt = receivedAt
                activeTurnLastVoicedByteCount = activeTurnAudio.count
            } else {
                silentChunks += 1
                if
                    silentChunks == Self.assistantPauseSilenceChunkCount,
                    !hasPublishedSpeechPause
                {
                    hasPublishedSpeechPause = true
                    result.speechPauseAt = lastVoicedAt ?? receivedAt
                }
                if silentChunks >= Self.speechEndSilenceChunkCount {
                    result.completedTurn = finishTurn(
                        at: lastVoicedAt ?? receivedAt
                    )
                }
            }
            return result
        }

        if !isVoiced {
            noiseFloor = noiseFloor * 0.98 + rms * 0.02
        }
        preRoll.append(data)
        if preRoll.count > Self.preRollChunkCount {
            preRoll.removeFirst(preRoll.count - Self.preRollChunkCount)
        }

        if isVoiced {
            consecutiveVoicedChunks += 1
        } else {
            consecutiveVoicedChunks = 0
        }

        guard consecutiveVoicedChunks >= Self.speechOnsetChunkCount else {
            return result
        }
        activeTurnStartedAt = receivedAt.addingTimeInterval(
            -Double(preRoll.count) * 0.02
        )
        lastVoicedAt = receivedAt
        silentChunks = 0
        hasPublishedSpeechPause = false
        activeTurnAudio.removeAll(keepingCapacity: true)
        result.streamingChunks = preRoll
        for bufferedChunk in preRoll {
            activeTurnAudio.append(bufferedChunk)
        }
        activeTurnLastVoicedByteCount = activeTurnAudio.count
        preRoll.removeAll(keepingCapacity: true)
        return result
    }

    mutating func finish(at endedAt: Date) -> SegmentedAudioTurn? {
        finishTurn(at: endedAt)
    }

    mutating func reset() {
        preRoll.removeAll(keepingCapacity: false)
        consecutiveVoicedChunks = 0
        silentChunks = 0
        hasPublishedSpeechPause = false
        noiseFloor = 0.001
        activeTurnStartedAt = nil
        lastVoicedAt = nil
        activeTurnAudio.removeAll(keepingCapacity: false)
        activeTurnLastVoicedByteCount = 0
    }

    private mutating func finishTurn(at endedAt: Date) -> SegmentedAudioTurn? {
        guard let startedAt = activeTurnStartedAt else { return nil }
        let retainedByteCount = min(
            activeTurnAudio.count,
            activeTurnLastVoicedByteCount
                + Self.retainedPostRollChunkCount * Self.bytesPerChunk
        )
        let turn = SegmentedAudioTurn(
            startedAt: startedAt,
            endedAt: endedAt,
            pcm16Audio: Data(activeTurnAudio.prefix(retainedByteCount)),
            capturedByteCount: activeTurnAudio.count
        )

        activeTurnStartedAt = nil
        lastVoicedAt = nil
        consecutiveVoicedChunks = 0
        silentChunks = 0
        hasPublishedSpeechPause = false
        activeTurnAudio.removeAll(keepingCapacity: true)
        activeTurnLastVoicedByteCount = 0
        preRoll.removeAll(keepingCapacity: true)
        return turn
    }

    private static func rms(of data: Data) -> Float {
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Double = 0
            for sample in samples {
                let value = Double(sample) / Double(Int16.max)
                sum += value * value
            }
            return Float(sqrt(sum / Double(samples.count)))
        }
    }
}

/// Captures the same speaker turns as the realtime client without opening a
/// network connection. The controller sends each emitted PCM turn directly to
/// the selected on-device transcription model.
final class LocalTurnTranscriptionClient: MeetingAudioTranscribing,
    @unchecked Sendable
{
    typealias StateHandler = (SocketState) -> Void
    typealias TurnHandler = (
        _ itemID: String,
        _ startedAt: Date,
        _ endedAt: Date,
        _ pcm16Audio: Data
    ) -> Void

    private let stateHandler: StateHandler
    private let turnHandler: TurnHandler
    private let stateQueue: DispatchQueue
    private var segmenter = AudioTurnSegmenter()
    private var isConnected = false

    init(
        label: String,
        onState: @escaping StateHandler,
        onTurn: @escaping TurnHandler
    ) {
        stateHandler = onState
        turnHandler = onTurn
        stateQueue = DispatchQueue(label: "PUnderclass.LocalTurn.\(label)")
    }

    func connect() {
        publishState(.connecting)
        stateQueue.async { [weak self] in
            guard let self, !self.isConnected else { return }
            self.isConnected = true
            self.publishState(.connected)
        }
    }

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        stateQueue.async { [weak self] in
            guard let self, self.isConnected else { return }
            let result = self.segmenter.append(pcm16, receivedAt: Date())
            if let turn = result.completedTurn {
                self.publish(turn)
            }
        }
    }

    func updateContext(_ context: TranscriptionContext) {
        // Context is read by the local refinement client when the completed
        // turn is submitted, so there is no remote session to update here.
    }

    func commitPendingAudio() {
        stateQueue.async { [weak self] in
            guard
                let self,
                self.isConnected,
                let turn = self.segmenter.finish(at: Date())
            else {
                return
            }
            self.publish(turn)
        }
    }

    func disconnect() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.segmenter.reset()
            self.publishState(.idle)
        }
    }

    private func publish(_ turn: SegmentedAudioTurn) {
        let itemID = "local-\(UUID().uuidString.lowercased())"
        DispatchQueue.main.async { [turnHandler] in
            turnHandler(
                itemID,
                turn.startedAt,
                turn.endedAt,
                turn.pcm16Audio
            )
        }
    }

    private func publishState(_ state: SocketState) {
        DispatchQueue.main.async { [stateHandler] in
            stateHandler(state)
        }
    }
}

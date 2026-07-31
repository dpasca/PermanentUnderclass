import AVFAudio
import CoreML
import FluidAudio
import Foundation

final class ParakeetRefinementClient: TranscriptRefining, @unchecked Sendable {
    typealias StateHandler = (SocketState) -> Void
    typealias RefinedHandler = (_ transcriptID: String, _ text: String) -> Void
    typealias FailureHandler = (_ transcriptID: String, _ message: String) -> Void

    static let modelDescription = "Parakeet TDT 0.6B v3 · Core ML"

    private let stateHandler: StateHandler
    private let refinedHandler: RefinedHandler
    private let failureHandler: FailureHandler
    private let stateQueue = DispatchQueue(
        label: "MeetingCopilot.Parakeet.Refinement",
        qos: .userInitiated
    )
    private let transcriber = ParakeetTranscriber.shared

    private var queuedRequests: [RealtimeRefinementRequest] = []
    private var activeRequest: RealtimeRefinementRequest?
    private var operationTask: Task<Void, Never>?
    private var isReady = false
    private var disconnectWhenIdle = false
    private var generation = UUID()

    init(
        onState: @escaping StateHandler,
        onRefined: @escaping RefinedHandler,
        onFailure: @escaping FailureHandler
    ) {
        stateHandler = onState
        refinedHandler = onRefined
        failureHandler = onFailure
    }

    func connect() {
        publishState(.connecting)
        stateQueue.async { [weak self] in
            guard let self, !self.isReady, self.operationTask == nil else { return }
            let generation = UUID()
            self.generation = generation
            self.operationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transcriber.prepare()
                    self.stateQueue.async { [weak self] in
                        guard
                            let self,
                            self.generation == generation
                        else {
                            return
                        }
                        self.operationTask = nil
                        self.isReady = true
                        self.publishState(.connected)
                        self.processNextRequest()
                    }
                } catch {
                    self.stateQueue.async { [weak self] in
                        guard
                            let self,
                            self.generation == generation
                        else {
                            return
                        }
                        self.operationTask = nil
                        self.isReady = false
                        self.failQueuedRequests(error.localizedDescription)
                        self.publishState(.failed(error.localizedDescription))
                    }
                }
            }
        }
    }

    func refine(_ request: RealtimeRefinementRequest) {
        guard !request.pcm16Audio.isEmpty else {
            publishFailure(
                transcriptID: request.transcriptID,
                message: "No buffered audio was available for local refinement."
            )
            return
        }
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.queuedRequests.append(request)
            self.processNextRequest()
        }
    }

    func finishWhenIdle() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.disconnectWhenIdle = true
            self.disconnectIfFinished()
        }
    }

    func disconnect() {
        stateQueue.async { [weak self] in
            self?.disconnectNow()
        }
    }

    private func processNextRequest() {
        guard
            isReady,
            activeRequest == nil,
            operationTask == nil,
            !queuedRequests.isEmpty
        else {
            disconnectIfFinished()
            return
        }

        let request = queuedRequests.removeFirst()
        activeRequest = request
        let generation = generation
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcriber.transcribe(
                    pcm16Audio: request.pcm16Audio,
                    expectedLanguages: request.context.languages
                )
                self.stateQueue.async { [weak self] in
                    guard
                        let self,
                        self.generation == generation,
                        self.activeRequest?.transcriptID == request.transcriptID
                    else {
                        return
                    }
                    self.operationTask = nil
                    self.activeRequest = nil
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.publishFailure(
                            transcriptID: request.transcriptID,
                            message: "Local Parakeet returned no transcript."
                        )
                    } else {
                        self.publishRefined(
                            transcriptID: request.transcriptID,
                            text: trimmed
                        )
                    }
                    self.processNextRequest()
                }
            } catch {
                self.stateQueue.async { [weak self] in
                    guard
                        let self,
                        self.generation == generation,
                        self.activeRequest?.transcriptID == request.transcriptID
                    else {
                        return
                    }
                    self.operationTask = nil
                    self.activeRequest = nil
                    self.publishFailure(
                        transcriptID: request.transcriptID,
                        message: error.localizedDescription
                    )
                    self.processNextRequest()
                }
            }
        }
    }

    private func failQueuedRequests(_ message: String) {
        let requests = queuedRequests
        queuedRequests.removeAll()
        for request in requests {
            publishFailure(transcriptID: request.transcriptID, message: message)
        }
    }

    private func disconnectIfFinished() {
        guard
            disconnectWhenIdle,
            activeRequest == nil,
            queuedRequests.isEmpty,
            operationTask == nil
        else {
            return
        }
        disconnectNow()
    }

    private func disconnectNow() {
        generation = UUID()
        operationTask?.cancel()
        operationTask = nil
        queuedRequests.removeAll()
        activeRequest = nil
        isReady = false
        disconnectWhenIdle = false
        publishState(.idle)
    }

    private func publishState(_ state: SocketState) {
        DispatchQueue.main.async { [stateHandler] in
            stateHandler(state)
        }
    }

    private func publishRefined(transcriptID: String, text: String) {
        DispatchQueue.main.async { [refinedHandler] in
            refinedHandler(transcriptID, text)
        }
    }

    private func publishFailure(transcriptID: String, message: String) {
        DispatchQueue.main.async { [failureHandler] in
            failureHandler(transcriptID, message)
        }
    }
}

actor ParakeetTranscriber {
    static let shared = ParakeetTranscriber()

    private var manager: AsrManager?

    func prepare() async throws {
        guard manager == nil else { return }
        // FluidAudio's v3 benchmarks show the large encoder is WER-neutral
        // and faster on Apple Silicon GPUs. More importantly for this desktop
        // app, this avoids a slow or occasionally stalled ANE compilation on
        // each fresh process. Decoder and joint models retain their defaults.
        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            encoderComputeUnits: .cpuAndGPU
        )
        manager = AsrManager(models: models)
    }

    func transcribe(
        pcm16Audio: Data,
        expectedLanguages: [String]
    ) async throws -> String {
        guard let manager else {
            throw MeetingCopilotError.audio("The local Parakeet model is not ready.")
        }
        let audioBuffer = try Self.audioBuffer(from: pcm16Audio)
        let decoderLayers = await manager.decoderLayerCount
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
        let language = expectedLanguages.lazy.compactMap(Language.init(rawValue:)).first
        let result = try await manager.transcribe(
            audioBuffer,
            decoderState: &decoderState,
            language: language
        )
        return result.text
    }

    private static func audioBuffer(from pcm16Audio: Data) throws -> AVAudioPCMBuffer {
        guard
            pcm16Audio.count.isMultiple(of: MemoryLayout<Int16>.size),
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(
                    pcm16Audio.count / MemoryLayout<Int16>.size
                )
            )
        else {
            throw MeetingCopilotError.audio("Could not construct local transcription audio.")
        }

        buffer.frameLength = buffer.frameCapacity
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let destination = audioBuffer.mData else {
            throw MeetingCopilotError.audio("Could not access local transcription audio.")
        }
        pcm16Audio.withUnsafeBytes { source in
            guard let sourceAddress = source.baseAddress else { return }
            memcpy(destination, sourceAddress, pcm16Audio.count)
        }
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize =
            UInt32(pcm16Audio.count)
        return buffer
    }
}

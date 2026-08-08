import AVFAudio
import CoreML
import FluidAudio
import Foundation
import OSLog

final class ParakeetRefinementClient: TranscriptRefining, @unchecked Sendable {
    typealias StateHandler = (SocketState) -> Void
    typealias RefinedHandler = (_ transcriptID: String, _ text: String) -> Void
    typealias FailureHandler = (_ transcriptID: String, _ message: String) -> Void

    static let modelDescription = "Parakeet TDT 0.6B v3 · Core ML"

    private let stateHandler: StateHandler
    private let refinedHandler: RefinedHandler
    private let failureHandler: FailureHandler
    private let stateQueue = DispatchQueue(
        label: "PUnderclass.Parakeet.Refinement",
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

    func cancelPendingRequests() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.queuedRequests.removeAll()
            // Whichever transcription is already running keeps the model busy,
            // but its result is dropped so it cannot delay the dictation the
            // user is waiting for.
            self.activeRequest = nil
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

enum ParakeetPreparationEvent: Equatable, Sendable {
    case checkingCache
    case downloading(fractionCompleted: Double)
    case loading(component: String)
}

actor ParakeetTranscriber {
    static let shared = ParakeetTranscriber()
    static let encoderComputeUnits: MLComputeUnits = .cpuOnly
    private static let logger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "ParakeetPreparation"
    )

    private var manager: AsrManager?
    private var preparationTask: Task<AsrManager, Error>?

    func prepare(
        onProgress: (@Sendable (ParakeetPreparationEvent) -> Void)? = nil
    ) async throws {
        guard manager == nil else { return }
        if let preparationTask {
            do {
                manager = try await preparationTask.value
                self.preparationTask = nil
                return
            } catch {
                self.preparationTask = nil
                throw error
            }
        }

        onProgress?(.checkingCache)
        // Keep the encoder off Metal. On macOS 26.4.1, Core ML's asynchronous
        // GPU path can abort inside MPSGraphTensorData while bridging a
        // three-dimensional encoder tensor. This is a framework
        // assertion, so it cannot be recovered as a Swift error. CPU-only
        // avoids MPSGraph without the large encoder's slow ANE compile.
        // Loading directly from the default cache still downloads missing
        // assets through FluidAudio, while avoiding downloadAndLoad's extra
        // load-and-discard pass over every Core ML bundle.
        let task = Task(priority: .utility) {
            let models = try await AsrModels.loadFromCache(
                version: .v3,
                encoderComputeUnits: Self.encoderComputeUnits,
                progressHandler: { progress in
                    guard let event = Self.preparationEvent(from: progress) else { return }
                    onProgress?(event)
                }
            )
            let manager = AsrManager(models: models)

            // Core ML's first prediction can be much slower than later calls.
            // Run a quiet, deterministic non-silent probe so that cost is paid
            // during background warmup instead of the first real dictation.
            onProgress?(.loading(component: "inference pipeline"))
            await Self.warmInferencePipeline(manager)
            return manager
        }
        preparationTask = task

        do {
            manager = try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func transcribe(
        pcm16Audio: Data,
        expectedLanguages: [String]
    ) async throws -> String {
        guard let manager else {
            throw PUnderclassError.audio("The local Parakeet model is not ready.")
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

    nonisolated private static func preparationEvent(
        from progress: DownloadUtils.DownloadProgress
    ) -> ParakeetPreparationEvent? {
        switch progress.phase {
        case .listing:
            return .checkingCache
        case let .downloading(_, totalFiles):
            guard totalFiles > 0 else { return nil }
            return .downloading(
                fractionCompleted: min(1, max(0, progress.fractionCompleted * 2))
            )
        case let .compiling(modelName):
            guard !modelName.isEmpty else { return nil }
            return .loading(component: modelComponentName(modelName))
        }
    }

    nonisolated private static func modelComponentName(_ modelName: String) -> String {
        let name = URL(fileURLWithPath: modelName)
            .deletingPathExtension()
            .lastPathComponent
        switch name {
        case "Preprocessor":
            return "audio preprocessor"
        case "Encoder", "EncoderInt4":
            return "encoder"
        case "Decoder":
            return "decoder"
        case "JointDecision", "JointDecisionv3":
            return "joint decoder"
        default:
            return name
        }
    }

    nonisolated private static func warmInferencePipeline(_ manager: AsrManager) async {
        let sampleCount = ASRConstants.minimumRequiredSamples(
            forSampleRate: ASRConstants.sampleRate
        )
        let frequency = 220.0
        let sampleRate = Double(ASRConstants.sampleRate)
        let samples = (0..<sampleCount).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate) * 0.002)
        }

        do {
            let decoderLayers = await manager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            _ = try await manager.transcribe(
                samples,
                decoderState: &decoderState
            )
        } catch {
            logger.debug(
                "parakeet_inference_warmup_skipped error=\(error.localizedDescription, privacy: .public)"
            )
        }
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
            throw PUnderclassError.audio("Could not construct local transcription audio.")
        }

        buffer.frameLength = buffer.frameCapacity
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let destination = audioBuffer.mData else {
            throw PUnderclassError.audio("Could not access local transcription audio.")
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

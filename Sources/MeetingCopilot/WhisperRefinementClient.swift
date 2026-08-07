@preconcurrency import AVFAudio
import CoreML
import Foundation
import OSLog
import WhisperKit

private final class WhisperPipelineBox: @unchecked Sendable {
    let pipeline: WhisperKit

    init(_ pipeline: WhisperKit) {
        self.pipeline = pipeline
    }
}

final class WhisperRefinementClient: TranscriptRefining, @unchecked Sendable {
    typealias StateHandler = (SocketState) -> Void
    typealias RefinedHandler = (_ transcriptID: String, _ text: String) -> Void
    typealias FailureHandler = (_ transcriptID: String, _ message: String) -> Void

    static let modelDescription = "Whisper Large v3 · Core ML · 626 MB"

    private let stateHandler: StateHandler
    private let refinedHandler: RefinedHandler
    private let failureHandler: FailureHandler
    private let stateQueue = DispatchQueue(
        label: "MeetingCopilot.Whisper.Refinement",
        qos: .userInitiated
    )
    private let transcriber = WhisperTranscriber.shared

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
                        guard let self, self.generation == generation else { return }
                        self.operationTask = nil
                        self.isReady = true
                        self.publishState(.connected)
                        self.processNextRequest()
                    }
                } catch {
                    self.stateQueue.async { [weak self] in
                        guard let self, self.generation == generation else { return }
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
                let text = try await self.transcriber.transcribe(request)
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
                            message: "Local Whisper returned no transcript."
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

enum WhisperPreparationEvent: Equatable, Sendable {
    case checkingCache
    case downloading(fractionCompleted: Double)
    case loading(component: String)
}

actor WhisperTranscriber {
    static let shared = WhisperTranscriber()
    static let modelVariant = "large-v3-v20240930_626MB"
    static let modelFolderName = "openai_whisper-large-v3-v20240930_626MB"

    private static let logger = Logger(
        subsystem: "com.permanentunderclass.meetingcopilot",
        category: "WhisperPreparation"
    )

    private var pipeline: WhisperKit?
    private var preparationTask: Task<WhisperPipelineBox, Error>?

    func prepare(
        onProgress: (@Sendable (WhisperPreparationEvent) -> Void)? = nil
    ) async throws {
        guard pipeline == nil else { return }
        if let preparationTask {
            do {
                pipeline = try await preparationTask.value.pipeline
                self.preparationTask = nil
                return
            } catch {
                self.preparationTask = nil
                throw error
            }
        }

        onProgress?(.checkingCache)
        let task = Task(priority: .utility) {
            let cacheDirectory = try Self.cacheDirectory()
            let cachedFolder = Self.cachedModelFolder(in: cacheDirectory)
            let modelFolder: URL
            if Self.hasCompleteModel(at: cachedFolder) {
                modelFolder = cachedFolder
            } else {
                modelFolder = try await WhisperKit.download(
                    variant: Self.modelVariant,
                    downloadBase: cacheDirectory,
                    progressCallback: { progress in
                        onProgress?(
                            .downloading(
                                fractionCompleted: min(
                                    1,
                                    max(0, progress.fractionCompleted)
                                )
                            )
                        )
                    }
                )
            }

            onProgress?(.loading(component: "Core ML models"))
            let configuration = WhisperKitConfig(
                model: Self.modelVariant,
                downloadBase: cacheDirectory,
                modelFolder: modelFolder.path,
                tokenizerFolder: cacheDirectory,
                computeOptions: ModelComputeOptions(),
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
            return WhisperPipelineBox(try await WhisperKit(configuration))
        }
        preparationTask = task

        do {
            pipeline = try await task.value.pipeline
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func transcribe(_ request: RealtimeRefinementRequest) async throws -> String {
        guard let pipeline else {
            throw MeetingCopilotError.audio("The local Whisper model is not ready.")
        }

        let audioSamples = try Self.audioSamples(from: request.pcm16Audio)
        let language = Self.singleLanguageHint(from: request.context.languages)
        let options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
        let results = try await pipeline.transcribe(
            audioArray: audioSamples,
            decodeOptions: options
        )
        return results
            .map(\.text)
            .joined(separator: " ")
    }

    nonisolated static func singleLanguageHint(from languages: [String]) -> String? {
        let normalized = Set(languages.compactMap { language -> String? in
            let code = language
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .components(separatedBy: CharacterSet(charactersIn: "-_"))
                .first
            guard let code, !code.isEmpty else { return nil }
            return code
        })
        guard normalized.count == 1 else { return nil }
        return normalized.first
    }

    nonisolated private static func cacheDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MeetingCopilotError.audio(
                "Could not locate Application Support for the local Whisper model."
            )
        }
        let directory = applicationSupport
            .appendingPathComponent("PUnderclass", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    nonisolated private static func cachedModelFolder(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelFolderName, isDirectory: true)
    }

    nonisolated private static func hasCompleteModel(at folder: URL) -> Bool {
        let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        return requiredModels.allSatisfy { modelName in
            ["mlmodelc", "mlpackage"].contains { pathExtension in
                FileManager.default.fileExists(
                    atPath: folder
                        .appendingPathComponent("\(modelName).\(pathExtension)")
                        .path
                )
            }
        }
    }

    nonisolated static func audioSamples(from pcm16Audio: Data) throws -> [Float] {
        guard
            pcm16Audio.count.isMultiple(of: MemoryLayout<Int16>.size),
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
            ),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(
                    pcm16Audio.count / MemoryLayout<Int16>.size
                )
            ),
            let destinationFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(WhisperKit.sampleRate),
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(
                from: sourceFormat,
                to: destinationFormat
            )
        else {
            throw MeetingCopilotError.audio(
                "Could not construct audio for local Whisper transcription."
            )
        }

        sourceBuffer.frameLength = sourceBuffer.frameCapacity
        let sourceAudioBuffer = sourceBuffer.mutableAudioBufferList.pointee.mBuffers
        guard let destination = sourceAudioBuffer.mData else {
            throw MeetingCopilotError.audio(
                "Could not access audio for local Whisper transcription."
            )
        }
        pcm16Audio.withUnsafeBytes { source in
            guard let sourceAddress = source.baseAddress else { return }
            memcpy(destination, sourceAddress, pcm16Audio.count)
        }
        sourceBuffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize =
            UInt32(pcm16Audio.count)

        let resamplingRatio = destinationFormat.sampleRate / sourceFormat.sampleRate
        let destinationCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * resamplingRatio) + 32
        )
        guard let destinationBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: destinationCapacity
        ) else {
            throw MeetingCopilotError.audio(
                "Could not allocate resampled audio for local Whisper transcription."
            )
        }

        var didProvideInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(
            to: destinationBuffer,
            error: &conversionError
        ) { _, status in
            if didProvideInput {
                status.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return sourceBuffer
        }
        guard conversionStatus != .error, conversionError == nil else {
            throw conversionError ?? MeetingCopilotError.audio(
                "Could not resample audio for local Whisper transcription."
            )
        }
        guard let samples = destinationBuffer.floatChannelData?[0] else {
            throw MeetingCopilotError.audio(
                "Could not access resampled audio for local Whisper transcription."
            )
        }
        return Array(
            UnsafeBufferPointer(
                start: samples,
                count: Int(destinationBuffer.frameLength)
            )
        )
    }
}

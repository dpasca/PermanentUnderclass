import Foundation
import OSLog

enum RealtimeRefinementServerEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    case audioCommitted(itemID: String)
    case transcriptionDelta(itemID: String, delta: String)
    case transcriptionCompleted(
        itemID: String,
        transcript: String,
        languages: [String]
    )
    case transcriptionFailed(itemID: String, message: String)
    case error(String)
    case ignored

    static func parse(_ data: Data) -> RealtimeRefinementServerEvent {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            let type = json["type"] as? String
        else {
            return .ignored
        }

        switch type {
        case "session.created":
            return .sessionCreated

        case "session.updated":
            return .sessionUpdated

        case "input_audio_buffer.committed":
            guard let itemID = json["item_id"] as? String else {
                return .ignored
            }
            return .audioCommitted(itemID: itemID)

        case "conversation.item.input_audio_transcription.delta":
            guard
                let itemID = json["item_id"] as? String,
                let delta = json["delta"] as? String
            else {
                return .ignored
            }
            return .transcriptionDelta(itemID: itemID, delta: delta)

        case "conversation.item.input_audio_transcription.completed":
            guard
                let itemID = json["item_id"] as? String,
                let transcript = json["transcript"] as? String
            else {
                return .ignored
            }
            let languages = (json["languages"] as? [[String: Any]])?
                .compactMap { $0["code"] as? String }
                ?? []
            return .transcriptionCompleted(
                itemID: itemID,
                transcript: transcript,
                languages: languages
            )

        case "conversation.item.input_audio_transcription.failed":
            guard let itemID = json["item_id"] as? String else {
                return .ignored
            }
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? error?["code"] as? String
                ?? error?["type"] as? String
                ?? "GPT-Transcribe could not transcribe the committed audio."
            return .transcriptionFailed(itemID: itemID, message: message)

        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? error?["code"] as? String
                ?? "The GPT-Transcribe API returned an unknown error."
            return .error(message)

        default:
            return .ignored
        }
    }
}

final class RealtimeRefinementClient: NSObject, TranscriptRefining, TranscriptStreaming {
    typealias StateHandler = (SocketState) -> Void
    typealias RefinedHandler = (_ transcriptID: String, _ text: String) -> Void
    typealias FailureHandler = (_ transcriptID: String, _ message: String) -> Void
    typealias UsageHandler = (OpenAITranscriptionUsageRecord) -> Void
    typealias CommittedHandler = (_ transcriptID: String) -> Void
    typealias StreamPartialHandler = (_ streamID: String, _ text: String) -> Void
    typealias StreamCompletionHandler = (_ streamID: String, _ text: String) -> Void
    typealias StreamFailureHandler = (
        _ streamID: String,
        _ message: String
    ) -> Void
    typealias UploadProgressHandler = (
        _ transcriptID: String,
        _ sentBytes: Int,
        _ totalBytes: Int
    ) -> Void

    static let model = "gpt-transcribe"
    static let webSocketURL = URL(
        string: "wss://api.openai.com/v1/realtime?intent=transcription"
    )!

    /// Chunk size for the batch fallback upload. Small enough that the overlay
    /// can report progress at a useful granularity.
    private static let maximumAppendBytes = 262_144
    /// The realtime transcription endpoint rejects any input rate below
    /// 24 kHz, so the wire carries capture audio unchanged.
    static let captureSampleRate = 24_000
    private static let pcm16BytesPerSecond =
        captureSampleRate * MemoryLayout<Int16>.size
    /// Streamed audio is flushed in ~250 ms frames: small enough to keep the
    /// socket busy as the user speaks, large enough to avoid tiny JSON frames.
    private static let streamFlushBytes = pcm16BytesPerSecond / 4
    static let connectionTimeoutSeconds: TimeInterval = 30
    private static let logger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "GPTTranscribe"
    )

    private let apiKey: String
    private let stateHandler: StateHandler
    private let refinedHandler: RefinedHandler
    private let failureHandler: FailureHandler
    private let usageHandler: UsageHandler
    private let committedHandler: CommittedHandler
    private let streamPartialHandler: StreamPartialHandler
    private let streamCompletionHandler: StreamCompletionHandler
    private let streamFailureHandler: StreamFailureHandler
    private let uploadProgressHandler: UploadProgressHandler
    private let socketQueue: DispatchQueue

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var acceptsRequests = true
    private var unavailableMessage: String?
    private var isOpen = false
    private var isConfigured = false
    private var isAwaitingRequestConfiguration = false
    private var queuedRequests: [RealtimeRefinementRequest] = []
    private var activeRequest: RealtimeRefinementRequest?
    private var activeItemID: String?
    private var activeRequestStartUptime: UInt64?
    private var activeCommitDispatchUptime: UInt64?
    private var didLogFirstTranscriptionDelta = false
    private var disconnectWhenIdle = false
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var stream: StreamState?
    /// A dictation started while the previous one is still finishing. One
    /// transcription session cannot carry two streams, so the new recording
    /// buffers here and takes over as soon as the previous transcript lands.
    private var pendingStream: StreamState?
    private var isAwaitingStreamConfiguration = false

    /// A dictation that is uploading while the user speaks. Segments are
    /// committed as the user pauses, so several items can be transcribing at
    /// once and their transcripts are reassembled in commit order.
    private struct StreamState {
        let streamID: String
        let context: TranscriptionContext
        let startUptime: UInt64
        var assembly = DictationStreamAssembly()
        var isConfigured = false
        var isFinishing = false
        var pendingAudio = Data()
        /// Bytes appended since the last commit.
        var segmentBytes = 0
        /// Bytes per committed segment, in commit order.
        var committedSegmentBytes: [Int] = []
        var uploadedBytes = 0
        var finishUptime: UInt64?

        var commitsSent: Int { committedSegmentBytes.count }
    }

    init(
        apiKey: String,
        label: String = "Default",
        onState: @escaping StateHandler,
        onRefined: @escaping RefinedHandler,
        onFailure: @escaping FailureHandler,
        onUsage: @escaping UsageHandler = { _ in },
        onCommitted: @escaping CommittedHandler = { _ in },
        onStreamPartial: @escaping StreamPartialHandler = { _, _ in },
        onStreamCompleted: @escaping StreamCompletionHandler = { _, _ in },
        onStreamFailed: @escaping StreamFailureHandler = { _, _ in },
        onUploadProgress: @escaping UploadProgressHandler = { _, _, _ in }
    ) {
        self.apiKey = apiKey
        stateHandler = onState
        refinedHandler = onRefined
        failureHandler = onFailure
        usageHandler = onUsage
        committedHandler = onCommitted
        streamPartialHandler = onStreamPartial
        streamCompletionHandler = onStreamCompleted
        streamFailureHandler = onStreamFailed
        uploadProgressHandler = onUploadProgress
        let socketQueue = DispatchQueue(
            label: "PUnderclass.GPTTranscribe.\(label)",
            qos: .userInitiated
        )
        self.socketQueue = socketQueue
        super.init()
    }

    func connect() {
        socketQueue.async { [weak self] in
            guard let self, self.task == nil else { return }
            self.publishState(.connecting)
            self.acceptsRequests = true
            self.unavailableMessage = nil

            var request = URLRequest(url: Self.webSocketURL)
            request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = Self.connectionTimeoutSeconds

            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            let task = session.webSocketTask(with: request)
            self.task = task
            task.resume()
            self.receiveNext()
            self.scheduleConnectionTimeout(for: task)
        }
    }

    func refine(_ request: RealtimeRefinementRequest) {
        guard !request.pcm16Audio.isEmpty else {
            publishFailure(
                transcriptID: request.transcriptID,
                message: "No buffered audio was available for the second pass."
            )
            return
        }
        socketQueue.async { [weak self] in
            guard let self else { return }
            guard self.acceptsRequests else {
                self.publishFailure(
                    transcriptID: request.transcriptID,
                    message: self.unavailableMessage
                        ?? "The GPT-Transcribe connection is no longer available."
                )
                return
            }
            self.queuedRequests.append(request)
            self.processNextRequest()
        }
    }

    func finishWhenIdle() {
        socketQueue.async { [weak self] in
            guard let self else { return }
            self.acceptsRequests = false
            self.unavailableMessage =
                "Live capture ended before this turn could be sent to GPT-Transcribe."
            self.disconnectWhenIdle = true
            self.disconnectIfFinished()
        }
    }

    func disconnect() {
        socketQueue.async { [weak self] in
            self?.disconnectNow()
        }
    }

    func cancelPendingRequests() {
        socketQueue.async { [weak self] in
            guard let self else { return }
            self.queuedRequests.removeAll()
            // Results for the in-flight request are dropped rather than
            // published; the socket keeps its session so the next request does
            // not pay for a reconnect.
            self.resetActiveRequest()
        }
    }

    // MARK: - Streaming

    var supportsStreaming: Bool { true }

    func beginStream(_ start: DictationStreamStart) {
        socketQueue.async { [weak self] in
            guard let self else { return }
            guard self.acceptsRequests else {
                self.publishStreamFailure(
                    streamID: start.streamID,
                    message: self.unavailableMessage
                        ?? "The GPT-Transcribe connection is no longer available."
                )
                return
            }
            let state = StreamState(
                streamID: start.streamID,
                context: start.context,
                startUptime: DispatchTime.now().uptimeNanoseconds
            )
            guard self.stream == nil else {
                self.pendingStream = state
                Self.logger.notice(
                    "stream_queued stream_id=\(start.streamID, privacy: .public)"
                )
                return
            }
            self.stream = state
            Self.logger.notice(
                "stream_started stream_id=\(start.streamID, privacy: .public)"
            )
            guard self.isOpen, self.isConfigured else { return }
            self.sendStreamConfiguration()
        }
    }

    func appendStream(streamID: String, pcm16Audio: Data) {
        guard !pcm16Audio.isEmpty else { return }
        socketQueue.async { [weak self] in
            guard let self else { return }
            if self.stream?.streamID == streamID {
                self.stream?.pendingAudio.append(pcm16Audio)
                guard
                    let buffered = self.stream?.pendingAudio.count,
                    buffered >= Self.streamFlushBytes
                else {
                    return
                }
                self.flushStreamAudio()
            } else if self.pendingStream?.streamID == streamID {
                // Buffered until the previous dictation releases the session.
                self.pendingStream?.pendingAudio.append(pcm16Audio)
            }
        }
    }

    func commitStreamSegment(streamID: String) {
        socketQueue.async { [weak self] in
            guard let self, self.stream?.streamID == streamID else { return }
            self.flushStreamAudio()
            self.sendStreamCommit()
        }
    }

    func finishStream(streamID: String) {
        socketQueue.async { [weak self] in
            guard let self else { return }
            if self.pendingStream?.streamID == streamID {
                self.pendingStream?.isFinishing = true
                self.pendingStream?.finishUptime =
                    DispatchTime.now().uptimeNanoseconds
                return
            }
            guard self.stream?.streamID == streamID else { return }
            self.stream?.isFinishing = true
            self.stream?.finishUptime = DispatchTime.now().uptimeNanoseconds
            // A dictation short enough to end before the session is configured
            // still has all its audio buffered; the commit goes out as soon as
            // the session acknowledges.
            guard self.stream?.isConfigured == true else { return }
            self.flushStreamAudio()
            self.sendStreamCommit()
            guard let stream = self.stream else { return }
            guard stream.commitsSent > 0 else {
                self.failStream("No audio reached GPT-Transcribe.")
                return
            }
            Self.logger.notice(
                "stream_finished stream_id=\(stream.streamID, privacy: .public) segments=\(stream.commitsSent, privacy: .public) bytes=\(stream.uploadedBytes, privacy: .public)"
            )
            self.completeStreamIfFinished()
        }
    }

    func cancelStream(streamID: String) {
        socketQueue.async { [weak self] in
            guard let self else { return }
            if self.pendingStream?.streamID == streamID {
                self.pendingStream = nil
                return
            }
            guard self.stream?.streamID == streamID else { return }
            self.stream = nil
            self.isAwaitingStreamConfiguration = false
            self.promotePendingStream()
        }
    }

    /// Starts the dictation that was recorded while the previous one finished.
    private func promotePendingStream() {
        guard stream == nil, let next = pendingStream else { return }
        pendingStream = nil
        stream = next
        Self.logger.notice(
            "stream_started stream_id=\(next.streamID, privacy: .public) queued=true"
        )
        guard isOpen, isConfigured else { return }
        sendStreamConfiguration()
    }

    /// Finishes a promoted stream whose recording already ended while it was
    /// waiting its turn.
    /// Sends the final commit for a stream whose recording ended before the
    /// session was configured — either because it was queued behind another
    /// dictation, or because the user released the shortcut almost immediately.
    private func completePromotedStreamIfAlreadyFinished() {
        guard let stream, stream.isFinishing, stream.isConfigured else { return }
        flushStreamAudio()
        sendStreamCommit()
        guard let updated = self.stream else { return }
        guard updated.commitsSent > 0 else {
            failStream("No audio reached GPT-Transcribe.")
            return
        }
        completeStreamIfFinished()
    }

    private func sendStreamConfiguration() {
        guard let stream, let task else { return }
        do {
            let data = try Self.sessionUpdateJSON(
                RealtimeRefinementRequest(
                    transcriptID: stream.streamID,
                    speaker: .you,
                    pcm16Audio: Data(),
                    context: stream.context,
                    recentTranscript: ""
                )
            )
            guard let text = String(data: data, encoding: .utf8) else {
                throw PUnderclassError.audio(
                    "Could not encode the GPT-Transcribe session."
                )
            }
            isAwaitingStreamConfiguration = true
            task.send(.string(text)) { [weak self] error in
                self?.socketQueue.async {
                    guard let self, let error else { return }
                    self.failConnection(error.localizedDescription)
                }
            }
        } catch {
            failStream(error.localizedDescription)
        }
    }

    private func flushStreamAudio() {
        guard
            let stream,
            stream.isConfigured,
            !stream.pendingAudio.isEmpty,
            let task
        else {
            return
        }
        let audio = stream.pendingAudio
        self.stream?.pendingAudio = Data()
        self.stream?.segmentBytes += audio.count
        self.stream?.uploadedBytes += audio.count
        let streamID = stream.streamID
        do {
            let data = try Self.inputAudioAppendJSON(audio)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PUnderclassError.audio(
                    "Could not encode GPT-Transcribe audio."
                )
            }
            // Streamed frames are not serialized behind each other's
            // completion: audio arrives in real time, so the socket is never
            // the bottleneck and waiting per frame would only add latency.
            task.send(.string(text)) { [weak self] error in
                self?.socketQueue.async {
                    guard
                        let self,
                        let error,
                        self.stream?.streamID == streamID
                    else {
                        return
                    }
                    self.failStream(error.localizedDescription)
                }
            }
        } catch {
            failStream(error.localizedDescription)
        }
    }

    private func sendStreamCommit() {
        guard let stream, stream.isConfigured, let task else { return }
        let segmentSeconds = Double(stream.segmentBytes)
            / Double(Self.pcm16BytesPerSecond)
        guard DictationSegmentCommitPolicy.canCommit(
            segmentSeconds: segmentSeconds
        ) else {
            return
        }
        self.stream?.committedSegmentBytes.append(stream.segmentBytes)
        self.stream?.segmentBytes = 0
        do {
            let data = try Self.inputAudioCommitJSON()
            guard let text = String(data: data, encoding: .utf8) else {
                throw PUnderclassError.audio(
                    "Could not encode the GPT-Transcribe commit."
                )
            }
            task.send(.string(text)) { [weak self] error in
                self?.socketQueue.async {
                    guard let self, let error else { return }
                    self.failStream(error.localizedDescription)
                }
            }
        } catch {
            failStream(error.localizedDescription)
        }
    }

    private func handleStreamEvent(
        _ event: RealtimeRefinementServerEvent,
        completionUsage: TranscriptionCompletionUsage?
    ) -> Bool {
        guard stream != nil else { return false }
        switch event {
        case let .audioCommitted(itemID):
            stream?.assembly.registerCommitted(itemID: itemID)
            return true

        case let .transcriptionDelta(itemID, delta):
            stream?.assembly.appendDelta(itemID: itemID, delta: delta)
            publishStreamPartial()
            return true

        case let .transcriptionCompleted(itemID, transcript, _):
            stream?.assembly.finalize(itemID: itemID, text: transcript)
            publishSegmentUsage(itemID: itemID, completionUsage: completionUsage)
            publishStreamPartial()
            completeStreamIfFinished()
            return true

        case let .transcriptionFailed(_, message):
            failStream(message)
            return true

        default:
            return false
        }
    }

    private func publishSegmentUsage(
        itemID: String,
        completionUsage: TranscriptionCompletionUsage?
    ) {
        guard let stream else { return }
        let reportedSeconds = completionUsage?.seconds
        let estimatedSeconds: Double? = stream.assembly.order
            .firstIndex(of: itemID)
            .flatMap { index in
                guard index < stream.committedSegmentBytes.count else {
                    return nil
                }
                return Double(stream.committedSegmentBytes[index])
                    / Double(Self.pcm16BytesPerSecond)
            }
        guard let seconds = reportedSeconds ?? estimatedSeconds else { return }
        publishUsage(
            OpenAITranscriptionUsageRecord(
                pass: .final,
                model: Self.model,
                audioSeconds: seconds,
                measurement: reportedSeconds == nil
                    ? .submittedAudioEstimate
                    : .serverReported
            )
        )
    }

    private func completeStreamIfFinished() {
        guard let stream, stream.isFinishing else { return }
        guard stream.assembly.isComplete(
            expectedSegments: stream.commitsSent
        ) else {
            return
        }
        let text = stream.assembly.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let elapsed = elapsedMilliseconds(
            from: stream.finishUptime,
            to: DispatchTime.now().uptimeNanoseconds
        ) {
            Self.logger.notice(
                "stream_completed stream_id=\(stream.streamID, privacy: .public) tail_ms=\(elapsed, privacy: .public) characters=\(text.count, privacy: .public)"
            )
        }
        self.stream = nil
        isAwaitingStreamConfiguration = false
        if text.isEmpty {
            publishStreamFailure(
                streamID: stream.streamID,
                message: "GPT-Transcribe returned no transcript."
            )
        } else {
            publishStreamCompletion(streamID: stream.streamID, text: text)
        }
        promotePendingStream()
    }

    /// Fails every stream without promoting a queued one, for when the socket
    /// itself is gone and there is nothing left to promote onto.
    private func failStreams(_ message: String) {
        if let pendingStream {
            self.pendingStream = nil
            publishStreamFailure(
                streamID: pendingStream.streamID,
                message: message
            )
        }
        guard let stream else { return }
        Self.logger.error(
            "stream_failed stream_id=\(stream.streamID, privacy: .public) error=\(message, privacy: .public)"
        )
        self.stream = nil
        isAwaitingStreamConfiguration = false
        publishStreamFailure(streamID: stream.streamID, message: message)
    }

    private func failStream(_ message: String) {
        guard let stream else { return }
        Self.logger.error(
            "stream_failed stream_id=\(stream.streamID, privacy: .public) error=\(message, privacy: .public)"
        )
        self.stream = nil
        isAwaitingStreamConfiguration = false
        publishStreamFailure(streamID: stream.streamID, message: message)
        promotePendingStream()
    }

    static func sessionUpdateJSON(
        _ request: RealtimeRefinementRequest? = nil
    ) throws -> Data {
        var transcription: [String: Any] = [
            "model": model
        ]
        if let request {
            let prompt = transcriptionPrompt(for: request)
            if !prompt.isEmpty {
                transcription["prompt"] = prompt
            }
            if !request.context.keywords.isEmpty {
                transcription["keywords"] = request.context.keywords
            }
            if !request.context.languages.isEmpty {
                transcription["languages"] = request.context.languages
            }
        }

        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": captureSampleRate
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: event)
    }

    static func inputAudioAppendJSON(_ audio: Data) throws -> Data {
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": audio.base64EncodedString()
        ]
        return try JSONSerialization.data(withJSONObject: event)
    }

    static func inputAudioCommitJSON() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["type": "input_audio_buffer.commit"]
        )
    }

    static func transcriptionPrompt(for request: RealtimeRefinementRequest) -> String {
        var sections: [String] = []
        let meetingContext = request.context.prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !meetingContext.isEmpty {
            sections.append(meetingContext)
        }
        if request.context.outputStyle == .cleanDictation {
            sections.append(QuickDictationContextPolicy.cleanupInstruction)
        }

        let recentTranscript = request.recentTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !recentTranscript.isEmpty {
            sections.append("Earlier captured turns:\n\(recentTranscript)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func processNextRequest() {
        guard
            isOpen,
            isConfigured,
            activeRequest == nil,
            !queuedRequests.isEmpty,
            task != nil
        else {
            disconnectIfFinished()
            return
        }

        let request = queuedRequests.removeFirst()
        activeRequest = request
        activeItemID = nil
        activeRequestStartUptime = DispatchTime.now().uptimeNanoseconds
        activeCommitDispatchUptime = nil
        didLogFirstTranscriptionDelta = false
        Self.logger.notice(
            "request_started transcript_id=\(request.transcriptID, privacy: .public) audio_bytes=\(request.pcm16Audio.count, privacy: .public)"
        )
        sendConfiguration(for: request)
    }

    private func sendConfiguration(for request: RealtimeRefinementRequest) {
        guard let task else { return }
        do {
            let data = try Self.sessionUpdateJSON(request)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PUnderclassError.audio(
                    "Could not encode the GPT-Transcribe session."
                )
            }
            isAwaitingRequestConfiguration = true
            task.send(.string(text)) { [weak self] error in
                self?.socketQueue.async {
                    guard let self, let error else { return }
                    self.failConnection(error.localizedDescription)
                }
            }
        } catch {
            failConnection(error.localizedDescription)
        }
    }

    private func sendActiveAudio() {
        guard let request = activeRequest, let task else { return }
        // The batch path is the fallback for when streaming was unavailable or
        // broke mid-recording; it still pays the full upload after the fact.
        sendAudioChunk(
            for: request.transcriptID,
            audio: request.pcm16Audio,
            offset: 0,
            task: task
        )
    }

    private func sendAudioChunk(
        for transcriptID: String,
        audio: Data,
        offset: Int,
        task: URLSessionWebSocketTask
    ) {
        guard activeRequest?.transcriptID == transcriptID else { return }
        guard offset < audio.count else {
            sendCommit(for: transcriptID, task: task)
            return
        }

        let end = min(offset + Self.maximumAppendBytes, audio.count)
        let chunk = audio.subdata(in: offset..<end)
        do {
            let data = try Self.inputAudioAppendJSON(chunk)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PUnderclassError.audio(
                    "Could not encode GPT-Transcribe audio."
                )
            }
            task.send(.string(text)) { [weak self] error in
                self?.socketQueue.async {
                    guard let self else { return }
                    guard self.activeRequest?.transcriptID == transcriptID else {
                        return
                    }
                    if let error {
                        self.failConnection(error.localizedDescription)
                        return
                    }
                    self.publishUploadProgress(
                        transcriptID: transcriptID,
                        sentBytes: end,
                        totalBytes: audio.count
                    )
                    self.sendAudioChunk(
                        for: transcriptID,
                        audio: audio,
                        offset: end,
                        task: task
                    )
                }
            }
        } catch {
            failConnection(error.localizedDescription)
        }
    }

    private func sendCommit(
        for transcriptID: String,
        task: URLSessionWebSocketTask
    ) {
        guard activeRequest?.transcriptID == transcriptID else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        activeCommitDispatchUptime = now
        if let elapsed = elapsedMilliseconds(
            from: activeRequestStartUptime,
            to: now
        ) {
            Self.logger.notice(
                "audio_commit_dispatched transcript_id=\(transcriptID, privacy: .public) client_prepare_ms=\(elapsed, privacy: .public)"
            )
        }
        do {
            let data = try Self.inputAudioCommitJSON()
            guard let text = String(data: data, encoding: .utf8) else {
                throw PUnderclassError.audio(
                    "Could not encode the GPT-Transcribe commit."
                )
            }
            task.send(.string(text)) { [weak self] error in
                self?.socketQueue.async {
                    guard
                        let self,
                        self.activeRequest?.transcriptID == transcriptID
                    else {
                        return
                    }
                    if let error {
                        self.failConnection(error.localizedDescription)
                        return
                    }
                    self.publishCommitted(transcriptID: transcriptID)
                }
            }
        } catch {
            failConnection(error.localizedDescription)
        }
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.socketQueue.async {
                switch result {
                case let .success(message):
                    let data: Data?
                    switch message {
                    case let .data(value):
                        data = value
                    case let .string(value):
                        data = value.data(using: .utf8)
                    @unknown default:
                        data = nil
                    }
                    if let data {
                        self.handle(
                            RealtimeRefinementServerEvent.parse(data),
                            completionUsage: TranscriptionCompletionUsage.parse(
                                from: data
                            )
                        )
                    }
                    self.receiveNext()

                case let .failure(error):
                    guard self.task != nil else { return }
                    self.failConnection(error.localizedDescription)
                }
            }
        }
    }

    private func handle(
        _ event: RealtimeRefinementServerEvent,
        completionUsage: TranscriptionCompletionUsage?
    ) {
        if handleStreamEvent(event, completionUsage: completionUsage) {
            return
        }
        switch event {
        case .sessionCreated:
            break

        case .sessionUpdated:
            if !isConfigured {
                cancelConnectionTimeout()
                isConfigured = true
                publishState(.connected)
                if stream != nil || pendingStream != nil {
                    promotePendingStream()
                    sendStreamConfiguration()
                } else {
                    processNextRequest()
                }
            } else if isAwaitingStreamConfiguration, stream != nil {
                isAwaitingStreamConfiguration = false
                stream?.isConfigured = true
                flushStreamAudio()
                completePromotedStreamIfAlreadyFinished()
            } else if isAwaitingRequestConfiguration, activeRequest != nil {
                isAwaitingRequestConfiguration = false
                sendActiveAudio()
            }

        case let .audioCommitted(itemID):
            guard activeRequest != nil else { return }
            activeItemID = itemID
            if
                let request = activeRequest,
                let elapsed = elapsedMilliseconds(
                    from: activeCommitDispatchUptime,
                    to: DispatchTime.now().uptimeNanoseconds
                )
            {
                Self.logger.notice(
                    "audio_commit_acknowledged transcript_id=\(request.transcriptID, privacy: .public) server_ack_ms=\(elapsed, privacy: .public)"
                )
            }

        case let .transcriptionDelta(itemID, _):
            guard activeItemID == itemID, !didLogFirstTranscriptionDelta else {
                return
            }
            didLogFirstTranscriptionDelta = true
            if
                let request = activeRequest,
                let elapsed = elapsedMilliseconds(
                    from: activeCommitDispatchUptime,
                    to: DispatchTime.now().uptimeNanoseconds
                )
            {
                Self.logger.notice(
                    "first_transcription_delta transcript_id=\(request.transcriptID, privacy: .public) provider_wait_ms=\(elapsed, privacy: .public)"
                )
            }

        case let .transcriptionCompleted(itemID, transcript, _):
            guard activeItemID == itemID else { return }
            if let request = activeRequest {
                let reportedSeconds = completionUsage?.seconds
                let audioSeconds = reportedSeconds
                    ?? Double(request.pcm16Audio.count)
                        / Double(Self.pcm16BytesPerSecond)
                publishUsage(
                    OpenAITranscriptionUsageRecord(
                        pass: .final,
                        model: Self.model,
                        audioSeconds: audioSeconds,
                        measurement: reportedSeconds == nil
                            ? .submittedAudioEstimate
                            : .serverReported
                    )
                )
            }
            completeActiveRequest(with: transcript)
            processNextRequest()

        case let .transcriptionFailed(itemID, message):
            guard activeItemID == itemID else { return }
            failActiveRequest(message)
            processNextRequest()

        case let .error(message):
            failConnection(message)

        case .ignored:
            break
        }
    }

    private func completeActiveRequest(with transcript: String) {
        guard let request = activeRequest else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        logRequestFinished(
            transcriptID: request.transcriptID,
            outcome: "completed"
        )
        resetActiveRequest()

        guard !text.isEmpty else {
            publishFailure(
                transcriptID: request.transcriptID,
                message: "GPT-Transcribe returned no transcript."
            )
            return
        }
        publishRefined(transcriptID: request.transcriptID, text: text)
    }

    private func failActiveRequest(_ message: String) {
        guard let request = activeRequest else { return }
        logRequestFinished(
            transcriptID: request.transcriptID,
            outcome: "failed"
        )
        resetActiveRequest()
        publishFailure(transcriptID: request.transcriptID, message: message)
    }

    private func resetActiveRequest() {
        activeRequest = nil
        activeItemID = nil
        activeRequestStartUptime = nil
        activeCommitDispatchUptime = nil
        didLogFirstTranscriptionDelta = false
        isAwaitingRequestConfiguration = false
    }

    private func logRequestFinished(
        transcriptID: String,
        outcome: String
    ) {
        guard let elapsed = elapsedMilliseconds(
            from: activeRequestStartUptime,
            to: DispatchTime.now().uptimeNanoseconds
        ) else {
            return
        }
        Self.logger.notice(
            "request_finished transcript_id=\(transcriptID, privacy: .public) outcome=\(outcome, privacy: .public) total_ms=\(elapsed, privacy: .public)"
        )
    }

    private func elapsedMilliseconds(
        from start: UInt64?,
        to end: UInt64
    ) -> UInt64? {
        guard let start, end >= start else { return nil }
        return (end - start) / 1_000_000
    }

    private func failQueuedRequests(_ message: String) {
        let requests = queuedRequests
        queuedRequests.removeAll()
        for request in requests {
            publishFailure(transcriptID: request.transcriptID, message: message)
        }
    }

    private func failConnection(_ message: String) {
        cancelConnectionTimeout()
        failStreams(message)
        failActiveRequest(message)
        failQueuedRequests(message)
        acceptsRequests = false
        unavailableMessage = message
        isOpen = false
        isConfigured = false
        disconnectWhenIdle = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        publishState(.failed(message))
    }

    private func disconnectIfFinished() {
        guard
            disconnectWhenIdle,
            activeRequest == nil,
            queuedRequests.isEmpty,
            stream == nil,
            pendingStream == nil
        else {
            return
        }
        disconnectNow()
    }

    private func disconnectNow() {
        cancelConnectionTimeout()
        acceptsRequests = false
        if unavailableMessage == nil {
            unavailableMessage = "The GPT-Transcribe connection is closed."
        }
        failStreams(
            unavailableMessage ?? "The GPT-Transcribe connection is closed."
        )
        isOpen = false
        isConfigured = false
        disconnectWhenIdle = false
        queuedRequests.removeAll()
        resetActiveRequest()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        publishState(.idle)
    }

    private func scheduleConnectionTimeout(for task: URLSessionWebSocketTask) {
        // `waitsForConnectivity` can keep a task pending beyond the request's
        // timeout, so readiness needs its own bounded watchdog.
        cancelConnectionTimeout()
        let taskIdentifier = task.taskIdentifier
        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.task?.taskIdentifier == taskIdentifier,
                !self.isConfigured
            else {
                return
            }
            self.connectionTimeoutWorkItem = nil
            self.failConnection(
                "GPT-Transcribe did not connect within \(Int(Self.connectionTimeoutSeconds)) seconds."
            )
        }
        connectionTimeoutWorkItem = workItem
        socketQueue.asyncAfter(
            deadline: .now() + Self.connectionTimeoutSeconds,
            execute: workItem
        )
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }

    private func sendInitialSessionUpdate() {
        guard let task else { return }
        do {
            let data = try Self.sessionUpdateJSON()
            guard let text = String(data: data, encoding: .utf8) else {
                throw PUnderclassError.audio(
                    "Could not encode the GPT-Transcribe session."
                )
            }
            task.send(.string(text)) { [weak self] error in
                self?.socketQueue.async {
                    guard let self, let error else { return }
                    self.failConnection(error.localizedDescription)
                }
            }
        } catch {
            failConnection(error.localizedDescription)
        }
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

    private func publishUsage(_ usage: OpenAITranscriptionUsageRecord) {
        DispatchQueue.main.async { [usageHandler] in
            usageHandler(usage)
        }
    }

    private func publishCommitted(transcriptID: String) {
        DispatchQueue.main.async { [committedHandler] in
            committedHandler(transcriptID)
        }
    }

    private func publishStreamPartial() {
        guard let stream else { return }
        let text = stream.assembly.text
        DispatchQueue.main.async { [streamPartialHandler, streamID = stream.streamID] in
            streamPartialHandler(streamID, text)
        }
    }

    private func publishStreamCompletion(streamID: String, text: String) {
        DispatchQueue.main.async { [streamCompletionHandler] in
            streamCompletionHandler(streamID, text)
        }
    }

    private func publishStreamFailure(streamID: String, message: String) {
        DispatchQueue.main.async { [streamFailureHandler] in
            streamFailureHandler(streamID, message)
        }
    }

    private func publishUploadProgress(
        transcriptID: String,
        sentBytes: Int,
        totalBytes: Int
    ) {
        DispatchQueue.main.async { [uploadProgressHandler] in
            uploadProgressHandler(transcriptID, sentBytes, totalBytes)
        }
    }
}

extension RealtimeRefinementClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        socketQueue.async { [weak self] in
            guard let self, webSocketTask == self.task else { return }
            self.isOpen = true
            self.sendInitialSessionUpdate()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        socketQueue.async { [weak self] in
            guard let self, webSocketTask == self.task else { return }
            self.cancelConnectionTimeout()
            self.acceptsRequests = false
            if self.unavailableMessage == nil {
                self.unavailableMessage = "The GPT-Transcribe connection is closed."
            }
            self.isOpen = false
            self.isConfigured = false
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil

            let hadPendingWork = self.activeRequest != nil
                || !self.queuedRequests.isEmpty
                || self.stream != nil
                || self.pendingStream != nil
            if closeCode == .normalClosure || closeCode == .goingAway,
               !hadPendingWork {
                self.publishState(.idle)
            } else {
                let message = reason.flatMap { String(data: $0, encoding: .utf8) }
                    ?? "The GPT-Transcribe connection closed unexpectedly."
                self.failStreams(message)
                self.failActiveRequest(message)
                self.failQueuedRequests(message)
                self.publishState(.failed(message))
            }
        }
    }
}

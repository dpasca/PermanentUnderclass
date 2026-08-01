import Foundation

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

final class RealtimeRefinementClient: NSObject, TranscriptRefining {
    typealias StateHandler = (SocketState) -> Void
    typealias RefinedHandler = (_ transcriptID: String, _ text: String) -> Void
    typealias FailureHandler = (_ transcriptID: String, _ message: String) -> Void
    typealias UsageHandler = (OpenAITranscriptionUsageRecord) -> Void

    static let model = "gpt-transcribe"
    static let webSocketURL = URL(
        string: "wss://api.openai.com/v1/realtime?intent=transcription"
    )!

    private static let maximumAppendBytes = 1_048_576
    private static let pcm16BytesPerSecond = 24_000 * MemoryLayout<Int16>.size

    private let apiKey: String
    private let stateHandler: StateHandler
    private let refinedHandler: RefinedHandler
    private let failureHandler: FailureHandler
    private let usageHandler: UsageHandler
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
    private var disconnectWhenIdle = false

    init(
        apiKey: String,
        label: String = "Default",
        onState: @escaping StateHandler,
        onRefined: @escaping RefinedHandler,
        onFailure: @escaping FailureHandler,
        onUsage: @escaping UsageHandler = { _ in }
    ) {
        self.apiKey = apiKey
        stateHandler = onState
        refinedHandler = onRefined
        failureHandler = onFailure
        usageHandler = onUsage
        socketQueue = DispatchQueue(
            label: "MeetingCopilot.GPTTranscribe.\(label)",
            qos: .userInitiated
        )
        super.init()
    }

    func connect() {
        publishState(.connecting)
        socketQueue.async { [weak self] in
            guard let self, self.task == nil else { return }
            self.acceptsRequests = true
            self.unavailableMessage = nil

            var request = URLRequest(url: Self.webSocketURL)
            request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

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
                "The meeting ended before this turn could be sent to GPT-Transcribe."
            self.disconnectWhenIdle = true
            self.disconnectIfFinished()
        }
    }

    func disconnect() {
        socketQueue.async { [weak self] in
            self?.disconnectNow()
        }
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
                            "rate": 24_000
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

        let recentTranscript = request.recentTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !recentTranscript.isEmpty {
            sections.append("Earlier meeting turns:\n\(recentTranscript)")
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
        sendConfiguration(for: request)
    }

    private func sendConfiguration(for request: RealtimeRefinementRequest) {
        guard let task else { return }
        do {
            let data = try Self.sessionUpdateJSON(request)
            guard let text = String(data: data, encoding: .utf8) else {
                throw MeetingCopilotError.audio(
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
                throw MeetingCopilotError.audio(
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
        do {
            let data = try Self.inputAudioCommitJSON()
            guard let text = String(data: data, encoding: .utf8) else {
                throw MeetingCopilotError.audio(
                    "Could not encode the GPT-Transcribe commit."
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
        switch event {
        case .sessionCreated:
            break

        case .sessionUpdated:
            if !isConfigured {
                isConfigured = true
                publishState(.connected)
                processNextRequest()
            } else if isAwaitingRequestConfiguration, activeRequest != nil {
                isAwaitingRequestConfiguration = false
                sendActiveAudio()
            }

        case let .audioCommitted(itemID):
            guard activeRequest != nil else { return }
            activeItemID = itemID

        case .transcriptionDelta:
            break

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
        resetActiveRequest()
        publishFailure(transcriptID: request.transcriptID, message: message)
    }

    private func resetActiveRequest() {
        activeRequest = nil
        activeItemID = nil
        isAwaitingRequestConfiguration = false
    }

    private func failQueuedRequests(_ message: String) {
        let requests = queuedRequests
        queuedRequests.removeAll()
        for request in requests {
            publishFailure(transcriptID: request.transcriptID, message: message)
        }
    }

    private func failConnection(_ message: String) {
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
            queuedRequests.isEmpty
        else {
            return
        }
        disconnectNow()
    }

    private func disconnectNow() {
        acceptsRequests = false
        if unavailableMessage == nil {
            unavailableMessage = "The GPT-Transcribe connection is closed."
        }
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

    private func sendInitialSessionUpdate() {
        guard let task else { return }
        do {
            let data = try Self.sessionUpdateJSON()
            guard let text = String(data: data, encoding: .utf8) else {
                throw MeetingCopilotError.audio(
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
            if closeCode == .normalClosure || closeCode == .goingAway,
               !hadPendingWork {
                self.publishState(.idle)
            } else {
                let message = reason.flatMap { String(data: $0, encoding: .utf8) }
                    ?? "The GPT-Transcribe connection closed unexpectedly."
                self.failActiveRequest(message)
                self.failQueuedRequests(message)
                self.publishState(.failed(message))
            }
        }
    }
}

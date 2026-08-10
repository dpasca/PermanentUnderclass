import Foundation

enum RealtimeServerEvent: Equatable {
    case transcriptionDelta(itemID: String, delta: String)
    case transcriptionCompleted(itemID: String, transcript: String)
    case speechStarted(itemID: String, audioStartMS: Int)
    case speechStopped(itemID: String, audioEndMS: Int)
    case audioCommitted(itemID: String)
    case sessionReady
    case error(String)
    case ignored

    static func parse(_ data: Data) -> RealtimeServerEvent {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            let type = json["type"] as? String
        else {
            return .ignored
        }

        switch type {
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
            return .transcriptionCompleted(itemID: itemID, transcript: transcript)

        case "input_audio_buffer.speech_started":
            guard
                let itemID = json["item_id"] as? String,
                let audioStartMS = Self.integer(json["audio_start_ms"])
            else {
                return .ignored
            }
            return .speechStarted(itemID: itemID, audioStartMS: audioStartMS)

        case "input_audio_buffer.speech_stopped":
            guard
                let itemID = json["item_id"] as? String,
                let audioEndMS = Self.integer(json["audio_end_ms"])
            else {
                return .ignored
            }
            return .speechStopped(itemID: itemID, audioEndMS: audioEndMS)

        case "input_audio_buffer.committed":
            guard let itemID = json["item_id"] as? String else {
                return .ignored
            }
            return .audioCommitted(itemID: itemID)

        case "session.created", "session.updated":
            return .sessionReady

        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? error?["code"] as? String
                ?? "The Realtime API returned an unknown error."
            return .error(message)

        default:
            return .ignored
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

final class RealtimeTranscriptionClient: NSObject {
    typealias StateHandler = (SocketState) -> Void
    typealias PartialHandler = (_ itemID: String, _ text: String) -> Void
    typealias FinalHandler = (
        _ itemID: String,
        _ transcript: String,
        _ startedAt: Date,
        _ endedAt: Date?,
        _ pcm16Audio: Data
    ) -> Void
    typealias UsageHandler = (OpenAITranscriptionUsageRecord) -> Void
    typealias SpeechPauseHandler = (_ speechEndedAt: Date) -> Void

    private struct OutboundMessage {
        let text: String
        let isAudio: Bool
    }

    private struct CommittedTurn {
        let startedAt: Date
        let endedAt: Date
        let pcm16Audio: Data
        let submittedAudioSeconds: Double
    }

    private let apiKey: String
    private var context: TranscriptionContext
    private let stateHandler: StateHandler
    private let partialHandler: PartialHandler
    private let finalHandler: FinalHandler
    private let usageHandler: UsageHandler
    private let earlyBridgePauseHandler: SpeechPauseHandler
    private let speechPauseHandler: SpeechPauseHandler
    private let socketQueue: DispatchQueue

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var isSending = false
    private var outbound: [OutboundMessage] = []
    private var partials: [String: String] = [:]
    private var preRoll: [Data] = []
    private var consecutiveVoicedChunks = 0
    private var silentChunks = 0
    private var hasPublishedEarlyBridgePause = false
    private var hasPublishedSpeechPause = false
    private var noiseFloor: Float = 0.001
    private var activeTurnStartedAt: Date?
    private var lastVoicedAt: Date?
    private var activeTurnAudio = Data()
    private var activeTurnLastVoicedByteCount = 0
    private var pendingTurns: [CommittedTurn] = []
    private var committedTurns: [String: CommittedTurn] = [:]
    private let maximumQueuedAudioChunks = 250
    private let preRollChunkCount = 15
    private let speechOnsetChunkCount = 2
    // Give the small opening-sentence model a 400 ms head start. The heavier
    // full-answer check keeps the more conservative 800 ms pause.
    static let earlyBridgePauseSilenceChunkCount = 20
    static let assistantPauseSilenceChunkCount = 40
    // Keep thoughtful or accented speech together across ordinary pauses.
    // Partial text still streams while this 3 s finalization window is open.
    private let speechEndSilenceChunkCount = 150
    private let retainedPostRollChunkCount = 10
    private static let pcm16BytesPerSecond = 24_000 * MemoryLayout<Int16>.size
    static let model = "gpt-live-transcribe"
    static let webSocketURL = URL(
        string: "wss://api.openai.com/v1/realtime?intent=transcription"
    )!

    init(
        apiKey: String,
        context: TranscriptionContext,
        label: String,
        onState: @escaping StateHandler,
        onPartial: @escaping PartialHandler,
        onFinal: @escaping FinalHandler,
        onEarlyBridgePause: @escaping SpeechPauseHandler = { _ in },
        onSpeechPause: @escaping SpeechPauseHandler = { _ in },
        onUsage: @escaping UsageHandler = { _ in }
    ) {
        self.apiKey = apiKey
        self.context = context
        stateHandler = onState
        partialHandler = onPartial
        finalHandler = onFinal
        earlyBridgePauseHandler = onEarlyBridgePause
        speechPauseHandler = onSpeechPause
        usageHandler = onUsage
        socketQueue = DispatchQueue(label: "PUnderclass.Realtime.\(label)")
        super.init()
    }

    func connect() {
        publishState(.connecting)
        socketQueue.async { [weak self] in
            guard let self, self.task == nil else { return }

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

    func sendAudio(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        socketQueue.async { [weak self] in
            guard let self, self.task != nil else { return }
            self.processAudioChunk(pcm16, receivedAt: Date())
        }
    }

    func updateContext(_ context: TranscriptionContext) {
        socketQueue.async { [weak self] in
            guard let self else { return }
            self.context = context
            guard
                let payload = try? Self.sessionUpdateJSON(context),
                let text = String(data: payload, encoding: .utf8)
            else {
                return
            }
            self.enqueue(text, isAudio: false, priority: true)
        }
    }

    func commitPendingAudio() {
        socketQueue.async { [weak self] in
            self?.commitActiveTurn(at: Date())
        }
    }

    func disconnect() {
        socketQueue.async { [weak self] in
            guard let self else { return }
            self.isOpen = false
            self.outbound.removeAll()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.publishState(.idle)
        }
    }

    private func enqueue(_ text: String, isAudio: Bool, priority: Bool) {
        let message = OutboundMessage(text: text, isAudio: isAudio)
        if priority {
            outbound.insert(message, at: 0)
        } else {
            outbound.append(message)
        }
        pumpSendQueue()
    }

    private func processAudioChunk(_ data: Data, receivedAt: Date) {
        let rms = Self.rms(of: data)
        let threshold = max(0.004, noiseFloor * 3.5)
        let isVoiced = rms >= threshold

        if activeTurnStartedAt != nil {
            enqueueAudio(data)
            activeTurnAudio.append(data)
            if isVoiced {
                silentChunks = 0
                hasPublishedEarlyBridgePause = false
                hasPublishedSpeechPause = false
                lastVoicedAt = receivedAt
                activeTurnLastVoicedByteCount = activeTurnAudio.count
            } else {
                silentChunks += 1
                if
                    silentChunks == Self.earlyBridgePauseSilenceChunkCount,
                    !hasPublishedEarlyBridgePause
                {
                    hasPublishedEarlyBridgePause = true
                    publishEarlyBridgePause(lastVoicedAt ?? receivedAt)
                }
                if
                    silentChunks == Self.assistantPauseSilenceChunkCount,
                    !hasPublishedSpeechPause
                {
                    hasPublishedSpeechPause = true
                    publishSpeechPause(lastVoicedAt ?? receivedAt)
                }
                if silentChunks >= speechEndSilenceChunkCount {
                    commitActiveTurn(at: lastVoicedAt ?? receivedAt)
                }
            }
            return
        }

        if !isVoiced {
            noiseFloor = noiseFloor * 0.98 + rms * 0.02
        }
        preRoll.append(data)
        if preRoll.count > preRollChunkCount {
            preRoll.removeFirst(preRoll.count - preRollChunkCount)
        }

        if isVoiced {
            consecutiveVoicedChunks += 1
        } else {
            consecutiveVoicedChunks = 0
        }

        guard consecutiveVoicedChunks >= speechOnsetChunkCount else { return }
        activeTurnStartedAt = receivedAt.addingTimeInterval(
            -Double(preRoll.count) * 0.02
        )
        lastVoicedAt = receivedAt
        silentChunks = 0
        hasPublishedEarlyBridgePause = false
        hasPublishedSpeechPause = false
        activeTurnAudio.removeAll(keepingCapacity: true)
        for bufferedChunk in preRoll {
            enqueueAudio(bufferedChunk)
            activeTurnAudio.append(bufferedChunk)
        }
        activeTurnLastVoicedByteCount = activeTurnAudio.count
        preRoll.removeAll(keepingCapacity: true)
    }

    private func enqueueAudio(_ data: Data) {
        let audioCount = outbound.lazy.filter(\.isAudio).count
        if audioCount >= maximumQueuedAudioChunks,
           let oldestAudio = outbound.firstIndex(where: \.isAudio) {
            outbound.remove(at: oldestAudio)
        }
        let encoded = data.base64EncodedString()
        let text = #"{"type":"input_audio_buffer.append","audio":"\#(encoded)"}"#
        outbound.append(OutboundMessage(text: text, isAudio: true))
        pumpSendQueue()
    }

    private func commitActiveTurn(at endedAt: Date) {
        guard let startedAt = activeTurnStartedAt else { return }
        enqueue(
            #"{"type":"input_audio_buffer.commit"}"#,
            isAudio: false,
            priority: false
        )
        let retainedByteCount = min(
            activeTurnAudio.count,
            activeTurnLastVoicedByteCount + retainedPostRollChunkCount * 960
        )
        pendingTurns.append(
            CommittedTurn(
                startedAt: startedAt,
                endedAt: endedAt,
                pcm16Audio: Data(activeTurnAudio.prefix(retainedByteCount)),
                submittedAudioSeconds: Double(activeTurnAudio.count)
                    / Double(Self.pcm16BytesPerSecond)
            )
        )
        activeTurnStartedAt = nil
        lastVoicedAt = nil
        consecutiveVoicedChunks = 0
        silentChunks = 0
        hasPublishedEarlyBridgePause = false
        hasPublishedSpeechPause = false
        activeTurnAudio.removeAll(keepingCapacity: true)
        activeTurnLastVoicedByteCount = 0
        preRoll.removeAll(keepingCapacity: true)
    }

    private func pumpSendQueue() {
        guard isOpen, !isSending, !outbound.isEmpty, let task else { return }
        let next = outbound.removeFirst()
        isSending = true
        task.send(.string(next.text)) { [weak self] error in
            self?.socketQueue.async {
                guard let self else { return }
                self.isSending = false
                if let error {
                    self.publishState(.failed(error.localizedDescription))
                }
                self.pumpSendQueue()
            }
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
                            RealtimeServerEvent.parse(data),
                            completionUsage: TranscriptionCompletionUsage.parse(
                                from: data
                            )
                        )
                    }
                    self.receiveNext()

                case let .failure(error):
                    if self.task != nil {
                        self.publishState(.failed(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func handle(
        _ event: RealtimeServerEvent,
        completionUsage: TranscriptionCompletionUsage?
    ) {
        switch event {
        case let .transcriptionDelta(itemID, delta):
            partials[itemID, default: ""].append(delta)
            publishPartial(itemID: itemID, text: partials[itemID, default: ""])

        case let .transcriptionCompleted(itemID, transcript):
            partials[itemID] = nil
            publishPartial(itemID: itemID, text: "")
            let turn = committedTurns.removeValue(forKey: itemID)
            if let audioSeconds = completionUsage?.seconds
                ?? turn?.submittedAudioSeconds {
                publishUsage(
                    OpenAITranscriptionUsageRecord(
                        pass: .live,
                        model: Self.model,
                        audioSeconds: audioSeconds,
                        measurement: completionUsage?.seconds == nil
                            ? .submittedAudioEstimate
                            : .serverReported
                    )
                )
            }
            publishFinal(
                itemID: itemID,
                transcript: transcript,
                startedAt: turn?.startedAt ?? Date(),
                endedAt: turn?.endedAt,
                pcm16Audio: turn?.pcm16Audio ?? Data()
            )

        case .speechStarted, .speechStopped:
            // This client uses explicit commits because gpt-live-transcribe
            // currently rejects server turn detection.
            break

        case let .audioCommitted(itemID):
            if !pendingTurns.isEmpty {
                committedTurns[itemID] = pendingTurns.removeFirst()
            }

        case .sessionReady:
            break

        case let .error(message):
            publishState(.failed(message))

        case .ignored:
            break
        }
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

    private func publishState(_ state: SocketState) {
        DispatchQueue.main.async { [stateHandler] in
            stateHandler(state)
        }
    }

    private func publishPartial(itemID: String, text: String) {
        DispatchQueue.main.async { [partialHandler] in
            partialHandler(itemID, text)
        }
    }

    private func publishFinal(
        itemID: String,
        transcript: String,
        startedAt: Date,
        endedAt: Date?,
        pcm16Audio: Data
    ) {
        DispatchQueue.main.async { [finalHandler] in
            finalHandler(itemID, transcript, startedAt, endedAt, pcm16Audio)
        }
    }

    private func publishUsage(_ usage: OpenAITranscriptionUsageRecord) {
        DispatchQueue.main.async { [usageHandler] in
            usageHandler(usage)
        }
    }

    private func publishSpeechPause(_ speechEndedAt: Date) {
        DispatchQueue.main.async { [speechPauseHandler] in
            speechPauseHandler(speechEndedAt)
        }
    }

    private func publishEarlyBridgePause(_ speechEndedAt: Date) {
        DispatchQueue.main.async { [earlyBridgePauseHandler] in
            earlyBridgePauseHandler(speechEndedAt)
        }
    }

    static func sessionUpdateJSON(_ context: TranscriptionContext) throws -> Data {
        var transcription: [String: Any] = [
            "model": model,
            "delay": context.delay.rawValue
        ]
        if !context.prompt.isEmpty {
            transcription["prompt"] = context.prompt
        }
        if !context.keywords.isEmpty {
            transcription["keywords"] = context.keywords
        }
        if !context.languages.isEmpty {
            transcription["languages"] = context.languages
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
}

extension RealtimeTranscriptionClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        socketQueue.async { [weak self] in
            guard let self, webSocketTask == self.task else { return }
            self.isOpen = true
            do {
                let data = try Self.sessionUpdateJSON(self.context)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw PUnderclassError.audio("Could not encode the Realtime session.")
                }
                self.enqueue(text, isAudio: false, priority: true)
                self.publishState(.connected)
            } catch {
                self.publishState(.failed(error.localizedDescription))
            }
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
            self.isOpen = false
            self.publishState(.idle)
        }
    }
}

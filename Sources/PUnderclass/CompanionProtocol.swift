import Foundation

enum CompanionJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    static func wrapping<T: Encodable>(_ value: T) -> JSONValue {
        do {
            let data = try CompanionJSON.encoder().encode(value)
            return try CompanionJSON.decoder().decode(JSONValue.self, from: data)
        } catch {
            return .object([
                "encodingError": .string(error.localizedDescription)
            ])
        }
    }
}

struct CompanionCursor: Codable, Equatable, Sendable, CustomStringConvertible {
    let streamID: String
    let sequence: Int

    var description: String { "\(streamID):\(sequence)" }

    init(streamID: String, sequence: Int) {
        self.streamID = streamID
        self.sequence = sequence
    }

    init?(description: String) {
        guard
            let separator = description.lastIndex(of: ":"),
            separator != description.startIndex,
            let sequence = Int(description[description.index(after: separator)...]),
            sequence >= 0
        else {
            return nil
        }
        self.streamID = String(description[..<separator])
        self.sequence = sequence
    }
}

struct CompanionSessionState: Codable, Equatable, Sendable {
    var isListening = false
    var status = "Ready"
    var behaviorName = "Answer mirror"
    var behaviorDetail = "Show 3–5 shorthand beats when the interviewer pauses"
    var assistantAvailable = true
    var suggestionsPaused = false
    var startedAt: Date?
    var endedAt: Date?
    var purpose: CapturePurpose?
    var source: CompanionSessionSource?
    var title: String?
    var isPreparingSyntheticInterview = false
    var answerMode: AssistantAnswerMode = .grounded
    var earlyBridgeEnabled = false
}

enum CompanionSessionSource: String, Codable, Equatable, Sendable {
    case liveCapture
    case syntheticInterview
}

struct CompanionTranscriptTurn: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let speaker: String
    let text: String
    let startedAt: Date
    let endedAt: Date?
    let isRefined: Bool
}

struct CompanionTranscriptPartial: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let speaker: String
    let text: String
}

struct CompanionTranscriptState: Codable, Equatable, Sendable {
    var turns: [CompanionTranscriptTurn] = []
    var partials: [CompanionTranscriptPartial] = []
}

struct CompanionReferenceState: Codable, Equatable, Sendable {
    var configured = false
    var folderName = "No reference folder"
    var phase = "notConfigured"
    var documentCount = 0
    var revision = ""
    var isWatching = false
    var issueCount = 0
}

struct CompanionUsageState: Codable, Equatable, Sendable {
    var estimatedTranscriptionCostUSD = 0.0
    var estimatedLiveTranscriptionCostUSD = 0.0
    var estimatedFinalTranscriptionCostUSD = 0.0
    var liveAudioSeconds = 0.0
    var finalAudioSeconds = 0.0
    var assistantGenerations = 0
    var assistantModelCalls = 0
    var assistantGroundingRepairAttempts = 0
    var assistantGroundingRepairSuccesses = 0
    var assistantGroundingRepairMilliseconds = 0
    var assistantInputTokens = 0
    var assistantCachedInputTokens = 0
    var assistantCacheWriteTokens = 0
    var assistantOutputTokens = 0
    var assistantReasoningTokens = 0
}

struct CompanionCitation: Codable, Equatable, Sendable {
    let label: String
    let path: String
}

struct CompanionAnswerBeat: Codable, Equatable, Sendable {
    let label: String
    let point: String
}

struct CompanionPlausibleRehearsalPlan: Codable, Equatable, Sendable {
    let projectAnchor: String
    let observedSignal: String
    let mechanismChange: String
    let discriminatingCheck: String
    let boundedOutcome: String
}

enum CompanionSuggestionConfidence: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

enum CompanionSuggestionGrounding: String, Codable, Equatable, Sendable {
    case localReferences
    case webSearch
    case generalKnowledge
}

enum AssistantAnswerMode: String, Codable, Equatable, Sendable, CaseIterable {
    case grounded
    case plausibleRehearsal

    var title: String {
        switch self {
        case .grounded:
            "Grounded"
        case .plausibleRehearsal:
            "Plausible rehearsal"
        }
    }
}

enum CompanionAssistantTrigger: String, Codable, Equatable, Sendable {
    case partialTranscript
    case finalizedTurn
}

struct CompanionAssistantSuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let basedOnSequence: Int
    let question: String
    var preamble: String? = nil
    let beats: [CompanionAnswerBeat]
    let citations: [CompanionCitation]
    let grounding: CompanionSuggestionGrounding
    let confidence: CompanionSuggestionConfidence
    let generatedAt: Date
    let generationMilliseconds: Int
    var trigger: CompanionAssistantTrigger?
    var triggeredAt: Date?
    var totalLatencyMilliseconds: Int?
    var topicID: String?
    var topicNumber: Int?
    var inferenceOutcome: CompanionInferenceOutcome? = nil
    var groundingRepairMilliseconds: Int? = nil
    var answerMode: AssistantAnswerMode = .grounded
    var plausibleAssumptions: [String] = []
    var plausibleRehearsalPlan: CompanionPlausibleRehearsalPlan? = nil
}

enum CompanionAssistantPhase: String, Codable, Equatable, Sendable {
    case idle
    case working
    case ready
    case failed
    case unavailable
}

enum CompanionInferenceOutcome: String, Codable, Equatable, Sendable {
    case suggestion
    case notAnswerable
    case repairedGrounding
    case invalidGrounding
    case cancelled
    case failed
}

struct CompanionAssistantBridge: Codable, Equatable, Sendable {
    let id: String
    let topicID: String
    let sourceText: String
    let text: String
    let generatedAt: Date
    let generationMilliseconds: Int
}

struct CompanionAssistantState: Codable, Equatable, Sendable {
    var phase: CompanionAssistantPhase = .idle
    var bridge: CompanionAssistantBridge?
    var suggestion: CompanionAssistantSuggestion?
    var suggestionHistory: [CompanionAssistantSuggestion] = []
    var lastError: String?
    var pinnedSuggestionID: String?
    var evaluatingSequence: Int?
    var evaluatingTrigger: CompanionAssistantTrigger?
    var evaluationTriggeredAt: Date?
    var evaluationStartedAt: Date?
    var lastEvaluatedSequence: Int?
    var lastEvaluationAt: Date?
    var lastEvaluationOutcome: CompanionInferenceOutcome?
    var lastEvaluationTrigger: CompanionAssistantTrigger?
    var lastEvaluationLatencyMilliseconds: Int?
}

struct CompanionAssistantWorking: Codable, Equatable, Sendable {
    let basedOnSequence: Int
    let trigger: CompanionAssistantTrigger
    let triggeredAt: Date
    let startedAt: Date
}

struct CompanionSnapshot: Codable, Equatable, Sendable {
    let v: Int
    let streamID: String
    var watermark: Int
    var generatedAt: Date
    var session: CompanionSessionState
    var transcript: CompanionTranscriptState
    var reference: CompanionReferenceState
    var usage: CompanionUsageState
    var assistant: CompanionAssistantState

    enum CodingKeys: String, CodingKey {
        case v
        case streamID = "streamId"
        case watermark
        case generatedAt
        case session
        case transcript
        case reference
        case usage
        case assistant
    }
}

struct CompanionEvent: Codable, Equatable, Sendable {
    let v: Int
    let streamID: String
    let sequence: Int
    let emittedAt: Date
    let name: String
    let payload: JSONValue

    var cursor: CompanionCursor {
        CompanionCursor(streamID: streamID, sequence: sequence)
    }

    enum CodingKeys: String, CodingKey {
        case v
        case streamID = "streamId"
        case sequence
        case emittedAt
        case name
        case payload
    }
}

enum CompanionStreamItem: Equatable, Sendable {
    case event(CompanionEvent)
    case heartbeat(Date)
}

enum CompanionCommandType: String, Codable, Equatable, Sendable {
    case pauseSuggestions
    case resumeSuggestions
    case pinSuggestion
    case unpinSuggestion
    case dismissSuggestion
}

struct CompanionCommandRequest: Codable, Equatable, Sendable {
    let type: CompanionCommandType
    let suggestionID: String?
}

struct CompanionCommandResponse: Codable, Equatable, Sendable {
    let idempotencyKey: String
    let applied: Bool
    let message: String
    let watermark: Int
}

actor CompanionEventHub {
    private static let suggestionHistoryLimit = 4

    let streamID: String
    private let bufferCapacity: Int
    private var sequence = 0
    private var buffer: [CompanionEvent] = []
    private var subscribers: [UUID: AsyncStream<CompanionStreamItem>.Continuation] = [:]
    private var commandResults: [String: CompanionCommandResponse] = [:]
    private var commandResultOrder: [String] = []
    private var topicCount = 0
    private var topicNumbersByID: [String: Int] = [:]
    private var state: CompanionSnapshot

    init(
        streamID: String = UUID().uuidString.lowercased(),
        bufferCapacity: Int = 10_000
    ) {
        self.streamID = streamID
        self.bufferCapacity = max(1, bufferCapacity)
        self.state = CompanionSnapshot(
            v: 1,
            streamID: streamID,
            watermark: 0,
            generatedAt: Date(),
            session: CompanionSessionState(),
            transcript: CompanionTranscriptState(),
            reference: CompanionReferenceState(),
            usage: CompanionUsageState(),
            assistant: CompanionAssistantState()
        )
    }

    func snapshot() -> CompanionSnapshot {
        state
    }

    func currentWatermark() -> Int {
        sequence
    }

    func suggestionsPaused() -> Bool {
        state.session.suggestionsPaused
    }

    @discardableResult
    func updateSession(
        isListening: Bool,
        status: String,
        purpose: CapturePurpose? = nil,
        source: CompanionSessionSource = .liveCapture,
        title: String? = nil,
        isPreparingSyntheticInterview: Bool = false,
        answerMode: AssistantAnswerMode = .grounded,
        earlyBridgeEnabled: Bool = false,
        assistantAvailable: Bool = true
    ) -> CompanionEvent {
        if isListening, !state.session.isListening {
            state.session.startedAt = Date()
            state.session.endedAt = nil
        } else if !isListening, state.session.isListening {
            state.session.endedAt = Date()
        }
        state.session.isListening = isListening
        state.session.status = status
        state.session.purpose = purpose
        state.session.source = source
        state.session.title = title
        state.session.isPreparingSyntheticInterview =
            isPreparingSyntheticInterview
        state.session.assistantAvailable = assistantAvailable
        state.session.answerMode = purpose == .interview
            ? answerMode
            : .grounded
        state.session.earlyBridgeEnabled = purpose == .interview
            && answerMode == .plausibleRehearsal
            && earlyBridgeEnabled
        if !assistantAvailable {
            state.session.behaviorName = "Local transcript"
            state.session.behaviorDetail =
                "Completed turns are transcribed on this Mac; OpenAI response cues are off"
        } else {
            switch purpose {
            case .meeting:
                state.session.behaviorName = "Meeting assistant"
                state.session.behaviorDetail =
                    "Ground concise response cues in the meeting references"
            case .interview:
                state.session.behaviorName = "Answer mirror"
                if state.session.earlyBridgeEnabled {
                    state.session.behaviorDetail =
                        "Show an experimental early bridge, then a plausible rehearsal draft"
                } else {
                    state.session.behaviorDetail = answerMode == .plausibleRehearsal
                        ? "Draft plausible, project-specific rehearsal answers to verify"
                        : "Show grounded shorthand beats when the interviewer pauses"
                }
            case nil:
                state.session.behaviorName = "Answer mirror"
                state.session.behaviorDetail =
                    "Show 3–5 shorthand beats when the interviewer pauses"
            }
        }
        return publish(name: "session.status", payload: state.session)
    }

    @discardableResult
    func updatePartial(_ partial: CompanionTranscriptPartial) -> CompanionEvent {
        state.transcript.partials.removeAll { $0.id == partial.id }
        if !partial.text.isEmpty {
            state.transcript.partials.append(partial)
        }
        return publish(name: "transcript.partial", payload: partial)
    }

    @discardableResult
    func appendFinal(_ turn: CompanionTranscriptTurn) -> CompanionEvent {
        state.transcript.turns.removeAll { $0.id == turn.id }
        state.transcript.turns.append(turn)
        state.transcript.turns.sort {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt < $1.startedAt
        }
        state.transcript.partials.removeAll { $0.id == turn.id }
        return publish(name: "transcript.final", payload: turn)
    }

    @discardableResult
    func revise(_ turn: CompanionTranscriptTurn) -> CompanionEvent {
        if let index = state.transcript.turns.firstIndex(where: { $0.id == turn.id }) {
            state.transcript.turns[index] = turn
        } else {
            state.transcript.turns.append(turn)
        }
        return publish(name: "transcript.revised", payload: turn)
    }

    @discardableResult
    func clearTranscript() -> CompanionEvent {
        state.transcript = CompanionTranscriptState()
        let event = publish(name: "transcript.cleared", payload: state.transcript)
        state.assistant = CompanionAssistantState()
        topicCount = 0
        topicNumbersByID.removeAll()
        _ = publish(name: "assistant.state", payload: state.assistant)
        return event
    }

    @discardableResult
    func updateReference(_ reference: CompanionReferenceState) -> CompanionEvent {
        state.reference = reference
        return publish(name: "reference.status", payload: reference)
    }

    @discardableResult
    func updateUsage(_ usage: CompanionUsageState) -> CompanionEvent {
        state.usage = usage
        return publish(name: "usage.updated", payload: usage)
    }

    @discardableResult
    func assistantWorking(
        basedOnSequence: Int,
        trigger: CompanionAssistantTrigger = .finalizedTurn,
        triggeredAt: Date = Date(),
        startedAt: Date = Date()
    ) -> CompanionEvent {
        state.assistant.phase = .working
        state.assistant.lastError = nil
        state.assistant.evaluatingSequence = basedOnSequence
        state.assistant.evaluatingTrigger = trigger
        state.assistant.evaluationTriggeredAt = triggeredAt
        state.assistant.evaluationStartedAt = startedAt
        return publish(
            name: "assistant.working",
            payload: CompanionAssistantWorking(
                basedOnSequence: basedOnSequence,
                trigger: trigger,
                triggeredAt: triggeredAt,
                startedAt: startedAt
            )
        )
    }

    @discardableResult
    func assistantBridged(
        _ bridge: CompanionAssistantBridge
    ) -> CompanionEvent {
        state.assistant.bridge = bridge
        return publish(name: "assistant.bridge", payload: bridge)
    }

    @discardableResult
    func assistantSupersededForNewTurn() -> CompanionEvent {
        state.assistant.phase = state.assistant.suggestion == nil
            ? .idle
            : .ready
        state.assistant.bridge = nil
        state.assistant.lastError = nil
        state.assistant.evaluatingSequence = nil
        state.assistant.evaluatingTrigger = nil
        state.assistant.evaluationTriggeredAt = nil
        state.assistant.evaluationStartedAt = nil
        return publish(name: "assistant.state", payload: state.assistant)
    }

    @discardableResult
    func assistantSuggested(
        _ suggestion: CompanionAssistantSuggestion,
        outcome: CompanionInferenceOutcome? = nil
    ) -> CompanionEvent {
        var numberedSuggestion = suggestion
        let evaluationOutcome = outcome
            ?? suggestion.inferenceOutcome
            ?? .suggestion
        numberedSuggestion.inferenceOutcome = evaluationOutcome
        let topicID = suggestion.topicID ?? suggestion.id
        if let existingTopicNumber = topicNumbersByID[topicID] {
            numberedSuggestion.topicNumber = existingTopicNumber
        } else {
            topicCount += 1
            numberedSuggestion.topicNumber = topicCount
            topicNumbersByID[topicID] = topicCount
        }
        state.assistant.phase = .ready
        state.assistant.bridge = nil
        state.assistant.suggestion = numberedSuggestion
        state.assistant.suggestionHistory.removeAll {
            $0.id == numberedSuggestion.id
        }
        state.assistant.suggestionHistory.insert(numberedSuggestion, at: 0)
        if state.assistant.suggestionHistory.count
            > Self.suggestionHistoryLimit
        {
            state.assistant.suggestionHistory.removeLast(
                state.assistant.suggestionHistory.count
                    - Self.suggestionHistoryLimit
            )
        }
        state.assistant.lastError = nil
        state.assistant.evaluatingSequence = nil
        state.assistant.evaluatingTrigger = nil
        state.assistant.evaluationTriggeredAt = nil
        state.assistant.evaluationStartedAt = nil
        state.assistant.lastEvaluatedSequence = numberedSuggestion.basedOnSequence
        state.assistant.lastEvaluationAt = numberedSuggestion.generatedAt
        state.assistant.lastEvaluationOutcome = evaluationOutcome
        state.assistant.lastEvaluationTrigger = numberedSuggestion.trigger
        state.assistant.lastEvaluationLatencyMilliseconds =
            numberedSuggestion.totalLatencyMilliseconds
        return publish(name: "assistant.suggestion", payload: numberedSuggestion)
    }

    @discardableResult
    func assistantFinishedWithoutSuggestion(
        basedOnSequence: Int,
        trigger: CompanionAssistantTrigger? = nil,
        triggeredAt: Date? = nil,
        completedAt: Date = Date(),
        outcome: CompanionInferenceOutcome = .notAnswerable
    ) -> CompanionEvent {
        let evaluationTrigger = trigger ?? state.assistant.evaluatingTrigger
        let evaluationTriggeredAt = triggeredAt
            ?? state.assistant.evaluationTriggeredAt
        state.assistant.phase = .idle
        state.assistant.bridge = nil
        state.assistant.lastError = nil
        state.assistant.evaluatingSequence = nil
        state.assistant.evaluatingTrigger = nil
        state.assistant.evaluationTriggeredAt = nil
        state.assistant.evaluationStartedAt = nil
        state.assistant.lastEvaluatedSequence = basedOnSequence
        state.assistant.lastEvaluationAt = completedAt
        state.assistant.lastEvaluationOutcome = outcome
        state.assistant.lastEvaluationTrigger = evaluationTrigger
        state.assistant.lastEvaluationLatencyMilliseconds =
            evaluationTriggeredAt.map {
                Self.milliseconds(from: $0, to: completedAt)
            }
        return publish(name: "assistant.state", payload: state.assistant)
    }

    @discardableResult
    func assistantFailed(
        _ message: String,
        unavailable: Bool = false,
        outcome: CompanionInferenceOutcome = .failed
    ) -> CompanionEvent {
        state.assistant.phase = unavailable ? .unavailable : .failed
        state.assistant.bridge = nil
        state.assistant.lastError = message
        if !unavailable, let sequence = state.assistant.evaluatingSequence {
            state.assistant.lastEvaluatedSequence = sequence
            state.assistant.lastEvaluationAt = Date()
            state.assistant.lastEvaluationOutcome = outcome
            state.assistant.lastEvaluationTrigger =
                state.assistant.evaluatingTrigger
            if let triggeredAt = state.assistant.evaluationTriggeredAt {
                state.assistant.lastEvaluationLatencyMilliseconds =
                    Self.milliseconds(from: triggeredAt, to: Date())
            }
        }
        state.assistant.evaluatingSequence = nil
        state.assistant.evaluatingTrigger = nil
        state.assistant.evaluationTriggeredAt = nil
        state.assistant.evaluationStartedAt = nil
        return publish(
            name: "assistant.failed",
            payload: [
                "message": message,
                "phase": state.assistant.phase.rawValue,
                "outcome": outcome.rawValue
            ]
        )
    }

    private static func milliseconds(from startedAt: Date, to endedAt: Date) -> Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000))
    }

    func subscribe(after cursor: CompanionCursor?) -> AsyncStream<CompanionStreamItem> {
        let pair = AsyncStream<CompanionStreamItem>.makeStream(
            bufferingPolicy: .bufferingNewest(1_000)
        )

        if let resetReason = replayResetReason(for: cursor) {
            pair.continuation.yield(.event(resetEvent(reason: resetReason)))
            pair.continuation.finish()
            return pair.stream
        }

        let subscriberID = UUID()
        if let cursor {
            let replay = buffer.filter { $0.sequence > cursor.sequence }
            if replay.count > 1_000 {
                pair.continuation.yield(
                    .event(resetEvent(reason: "clientReplayLimitExceeded"))
                )
                pair.continuation.finish()
                return pair.stream
            }
            for event in replay {
                pair.continuation.yield(.event(event))
            }
        }
        subscribers[subscriberID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }
        return pair.stream
    }

    func heartbeat(at date: Date = Date()) {
        var overflowed: [UUID] = []
        for (id, continuation) in subscribers {
            if case .dropped = continuation.yield(.heartbeat(date)) {
                continuation.finish()
                overflowed.append(id)
            }
        }
        for id in overflowed {
            subscribers.removeValue(forKey: id)
        }
    }

    func apply(
        command: CompanionCommandRequest,
        idempotencyKey: String
    ) -> CompanionCommandResponse {
        if let previous = commandResults[idempotencyKey] {
            return previous
        }

        let result: (Bool, String)
        switch command.type {
        case .pauseSuggestions:
            state.session.suggestionsPaused = true
            _ = publish(name: "session.status", payload: state.session)
            result = (true, "Live answer outlines paused")
        case .resumeSuggestions:
            state.session.suggestionsPaused = false
            _ = publish(name: "session.status", payload: state.session)
            result = (true, "Live answer outlines resumed")
        case .pinSuggestion:
            if
                let suggestionID = command.suggestionID,
                state.assistant.suggestion?.id == suggestionID
            {
                state.assistant.pinnedSuggestionID = suggestionID
                _ = publish(name: "assistant.state", payload: state.assistant)
                result = (true, "Answer outline pinned")
            } else {
                result = (false, "That answer outline is no longer current")
            }
        case .unpinSuggestion:
            state.assistant.pinnedSuggestionID = nil
            _ = publish(name: "assistant.state", payload: state.assistant)
            result = (true, "Answer outline unpinned")
        case .dismissSuggestion:
            if
                command.suggestionID == nil
                    || state.assistant.suggestion?.id == command.suggestionID
            {
                if let currentID = state.assistant.suggestion?.id {
                    state.assistant.suggestionHistory.removeAll {
                        $0.id == currentID
                    }
                }
                state.assistant.suggestion =
                    state.assistant.suggestionHistory.first
                state.assistant.phase = state.assistant.suggestion == nil
                    ? .idle
                    : .ready
                state.assistant.pinnedSuggestionID = nil
                _ = publish(name: "assistant.state", payload: state.assistant)
                result = (true, "Answer outline dismissed")
            } else {
                result = (false, "That answer outline is no longer current")
            }
        }

        let response = CompanionCommandResponse(
            idempotencyKey: idempotencyKey,
            applied: result.0,
            message: result.1,
            watermark: sequence
        )
        commandResults[idempotencyKey] = response
        commandResultOrder.append(idempotencyKey)
        if commandResultOrder.count > 512 {
            let discarded = commandResultOrder.removeFirst()
            commandResults.removeValue(forKey: discarded)
        }
        return response
    }

    private func publish<T: Encodable>(name: String, payload: T) -> CompanionEvent {
        sequence += 1
        let now = Date()
        let event = CompanionEvent(
            v: 1,
            streamID: streamID,
            sequence: sequence,
            emittedAt: now,
            name: name,
            payload: .wrapping(payload)
        )
        buffer.append(event)
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
        state.watermark = sequence
        state.generatedAt = now
        var overflowed: [UUID] = []
        for (id, continuation) in subscribers {
            if case .dropped = continuation.yield(.event(event)) {
                continuation.finish()
                overflowed.append(id)
            }
        }
        for id in overflowed {
            subscribers.removeValue(forKey: id)
        }
        return event
    }

    private func replayResetReason(for cursor: CompanionCursor?) -> String? {
        guard let cursor else { return nil }
        guard cursor.streamID == streamID else { return "producerRestarted" }
        guard cursor.sequence <= sequence else { return "cursorAheadOfProducer" }
        guard let oldest = buffer.first?.sequence else { return nil }
        guard cursor.sequence >= oldest - 1 else { return "replayWindowExpired" }
        return nil
    }

    private func resetEvent(reason: String) -> CompanionEvent {
        CompanionEvent(
            v: 1,
            streamID: streamID,
            sequence: sequence,
            emittedAt: Date(),
            name: "stream.reset",
            payload: .object(["reason": .string(reason)])
        )
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

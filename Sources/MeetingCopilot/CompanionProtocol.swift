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
    var behaviorName = "Interview wingman"
    var behaviorDetail = "Check both speakers; label local versus general support"
    var suggestionsPaused = false
    var startedAt: Date?
    var endedAt: Date?
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
    var assistantInputTokens = 0
    var assistantCachedInputTokens = 0
    var assistantCacheWriteTokens = 0
    var assistantOutputTokens = 0
    var assistantReasoningTokens = 0
}

struct CompanionTalkingPoint: Codable, Equatable, Sendable {
    let title: String
    let body: String
}

struct CompanionProofPoint: Codable, Equatable, Sendable {
    let value: String
    let label: String
}

struct CompanionCitation: Codable, Equatable, Sendable {
    let label: String
    let path: String
}

enum CompanionSuggestionConfidence: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

enum CompanionSuggestionGrounding: String, Codable, Equatable, Sendable {
    case localReferences
    case generalKnowledge
}

struct CompanionAssistantSuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let basedOnSequence: Int
    let question: String
    let lead: String
    let talkingPoints: [CompanionTalkingPoint]
    let proof: [CompanionProofPoint]
    let watchoutTitle: String
    let watchoutBody: String
    let followup: String
    let citations: [CompanionCitation]
    let grounding: CompanionSuggestionGrounding
    let confidence: CompanionSuggestionConfidence
    let generatedAt: Date
    let generationMilliseconds: Int
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
    case noSuggestion
    case failed
}

struct CompanionAssistantState: Codable, Equatable, Sendable {
    var phase: CompanionAssistantPhase = .idle
    var suggestion: CompanionAssistantSuggestion?
    var lastError: String?
    var pinnedSuggestionID: String?
    var evaluatingSequence: Int?
    var lastEvaluatedSequence: Int?
    var lastEvaluationAt: Date?
    var lastEvaluationOutcome: CompanionInferenceOutcome?
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
    let streamID: String
    private let bufferCapacity: Int
    private var sequence = 0
    private var buffer: [CompanionEvent] = []
    private var subscribers: [UUID: AsyncStream<CompanionStreamItem>.Continuation] = [:]
    private var commandResults: [String: CompanionCommandResponse] = [:]
    private var commandResultOrder: [String] = []
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
    func updateSession(isListening: Bool, status: String) -> CompanionEvent {
        if isListening, !state.session.isListening {
            state.session.startedAt = Date()
            state.session.endedAt = nil
        } else if !isListening, state.session.isListening {
            state.session.endedAt = Date()
        }
        state.session.isListening = isListening
        state.session.status = status
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
    func assistantWorking(basedOnSequence: Int) -> CompanionEvent {
        state.assistant.phase = .working
        state.assistant.lastError = nil
        state.assistant.evaluatingSequence = basedOnSequence
        return publish(
            name: "assistant.working",
            payload: ["basedOnSequence": basedOnSequence]
        )
    }

    @discardableResult
    func assistantSuggested(_ suggestion: CompanionAssistantSuggestion) -> CompanionEvent {
        state.assistant.phase = .ready
        state.assistant.suggestion = suggestion
        state.assistant.lastError = nil
        state.assistant.evaluatingSequence = nil
        state.assistant.lastEvaluatedSequence = suggestion.basedOnSequence
        state.assistant.lastEvaluationAt = suggestion.generatedAt
        state.assistant.lastEvaluationOutcome = .suggestion
        return publish(name: "assistant.suggestion", payload: suggestion)
    }

    @discardableResult
    func assistantFinishedWithoutSuggestion(basedOnSequence: Int) -> CompanionEvent {
        state.assistant.phase = .idle
        state.assistant.lastError = nil
        state.assistant.evaluatingSequence = nil
        state.assistant.lastEvaluatedSequence = basedOnSequence
        state.assistant.lastEvaluationAt = Date()
        state.assistant.lastEvaluationOutcome = .noSuggestion
        if state.assistant.pinnedSuggestionID == nil {
            state.assistant.suggestion = nil
        }
        return publish(name: "assistant.state", payload: state.assistant)
    }

    @discardableResult
    func assistantFailed(_ message: String, unavailable: Bool = false) -> CompanionEvent {
        state.assistant.phase = unavailable ? .unavailable : .failed
        state.assistant.lastError = message
        if !unavailable, let sequence = state.assistant.evaluatingSequence {
            state.assistant.lastEvaluatedSequence = sequence
            state.assistant.lastEvaluationAt = Date()
            state.assistant.lastEvaluationOutcome = .failed
        }
        state.assistant.evaluatingSequence = nil
        return publish(
            name: "assistant.failed",
            payload: [
                "message": message,
                "phase": state.assistant.phase.rawValue
            ]
        )
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
            result = (true, "Live suggestions paused")
        case .resumeSuggestions:
            state.session.suggestionsPaused = false
            _ = publish(name: "session.status", payload: state.session)
            result = (true, "Live suggestions resumed")
        case .pinSuggestion:
            if
                let suggestionID = command.suggestionID,
                state.assistant.suggestion?.id == suggestionID
            {
                state.assistant.pinnedSuggestionID = suggestionID
                _ = publish(name: "assistant.state", payload: state.assistant)
                result = (true, "Suggestion pinned")
            } else {
                result = (false, "That suggestion is no longer current")
            }
        case .unpinSuggestion:
            state.assistant.pinnedSuggestionID = nil
            _ = publish(name: "assistant.state", payload: state.assistant)
            result = (true, "Suggestion unpinned")
        case .dismissSuggestion:
            if
                command.suggestionID == nil
                    || state.assistant.suggestion?.id == command.suggestionID
            {
                state.assistant.suggestion = nil
                state.assistant.phase = .idle
                state.assistant.pinnedSuggestionID = nil
                _ = publish(name: "assistant.state", payload: state.assistant)
                result = (true, "Suggestion dismissed")
            } else {
                result = (false, "That suggestion is no longer current")
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

import CoreAudio
import Foundation

enum SpeakerTag: String, Codable, Hashable {
    case you = "You"
    case other = "Other"
}

struct TranscriptTurn: Identifiable, Equatable {
    let id: String
    let speaker: SpeakerTag
    let startedAt: Date
    let endedAt: Date?
    let liveText: String
    var text: String
    var refinement: TranscriptRefinementState
}

enum TranscriptRefinementState: Equatable {
    case refining
    case refined
    case liveOnly(String?)
}

enum TranscriptRefinementEngine: String, CaseIterable, Identifiable {
    case localParakeet
    case openAITranscribe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localParakeet:
            "Local Parakeet"
        case .openAITranscribe:
            "OpenAI GPT-Transcribe"
        }
    }

    var modelName: String {
        switch self {
        case .localParakeet:
            ParakeetRefinementClient.modelDescription
        case .openAITranscribe:
            RealtimeRefinementClient.model
        }
    }

    var systemImage: String {
        switch self {
        case .localParakeet:
            "desktopcomputer"
        case .openAITranscribe:
            "cloud"
        }
    }

    var purpose: String {
        switch self {
        case .localParakeet:
            "Finalizes meeting turns and runs Quick Dictation privately on this Mac."
        case .openAITranscribe:
            "Finalizes meeting turns and runs Quick Dictation in the cloud."
        }
    }

    var detail: String {
        switch self {
        case .localParakeet:
            "Parakeet TDT v3 runs directly inside PUnderclass through Core ML."
        case .openAITranscribe:
            "Each bounded turn is transcribed again by the high-accuracy GPT-Transcribe model."
        }
    }
}

enum ParakeetPreparationStage: Equatable, Sendable {
    case idle
    case checkingCache
    case downloading(fractionCompleted: Double)
    case loading(component: String)
    case ready
    case failed(String)
}

struct ParakeetPreparationState: Equatable, Sendable {
    var stage: ParakeetPreparationStage = .idle
    var startedAt: Date?
    var finishedAt: Date?

    var isInProgress: Bool {
        switch stage {
        case .checkingCache, .downloading, .loading:
            true
        case .idle, .ready, .failed:
            false
        }
    }

    var isReady: Bool {
        stage == .ready
    }

    var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    var downloadFraction: Double? {
        guard case let .downloading(fractionCompleted) = stage else { return nil }
        return fractionCompleted
    }

    func hint(at now: Date) -> String? {
        switch stage {
        case .idle:
            nil
        case .checkingCache:
            "Background Parakeet warmup · checking cache · \(elapsedText(at: now))"
        case let .downloading(fractionCompleted):
            "Background Parakeet warmup · downloading \(Int((fractionCompleted * 100).rounded()))% · \(elapsedText(at: now))"
        case let .loading(component):
            "Background Parakeet warmup · loading \(component) · \(elapsedText(at: now))"
        case .ready:
            "Local Parakeet ready · initialized in \(elapsedText(at: finishedAt ?? now))"
        case let .failed(message):
            "Parakeet warmup failed after \(elapsedText(at: finishedAt ?? now)): \(message)"
        }
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt ?? date)))
        guard elapsed >= 60 else { return "\(elapsed)s" }
        return "\(elapsed / 60)m \(elapsed % 60)s"
    }
}

struct RealtimeRefinementRequest {
    let transcriptID: String
    let speaker: SpeakerTag
    let pcm16Audio: Data
    let context: TranscriptionContext
    let recentTranscript: String
}

struct TranscriptionCompletionUsage: Equatable {
    enum BillingUnit: String, Equatable {
        case duration
        case tokens
    }

    let billingUnit: BillingUnit
    let seconds: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let audioInputTokens: Int?
    let textInputTokens: Int?

    static func parse(from data: Data) -> TranscriptionCompletionUsage? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            json["type"] as? String
                == "conversation.item.input_audio_transcription.completed",
            let usage = json["usage"] as? [String: Any],
            let rawUnit = usage["type"] as? String,
            let billingUnit = BillingUnit(rawValue: rawUnit)
        else {
            return nil
        }

        let inputDetails = usage["input_token_details"] as? [String: Any]
        return TranscriptionCompletionUsage(
            billingUnit: billingUnit,
            seconds: number(usage["seconds"]),
            inputTokens: integer(usage["input_tokens"]),
            outputTokens: integer(usage["output_tokens"]),
            totalTokens: integer(usage["total_tokens"]),
            audioInputTokens: integer(inputDetails?["audio_tokens"]),
            textInputTokens: integer(inputDetails?["text_tokens"])
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
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

enum OpenAITranscriptionPass: Equatable {
    case live
    case final
}

enum OpenAIUsageMeasurement: Equatable {
    case serverReported
    case submittedAudioEstimate
}

struct OpenAITranscriptionUsageRecord: Equatable {
    let pass: OpenAITranscriptionPass
    let model: String
    let audioSeconds: Double
    let measurement: OpenAIUsageMeasurement
}

struct APIExpenseSummary: Equatable {
    // Pricing is configuration, not an invoice. Keep the effective date visible
    // so a future model or pricing update cannot silently change old estimates.
    static let pricingEffectiveAt = "2026-08-01"
    static let liveTranscriptionUSDPerMinute = 0.017
    static let finalTranscriptionUSDPerMinute = 0.0045

    var liveAudioSeconds: Double = 0
    var finalAudioSeconds: Double = 0
    var serverReportedRecords = 0
    var estimatedRecords = 0
    var assistantGenerations = 0
    var assistantInputTokens = 0
    var assistantCachedInputTokens = 0
    var assistantCacheWriteTokens = 0
    var assistantOutputTokens = 0
    var assistantReasoningTokens = 0

    var liveCostUSD: Double {
        liveAudioSeconds / 60 * Self.liveTranscriptionUSDPerMinute
    }

    var finalCostUSD: Double {
        finalAudioSeconds / 60 * Self.finalTranscriptionUSDPerMinute
    }

    var totalCostUSD: Double {
        liveCostUSD + finalCostUSD
    }

    var totalAudioSeconds: Double {
        liveAudioSeconds + finalAudioSeconds
    }

    var displayCost: String {
        let decimalPlaces = totalCostUSD < 0.01 ? 4 : 2
        return String(format: "$%.*f", decimalPlaces, totalCostUSD)
    }

    mutating func record(_ usage: OpenAITranscriptionUsageRecord) {
        let seconds = max(0, usage.audioSeconds)
        switch usage.pass {
        case .live:
            liveAudioSeconds += seconds
        case .final:
            finalAudioSeconds += seconds
        }
        switch usage.measurement {
        case .serverReported:
            serverReportedRecords += 1
        case .submittedAudioEstimate:
            estimatedRecords += 1
        }
    }

    mutating func record(_ usage: AssistantGenerationUsage) {
        assistantGenerations += 1
        assistantInputTokens += max(0, usage.inputTokens)
        assistantCachedInputTokens += max(0, usage.cachedInputTokens)
        assistantCacheWriteTokens += max(0, usage.cacheWriteTokens)
        assistantOutputTokens += max(0, usage.outputTokens)
        assistantReasoningTokens += max(0, usage.reasoningTokens)
    }
}

protocol TranscriptRefining: AnyObject {
    func connect()
    func refine(_ request: RealtimeRefinementRequest)
    func finishWhenIdle()
    func disconnect()
}

struct AudioProcessInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let isProducingOutput: Bool

    var displayName: String {
        isProducingOutput ? "\(name) — playing audio" : name
    }
}

enum SocketState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Error"
        }
    }

    var detail: String? {
        if case let .failed(message) = self {
            return message
        }
        return nil
    }
}

struct TrackTelemetry: Equatable {
    var waveform: [Float] = Array(repeating: 0, count: 180)
    var rms: Float = 0
    var peak: Float = 0
    var packets: UInt64 = 0
    var bytes: UInt64 = 0
    var droppedBuffers: UInt64 = 0
    var monitoringStartedAt: Date?
    var lastPacketAt: Date?
    var sourceFormat = "Waiting for audio"
}

enum AudioStreamHealth: Equatable {
    case unavailable
    case permissionRequired
    case ready
    case checking
    case healthy
    case dropping
    case noData

    var label: String {
        switch self {
        case .unavailable:
            "Not connected"
        case .permissionRequired:
            "Access needed"
        case .ready:
            "Ready"
        case .checking:
            "Checking…"
        case .healthy:
            "Healthy"
        case .dropping:
            "Drops detected"
        case .noData:
            "No audio data"
        }
    }

    var detail: String {
        switch self {
        case .unavailable:
            "No audio source is currently available."
        case .permissionRequired:
            "Microphone access is required before the input can be checked."
        case .ready:
            "The device is selected. Start listening to run a live signal check."
        case .checking:
            "Capture has started and is waiting for its first audio packets."
        case .healthy:
            "Audio packets are arriving normally."
        case .dropping:
            "Audio is arriving, but one or more buffers were dropped."
        case .noData:
            "Capture is active, but audio packets have stopped arriving."
        }
    }

    static func evaluate(
        sourceAvailable: Bool,
        permissionGranted: Bool = true,
        isMonitoring: Bool,
        telemetry: TrackTelemetry,
        now: Date = Date(),
        staleAfter: TimeInterval = 2
    ) -> AudioStreamHealth {
        guard sourceAvailable else { return .unavailable }
        guard permissionGranted else { return .permissionRequired }
        guard isMonitoring else { return .ready }

        if let lastPacketAt = telemetry.lastPacketAt {
            guard now.timeIntervalSince(lastPacketAt) <= staleAfter else {
                return .noData
            }
            return telemetry.droppedBuffers > 0 ? .dropping : .healthy
        }

        if
            let monitoringStartedAt = telemetry.monitoringStartedAt,
            now.timeIntervalSince(monitoringStartedAt) > staleAfter
        {
            return .noData
        }
        return .checking
    }
}

struct TrackViewState: Equatable {
    var socket: SocketState = .idle
    var telemetry = TrackTelemetry()
    var partialTranscript = ""
    var lastItemID = ""
}

struct DictationPermissionState: Equatable {
    var canMonitorKeyboard: Bool
    var canPasteIntoOtherApps: Bool
    var canUseMicrophone: Bool

    var allGranted: Bool {
        canMonitorKeyboard && canPasteIntoOtherApps && canUseMicrophone
    }

    var detail: String {
        if allGranted {
            return "Accessibility and Microphone are enabled."
        }
        var missing: [String] = []
        if !canMonitorKeyboard || !canPasteIntoOtherApps {
            missing.append("Accessibility")
        }
        if !canUseMicrophone {
            missing.append("Microphone")
        }
        return "\(missing.joined(separator: " and ")) access is required."
    }
}

enum DictationPhase: Equatable {
    case off
    case needsPermission
    case preparing(TranscriptRefinementEngine)
    case ready
    case recording
    case transcribing
    case failed(String)

    var label: String {
        switch self {
        case .off:
            "Off"
        case .needsPermission:
            "Needs permission"
        case let .preparing(engine):
            switch engine {
            case .localParakeet:
                "Loading Parakeet…"
            case .openAITranscribe:
                "Connecting to GPT-Transcribe…"
            }
        case .ready:
            "Ready"
        case .recording:
            "Listening…"
        case .transcribing:
            "Transcribing…"
        case .failed:
            "Needs attention"
        }
    }

    var detail: String? {
        switch self {
        case let .preparing(engine):
            switch engine {
            case .localParakeet:
                return "Parakeet is still loading. Release the shortcut and wait for Ready before dictating."
            case .openAITranscribe:
                return "GPT-Transcribe is still connecting. Release the shortcut and wait for Ready before dictating."
            }
        case let .failed(message):
            return message
        default:
            return nil
        }
    }
}

enum TranscriptionDelay: String, CaseIterable, Identifiable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }
}

struct TranscriptionContext: Equatable {
    var prompt: String
    var keywords: [String]
    var languages: [String]
    var delay: TranscriptionDelay
}

enum MeetingCopilotError: LocalizedError {
    case noAPIKey
    case noProcessSelected
    case invalidKeyword(String)
    case coreAudio(operation: String, status: OSStatus)
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "Enter an OpenAI API key first."
        case .noProcessSelected:
            "Select the meeting application whose output should be transcribed."
        case let .invalidKeyword(keyword):
            "The terminology hint “\(keyword)” contains a forbidden character or line break."
        case let .coreAudio(operation, status):
            "\(operation) failed (\(Self.fourCC(status)), OSStatus \(status))."
        case let .audio(message):
            message
        }
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let scalars = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        guard scalars.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            return "unknown"
        }
        return String(bytes: scalars, encoding: .ascii) ?? "unknown"
    }
}

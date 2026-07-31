import CoreAudio
import Foundation

enum SpeakerTag: String, Codable {
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
    case openAIRealtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localParakeet:
            "Local Parakeet"
        case .openAIRealtime:
            "OpenAI audio second pass"
        }
    }

    var detail: String {
        switch self {
        case .localParakeet:
            "Parakeet TDT v3 runs directly inside Meeting Copilot through Core ML."
        case .openAIRealtime:
            "The bounded turn audio is transcribed again by an OpenAI audio model."
        }
    }
}

struct RealtimeRefinementRequest {
    let transcriptID: String
    let speaker: SpeakerTag
    let pcm16Audio: Data
    let context: TranscriptionContext
    let recentTranscript: String
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
    var sourceFormat = "Waiting for audio"
}

struct TrackViewState: Equatable {
    var socket: SocketState = .idle
    var telemetry = TrackTelemetry()
    var partialTranscript = ""
    var lastItemID = ""
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

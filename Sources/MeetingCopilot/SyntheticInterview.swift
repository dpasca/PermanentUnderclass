import AVFoundation
import Foundation

struct SyntheticInterviewTurn: Codable, Equatable, Sendable {
    let id: String
    let speaker: SpeakerTag
    let text: String
    let pauseAfterSpeech: TimeInterval
}

struct SyntheticInterviewScenario: Codable, Equatable, Sendable {
    static let launchArgument = "--synthetic-interview"
    static let generationVersion = 3

    let generationVersion: Int
    let purpose: CapturePurpose
    let name: String
    let referenceRevision: String
    let referenceDocumentCount: Int
    let generatedAt: Date
    let finalizationDelay: TimeInterval
    let turns: [SyntheticInterviewTurn]
}

struct SyntheticInterviewState: Equatable {
    var purpose: CapturePurpose = .interview
    var isGenerating = false
    var isRunning = false
    var hasRun = false
    var title = "Reference-grounded interview ready"
    var detail = "Generate an audible interview replay from the currently indexed reference documents."
    var scenarioName = ""
    var referenceRevision = ""
    var currentTurn = 0
    var totalTurns = 0

    var isActive: Bool {
        isGenerating || isRunning
    }

    var progress: Double {
        guard totalTurns > 0 else { return 0 }
        return Double(currentTurn) / Double(totalTurns)
    }

    static func ready(for purpose: CapturePurpose) -> SyntheticInterviewState {
        SyntheticInterviewState(
            purpose: purpose,
            title: purpose == .meeting
                ? "Reference-grounded meeting ready"
                : "Reference-grounded interview ready",
            detail: purpose == .meeting
                ? "Generate an audible mock meeting from the currently indexed reference documents."
                : "Generate an audible interview replay from the currently indexed reference documents."
        )
    }
}

struct SyntheticInterviewScenarioStore {
    private static let directoryName = "com.permanentunderclass.meetingcopilot"
    private static func fileName(for purpose: CapturePurpose) -> String {
        switch purpose {
        case .meeting:
            "SyntheticMeetingScenario.json"
        case .interview:
            "SyntheticInterviewScenario.json"
        }
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationSupport(
        for purpose: CapturePurpose = .interview,
        fileManager: FileManager = .default
    ) -> SyntheticInterviewScenarioStore {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return SyntheticInterviewScenarioStore(
            fileURL: applicationSupportURL
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName(for: purpose)),
            fileManager: fileManager
        )
    }

    func load(
        referenceRevision: String,
        purpose: CapturePurpose
    ) throws -> SyntheticInterviewScenario? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let scenario = try JSONDecoder().decode(
            SyntheticInterviewScenario.self,
            from: data
        )
        guard
            scenario.generationVersion
                == SyntheticInterviewScenario.generationVersion,
            scenario.purpose == purpose,
            scenario.referenceRevision == referenceRevision
        else {
            return nil
        }
        return scenario
    }

    func save(_ scenario: SyntheticInterviewScenario) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(scenario).write(to: fileURL, options: .atomic)
    }
}

enum SyntheticInterviewError: LocalizedError, Equatable {
    case referencesUnavailable
    case referencesChanged

    var errorDescription: String? {
        switch self {
        case .referencesUnavailable:
            "Choose and finish indexing a reference folder before generating the replay."
        case .referencesChanged:
            "The reference documents changed during replay generation. Run it again to use the new revision."
        }
    }
}

enum SyntheticSpeechError: LocalizedError {
    case alreadySpeaking

    var errorDescription: String? {
        switch self {
        case .alreadySpeaking:
            "The generated replay voice is already speaking."
        }
    }
}

final class SyntheticSpeechPlayer: NSObject, AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    typealias PartialHandler = (String) -> Void

    private let synthesizer = AVSpeechSynthesizer()
    private var activeText = ""
    private var partialHandler: PartialHandler?
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String,
        speaker: SpeakerTag,
        onPartial: @escaping PartialHandler
    ) async throws {
        guard continuation == nil else { throw SyntheticSpeechError.alreadySpeaking }
        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activeText = text
                partialHandler = onPartial
                self.continuation = continuation

                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(
                    language: speaker == .you ? "en-US" : "en-GB"
                )
                utterance.rate = speaker == .you ? 0.48 : 0.5
                utterance.pitchMultiplier = speaker == .you ? 0.96 : 1.04
                utterance.preUtteranceDelay = 0.12
                synthesizer.speak(utterance)
            }
        } onCancel: { [weak self] in
            DispatchQueue.main.async {
                self?.stop()
            }
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        } else {
            finish(throwing: CancellationError())
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let text = activeText as NSString
        let end = min(text.length, NSMaxRange(characterRange))
        guard end > 0 else { return }
        partialHandler?(text.substring(to: end))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        partialHandler?(activeText)
        finish()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish(throwing: CancellationError())
    }

    private func finish(throwing error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        partialHandler = nil
        activeText = ""
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

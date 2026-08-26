import Foundation

struct InterviewSessionArchive: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let source: CompanionSessionSource
    let startedAt: Date
    var endedAt: Date?
    let answerMode: AssistantAnswerMode
    let earlyBridgeEnabled: Bool
    let sessionContext: String
    let referenceRevision: String?
    var transcript: [CompanionTranscriptTurn]
    var earlyBridges: [CompanionAssistantBridge]
    var suggestions: [CompanionAssistantSuggestion]
    var updatedAt: Date

    init(
        id: UUID,
        source: CompanionSessionSource,
        startedAt: Date,
        answerMode: AssistantAnswerMode,
        earlyBridgeEnabled: Bool,
        sessionContext: String,
        referenceRevision: String?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.source = source
        self.startedAt = startedAt
        endedAt = nil
        self.answerMode = answerMode
        self.earlyBridgeEnabled = earlyBridgeEnabled
        self.sessionContext = sessionContext
        self.referenceRevision = referenceRevision
        transcript = []
        earlyBridges = []
        suggestions = []
        updatedAt = startedAt
    }

    mutating func upsertTranscriptTurn(
        _ turn: CompanionTranscriptTurn,
        updatedAt: Date = Date()
    ) {
        transcript.removeAll { $0.id == turn.id }
        transcript.append(turn)
        transcript.sort {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt < $1.startedAt
        }
        self.updatedAt = updatedAt
    }

    mutating func appendBridge(
        _ bridge: CompanionAssistantBridge,
        updatedAt: Date = Date()
    ) {
        earlyBridges.removeAll { $0.id == bridge.id }
        earlyBridges.append(bridge)
        earlyBridges.sort {
            if $0.generatedAt == $1.generatedAt { return $0.id < $1.id }
            return $0.generatedAt < $1.generatedAt
        }
        self.updatedAt = updatedAt
    }

    mutating func appendSuggestion(
        _ suggestion: CompanionAssistantSuggestion,
        updatedAt: Date = Date()
    ) {
        suggestions.removeAll { $0.id == suggestion.id }
        suggestions.append(suggestion)
        suggestions.sort {
            if $0.generatedAt == $1.generatedAt { return $0.id < $1.id }
            return $0.generatedAt < $1.generatedAt
        }
        self.updatedAt = updatedAt
    }

    mutating func finish(at date: Date = Date()) {
        if endedAt == nil {
            endedAt = date
        }
        updatedAt = date
    }
}

struct InterviewSessionArchiveStore {
    private static let directoryName = "com.newtypekk.punderclass"
    private static let archiveDirectoryName = "InterviewSessions"

    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) -> InterviewSessionArchiveStore {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return InterviewSessionArchiveStore(
            directoryURL: applicationSupportURL
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(
                    archiveDirectoryName,
                    isDirectory: true
                ),
            fileManager: fileManager
        )
    }

    @discardableResult
    func save(_ archive: InterviewSessionArchive) throws -> URL {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = fileURL(for: archive)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
        return fileURL
    }

    func load(from fileURL: URL) throws -> InterviewSessionArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            InterviewSessionArchive.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func mostRecentArchiveURL() throws -> URL? {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return nil
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        return try urls.max { lhs, rhs in
            let lhsDate = try lhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsDate < rhsDate
        }
    }

    private func fileURL(for archive: InterviewSessionArchive) -> URL {
        let epoch = max(0, Int(archive.startedAt.timeIntervalSince1970))
        return directoryURL.appendingPathComponent(
            "\(epoch)-\(archive.id.uuidString.lowercased()).json"
        )
    }
}

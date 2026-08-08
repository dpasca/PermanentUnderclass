import Foundation

struct QuickDictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let text: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

struct QuickDictationHistoryStore {
    private static let directoryName = "com.newtypekk.punderclass"
    private static let fileName = "QuickDictationHistory.json"

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) -> QuickDictationHistoryStore {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return QuickDictationHistoryStore(
            fileURL: applicationSupportURL
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName),
            fileManager: fileManager
        )
    }

    func load() throws -> [QuickDictationHistoryEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder()
            .decode([QuickDictationHistoryEntry].self, from: data)
            .sorted(by: Self.isNewer)
    }

    func save(_ entries: [QuickDictationHistoryEntry]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func isNewer(
        _ lhs: QuickDictationHistoryEntry,
        _ rhs: QuickDictationHistoryEntry
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

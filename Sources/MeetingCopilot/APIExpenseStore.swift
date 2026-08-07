import Foundation

/// Persists the running API spend estimate. The counter is only useful if it
/// survives relaunches — during development the app starts many times a day,
/// and a per-launch total answers no question anyone actually has.
struct APIExpenseStore {
    private static let directoryName = "com.permanentunderclass.meetingcopilot"
    private static let fileName = "APIExpenses.json"

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) -> APIExpenseStore {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return APIExpenseStore(
            fileURL: applicationSupportURL
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName),
            fileManager: fileManager
        )
    }

    func load() throws -> APIExpenseSummary {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return APIExpenseSummary()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(APIExpenseSummary.self, from: data)
    }

    func save(_ summary: APIExpenseSummary) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: fileURL, options: .atomic)
    }
}

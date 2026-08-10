import CryptoKit
import Foundation
import NaturalLanguage

enum ReferenceWebProvider: String, Codable, Equatable, Sendable {
    case jinaReader
    case direct
    case exa

    var title: String {
        switch self {
        case .jinaReader:
            "Jina Reader"
        case .direct:
            "Direct fetch"
        case .exa:
            "Exa"
        }
    }
}

enum ReferenceWebSourceStatus: String, Codable, Equatable, Sendable {
    case pending
    case fetching
    case ready
    case keyRequired
    case failed

    var title: String {
        switch self {
        case .pending:
            "Not fetched"
        case .fetching:
            "Fetching…"
        case .ready:
            "Ready"
        case .keyRequired:
            "Exa key optional"
        case .failed:
            "Needs attention"
        }
    }
}

struct ReferenceWebSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var requestedURL: String
    var resolvedURL: String?
    var title: String?
    var content: String
    var fetchedAt: Date?
    var provider: ReferenceWebProvider?
    var status: ReferenceWebSourceStatus
    var detail: String

    init(url: URL, id: String = UUID().uuidString.lowercased()) {
        self.id = id
        requestedURL = url.absoluteString
        resolvedURL = nil
        title = nil
        content = ""
        fetchedAt = nil
        provider = nil
        status = .pending
        detail = ""
    }

    var citationPath: String {
        requestedURL
    }
}

struct PreparedReferenceCard: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectAnchor: String
    let period: String
    let latestYear: Int?
    let role: String
    let summary: String
    let concreteDetails: [String]
    let interviewUses: [String]
    let sourcePaths: [String]
    let roleRelevance: Int
    var isEnabled: Bool

    var semanticText: String {
        ([projectAnchor, period, role, summary]
            + concreteDetails
            + interviewUses)
            .joined(separator: "\n")
    }
}

struct PreparedReferencePack: Codable, Equatable, Sendable {
    let purpose: CapturePurpose
    let localReferenceRevision: String
    let webSourceRevision: String
    let sessionContext: String
    let preparedAt: Date
    var cards: [PreparedReferenceCard]

    var enabledCardCount: Int {
        cards.filter(\.isEnabled).count
    }

    var revision: String {
        ReferencePreparationDigest.hash(
            [
                purpose.rawValue,
                localReferenceRevision,
                webSourceRevision,
                sessionContext
            ] + cards.map {
                "\($0.id):\($0.isEnabled ? "on" : "off")"
            }
        )
    }

    func isCurrent(
        purpose: CapturePurpose,
        localReferenceRevision: String?,
        webSources: [ReferenceWebSource],
        sessionContext: String
    ) -> Bool {
        self.purpose == purpose
            && self.localReferenceRevision
                == (localReferenceRevision ?? Self.noLocalRevision)
            && webSourceRevision
                == ReferencePreparationDigest.webSourceRevision(webSources)
            && self.sessionContext.normalizedReferenceContext
                == sessionContext.normalizedReferenceContext
    }

    func snapshot(
        for question: String,
        folderURL: URL?,
        maximumCards: Int = 8,
        selector: PreparedReferenceSelector = PreparedReferenceSelector()
    ) -> ReferenceLibrarySnapshot? {
        let selectedCards = selector.select(
            from: cards,
            question: question,
            maximumCards: maximumCards
        )
        guard !selectedCards.isEmpty else { return nil }

        var cardsBySource: [String: [PreparedReferencePromptCard]] = [:]
        for card in selectedCards {
            let promptCard = PreparedReferencePromptCard(card: card)
            for sourcePath in card.sourcePaths {
                cardsBySource[sourcePath, default: []].append(promptCard)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let documents: [ReferenceDocument] = cardsBySource.keys.sorted().compactMap { path in
            guard
                let sourceCards = cardsBySource[path],
                let data = try? encoder.encode(sourceCards),
                let content = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return ReferenceDocument(
                relativePath: path,
                kind: .structuredText,
                content: content,
                sourceByteCount: data.count,
                isTruncated: false
            )
        }
        guard !documents.isEmpty else { return nil }

        return ReferenceLibrarySnapshot(
            folderURL: folderURL
                ?? URL(fileURLWithPath: "/prepared-interview-evidence", isDirectory: true),
            documents: documents,
            revision: ReferencePreparationDigest.hash(
                [revision, question.normalizedReferenceContext]
                    + selectedCards.map(\.id)
            ),
            indexedAt: preparedAt,
            ignoredFileCount: 0,
            issues: []
        )
    }

    static let noLocalRevision = "no-local-reference-material"
}

private struct PreparedReferencePromptCard: Codable {
    let project: String
    let period: String
    let latestYear: Int?
    let role: String
    let summary: String
    let concreteDetails: [String]
    let usefulForQuestionsAbout: [String]
    let roleRelevance: Int

    init(card: PreparedReferenceCard) {
        project = card.projectAnchor
        period = card.period
        latestYear = card.latestYear
        role = card.role
        summary = card.summary
        concreteDetails = card.concreteDetails
        usefulForQuestionsAbout = card.interviewUses
        roleRelevance = card.roleRelevance
    }
}

enum ReferencePreparationPhase: Equatable, Sendable {
    case idle
    case fetching
    case extracting
    case ready
    case failed(String)

    var isWorking: Bool {
        self == .fetching || self == .extracting
    }

    var title: String {
        switch self {
        case .idle:
            "Not prepared"
        case .fetching:
            "Reading web sources…"
        case .extracting:
            "Building evidence…"
        case .ready:
            "Prepared"
        case .failed:
            "Needs attention"
        }
    }
}

struct ReferencePreparationState: Equatable, Sendable {
    var webSources: [ReferenceWebSource] = []
    var pack: PreparedReferencePack?
    var phase: ReferencePreparationPhase = .idle

    init() {}

    init(archive: ReferencePreparationArchive) {
        webSources = archive.webSources.map { source in
            var restored = source
            if restored.status == .fetching {
                restored.status = .pending
            }
            return restored
        }
        pack = archive.pack
        phase = pack == nil ? .idle : .ready
    }
}

struct ReferencePreparationArchive: Codable, Equatable, Sendable {
    var webSources: [ReferenceWebSource]
    var pack: PreparedReferencePack?

    init(state: ReferencePreparationState) {
        webSources = state.webSources
        pack = state.pack
    }
}

struct ReferencePreparationStore {
    private static let directoryName = "com.newtypekk.punderclass"
    private static let fileName = "ReferencePreparation.json"

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) -> ReferencePreparationStore {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return ReferencePreparationStore(
            fileURL: applicationSupportURL
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName),
            fileManager: fileManager
        )
    }

    func load() throws -> ReferencePreparationArchive {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ReferencePreparationArchive(state: ReferencePreparationState())
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(
            ReferencePreparationArchive.self,
            from: data
        )
    }

    func save(_ archive: ReferencePreparationArchive) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
    }
}

struct PreparedReferenceSelector {
    typealias SemanticDistance = (String, String) -> Double?

    private let semanticDistance: SemanticDistance
    private let currentYear: Int

    init(
        currentYear: Int = Calendar.current.component(.year, from: Date()),
        semanticDistance: @escaping SemanticDistance = Self.nativeDistance
    ) {
        self.currentYear = currentYear
        self.semanticDistance = semanticDistance
    }

    func select(
        from cards: [PreparedReferenceCard],
        question: String,
        maximumCards: Int
    ) -> [PreparedReferenceCard] {
        guard maximumCards > 0 else { return [] }
        let enabledCards = cards.filter(\.isEnabled)
        guard !enabledCards.isEmpty else { return [] }

        let trimmedQuestion = question.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmedQuestion.isEmpty {
            return Array(
                enabledCards.sorted(by: preparationPriority).prefix(maximumCards)
            )
        }

        let ranked = enabledCards.map {
            (card: $0, score: score($0, question: trimmedQuestion))
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return preparationPriority(lhs.card, rhs.card)
        }.map(\.card)

        let semanticSlots = max(1, maximumCards - min(2, maximumCards / 3))
        var selected = Array(ranked.prefix(semanticSlots))
        let recentRoleMatches = enabledCards.sorted(by: preparationPriority)
        for card in recentRoleMatches where selected.count < maximumCards {
            guard !selected.contains(where: { $0.id == card.id }) else { continue }
            selected.append(card)
        }
        return selected
    }

    private func score(
        _ card: PreparedReferenceCard,
        question: String
    ) -> Double {
        let distance = semanticDistance(question, card.semanticText) ?? 2
        let roleAdjustment = Double(max(0, min(5, card.roleRelevance)) - 1)
            * 0.045
        let agePenalty: Double
        if let latestYear = card.latestYear {
            agePenalty = Double(max(0, min(25, currentYear - latestYear)))
                * 0.008
        } else {
            agePenalty = 0.06
        }
        return distance - roleAdjustment + agePenalty
    }

    private func preparationPriority(
        _ lhs: PreparedReferenceCard,
        _ rhs: PreparedReferenceCard
    ) -> Bool {
        if lhs.roleRelevance != rhs.roleRelevance {
            return lhs.roleRelevance > rhs.roleRelevance
        }
        if lhs.latestYear != rhs.latestYear {
            return (lhs.latestYear ?? 0) > (rhs.latestYear ?? 0)
        }
        return lhs.projectAnchor < rhs.projectAnchor
    }

    private static func nativeDistance(_ lhs: String, _ rhs: String) -> Double? {
        NLEmbedding.sentenceEmbedding(for: .english)?
            .distance(between: lhs, and: rhs)
    }
}

enum ReferencePreparationDigest {
    static func webSourceRevision(_ sources: [ReferenceWebSource]) -> String {
        hash(
            sources.sorted { $0.id < $1.id }.flatMap {
                [
                    $0.id,
                    $0.requestedURL,
                    $0.resolvedURL ?? "",
                    $0.status.rawValue,
                    $0.content
                ]
            }
        )
    }

    static func cardID(
        projectAnchor: String,
        period: String,
        sourcePaths: [String]
    ) -> String {
        String(
            hash(
                [projectAnchor.normalizedReferenceContext,
                 period.normalizedReferenceContext]
                    + sourcePaths.sorted()
            ).prefix(24)
        )
    }

    static func hash(_ values: [String]) -> String {
        var hasher = SHA256()
        for value in values {
            let data = Data(value.utf8)
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var normalizedReferenceContext: String {
        split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

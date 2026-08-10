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
    var contentDigest: String?
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
        contentDigest = nil
        fetchedAt = nil
        provider = nil
        status = .pending
        detail = ""
    }

    var citationPath: String {
        requestedURL
    }
}

struct ReferenceResumeSource: Codable, Equatable, Sendable {
    let filePath: String
    let citationPath: String
    let contentDigest: String
    let sourceByteCount: Int

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var displayName: String {
        fileURL.lastPathComponent
    }
}

enum PreparedReferenceSourceKind: String, Codable, Equatable, Sendable {
    case resume
    case portfolio
    case projectPage
    case credits
    case interviewPreparation
    case jobDescription
    case other

    var title: String {
        switch self {
        case .resume:
            "Resume"
        case .portfolio:
            "Portfolio"
        case .projectPage:
            "Project page"
        case .credits:
            "Credits"
        case .interviewPreparation:
            "Interview preparation"
        case .jobDescription:
            "Job description"
        case .other:
            "Other"
        }
    }
}

enum PreparedReferenceSourceUse: String, Codable, Equatable, Sendable {
    case primaryResume
    case factualSupplement
    case contextOnly
    case excluded

    var title: String {
        switch self {
        case .primaryResume:
            "Primary resume"
        case .factualSupplement:
            "Factual supplement"
        case .contextOnly:
            "Context only"
        case .excluded:
            "Excluded"
        }
    }

    var canSupportCandidateFacts: Bool {
        self == .primaryResume || self == .factualSupplement
    }
}

struct PreparedReferenceSourceAssessment: Codable, Equatable, Identifiable,
    Sendable
{
    var id: String { path }

    let path: String
    let title: String
    let kind: PreparedReferenceSourceKind
    let use: PreparedReferenceSourceUse
    let confidence: Double
    let rationale: String
    let conflictsWith: [String]
    let conflictSummary: String
}

struct PreparedReferenceSourceManifest: Codable, Equatable, Sendable {
    let canonicalResumePath: String?
    let requiresReview: Bool
    let resolutionSummary: String
    let sources: [PreparedReferenceSourceAssessment]

    var factualSourcePaths: Set<String> {
        Set(
            sources.compactMap {
                $0.use.canSupportCandidateFacts ? $0.path : nil
            }
        )
    }

    var conflictCount: Int {
        sources.filter {
            !$0.conflictsWith.isEmpty || !$0.conflictSummary.isEmpty
        }.count
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
    let semanticVector: [Float]?
    var isEnabled: Bool

    init(
        id: String,
        projectAnchor: String,
        period: String,
        latestYear: Int?,
        role: String,
        summary: String,
        concreteDetails: [String],
        interviewUses: [String],
        sourcePaths: [String],
        roleRelevance: Int,
        semanticVector: [Float]? = nil,
        isEnabled: Bool
    ) {
        self.id = id
        self.projectAnchor = projectAnchor
        self.period = period
        self.latestYear = latestYear
        self.role = role
        self.summary = summary
        self.concreteDetails = concreteDetails
        self.interviewUses = interviewUses
        self.sourcePaths = sourcePaths
        self.roleRelevance = roleRelevance
        self.semanticVector = semanticVector
        self.isEnabled = isEnabled
    }

    var semanticText: String {
        ([projectAnchor, period, role, summary]
            + concreteDetails
            + interviewUses)
            .joined(separator: "\n")
    }
}

struct PreparedReferencePack: Codable, Equatable, Sendable {
    static let currentPreparationVersion = 2

    let preparationVersion: Int?
    let purpose: CapturePurpose
    let localReferenceRevision: String
    let webSourceRevision: String
    let sessionContext: String
    let preparedAt: Date
    let sourceManifest: PreparedReferenceSourceManifest?
    let evidenceRevision: String?
    var cards: [PreparedReferenceCard]

    init(
        preparationVersion: Int = Self.currentPreparationVersion,
        purpose: CapturePurpose,
        localReferenceRevision: String,
        webSourceRevision: String,
        sessionContext: String,
        preparedAt: Date,
        sourceManifest: PreparedReferenceSourceManifest? = nil,
        cards: [PreparedReferenceCard]
    ) {
        self.preparationVersion = preparationVersion
        self.purpose = purpose
        self.localReferenceRevision = localReferenceRevision
        self.webSourceRevision = webSourceRevision
        self.sessionContext = sessionContext
        self.preparedAt = preparedAt
        self.sourceManifest = sourceManifest
        evidenceRevision = ReferencePreparationDigest.preparedEvidenceRevision(
            sourceManifest: sourceManifest,
            cards: cards
        )
        self.cards = cards
    }

    var enabledCardCount: Int {
        cards.filter(\.isEnabled).count
    }

    var revision: String {
        ReferencePreparationDigest.hash(
            [
                purpose.rawValue,
                String(preparationVersion ?? 1),
                localReferenceRevision,
                webSourceRevision,
                sessionContext,
                evidenceRevision ?? "legacy-evidence"
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
        preparationVersion == Self.currentPreparationVersion
            && sourceManifest != nil
            && evidenceRevision != nil
            && self.purpose == purpose
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
    var resumeSource: ReferenceResumeSource?
    var webSources: [ReferenceWebSource] = []
    var pack: PreparedReferencePack?
    var phase: ReferencePreparationPhase = .idle

    init() {}

    init(archive: ReferencePreparationArchive) {
        resumeSource = archive.resumeSource
        webSources = archive.webSources.map { source in
            var restored = source
            if restored.status == .fetching {
                restored.status = .pending
            }
            if restored.contentDigest == nil, !restored.content.isEmpty {
                restored.contentDigest = ReferencePreparationDigest.hash([
                    restored.content
                ])
            }
            return restored
        }
        pack = archive.pack
        phase = pack == nil ? .idle : .ready
    }
}

struct ReferencePreparationArchive: Codable, Equatable, Sendable {
    var resumeSource: ReferenceResumeSource?
    var webSources: [ReferenceWebSource]
    var pack: PreparedReferencePack?

    init(state: ReferencePreparationState) {
        resumeSource = state.resumeSource
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

    private let semanticDistance: SemanticDistance?
    private let currentYear: Int

    init(
        currentYear: Int = Calendar.current.component(.year, from: Date()),
        semanticDistance: SemanticDistance? = nil
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

        let questionVector = semanticDistance == nil
            ? PreparedReferenceEmbedding.vector(for: trimmedQuestion)
            : nil
        let candidates = enabledCards.map { card in
            let distance = semanticDistance(
                card,
                question: trimmedQuestion,
                questionVector: questionVector
            )
            return (
                card: card,
                distance: distance,
                score: adjustedScore(card, semanticDistance: distance)
            )
        }
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return preparationPriority(lhs.card, rhs.card)
        }.map(\.card)
        let rawSemanticRanked = candidates.sorted { lhs, rhs in
            if lhs.distance != rhs.distance {
                return lhs.distance < rhs.distance
            }
            return preparationPriority(lhs.card, rhs.card)
        }.map(\.card)

        let recentSlots = min(3, maximumCards / 2)
        let semanticSlots = max(1, maximumCards - recentSlots)
        // Preserve a couple of pure semantic anchors so an explicitly relevant
        // legacy example survives, then use bounded recency and role signals
        // for the rest of the semantic set.
        let rawSemanticSlots = min(2, maximumCards / 4)
        var selected = Array(rawSemanticRanked.prefix(rawSemanticSlots))
        for card in ranked where selected.count < semanticSlots {
            guard !selected.contains(where: { $0.id == card.id }) else { continue }
            selected.append(card)
        }
        let recentRoleMatches = enabledCards.sorted(by: recentPriority)
        for card in recentRoleMatches where selected.count < maximumCards {
            guard !selected.contains(where: { $0.id == card.id }) else { continue }
            selected.append(card)
        }
        for card in ranked where selected.count < maximumCards {
            guard !selected.contains(where: { $0.id == card.id }) else { continue }
            selected.append(card)
        }
        return selected
    }

    private func semanticDistance(
        _ card: PreparedReferenceCard,
        question: String,
        questionVector: [Float]?
    ) -> Double {
        if let semanticDistance {
            return semanticDistance(question, card.semanticText) ?? 2
        } else if
            let questionVector,
            let cardVector = card.semanticVector
                ?? PreparedReferenceEmbedding.vector(for: card.semanticText),
            let vectorDistance = PreparedReferenceEmbedding.cosineDistance(
                questionVector,
                cardVector
            )
        {
            return vectorDistance
        }
        return 2
    }

    private func adjustedScore(
        _ card: PreparedReferenceCard,
        semanticDistance: Double
    ) -> Double {
        // Semantic distance remains dominant: role can move a score by at most
        // 0.03 and age by at most 0.075.
        let roleAdjustment = Double(max(0, min(5, card.roleRelevance)) - 1)
            * 0.0075
        let agePenalty: Double
        if let latestYear = card.latestYear {
            agePenalty = Double(max(0, min(10, currentYear - latestYear)))
                * 0.0075
        } else {
            agePenalty = 0.035
        }
        return semanticDistance - roleAdjustment + agePenalty
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

    private func recentPriority(
        _ lhs: PreparedReferenceCard,
        _ rhs: PreparedReferenceCard
    ) -> Bool {
        if lhs.latestYear != rhs.latestYear {
            return (lhs.latestYear ?? 0) > (rhs.latestYear ?? 0)
        }
        if lhs.roleRelevance != rhs.roleRelevance {
            return lhs.roleRelevance > rhs.roleRelevance
        }
        return lhs.projectAnchor < rhs.projectAnchor
    }
}

enum PreparedReferenceEmbedding {
    private static let english = NLEmbedding.sentenceEmbedding(for: .english)
    private static let lock = NSLock()

    static func vector(for text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return english?.vector(for: text)?
            .map(Float.init)
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhs.indices {
            let lhsValue = Double(lhs[index])
            let rhsValue = Double(rhs[index])
            dot += lhsValue * rhsValue
            lhsMagnitude += lhsValue * lhsValue
            rhsMagnitude += rhsValue * rhsValue
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        return 1 - dot / sqrt(lhsMagnitude * rhsMagnitude)
    }
}

enum ReferencePreparationDigest {
    static func webSourceRevision(_ sources: [ReferenceWebSource]) -> String {
        // Ready sources persist this digest so frequent readiness checks never
        // rehash an entire downloaded page.
        hash(
            sources.sorted { $0.id < $1.id }.flatMap {
                [
                    $0.id,
                    $0.requestedURL,
                    $0.resolvedURL ?? "",
                    $0.status.rawValue,
                    $0.contentDigest ?? hash([$0.content])
                ]
            }
        )
    }

    static func localSourceRevision(
        folderRevision: String?,
        resumeSource: ReferenceResumeSource?
    ) -> String {
        guard let resumeSource else {
            return folderRevision ?? PreparedReferencePack.noLocalRevision
        }
        return hash([
            folderRevision ?? PreparedReferencePack.noLocalRevision,
            resumeSource.filePath,
            resumeSource.citationPath,
            resumeSource.contentDigest
        ])
    }

    static func preparedEvidenceRevision(
        sourceManifest: PreparedReferenceSourceManifest?,
        cards: [PreparedReferenceCard]
    ) -> String {
        var values: [String] = [
            sourceManifest?.canonicalResumePath ?? "",
            sourceManifest?.requiresReview == true ? "review" : "resolved",
            sourceManifest?.resolutionSummary ?? ""
        ]
        for source in sourceManifest?.sources.sorted(by: {
            $0.path < $1.path
        }) ?? [] {
            values += [
                source.path,
                source.title,
                source.kind.rawValue,
                source.use.rawValue,
                String(source.confidence),
                source.rationale,
                source.conflictsWith.sorted().joined(separator: "\n"),
                source.conflictSummary
            ]
        }
        for card in cards.sorted(by: { $0.id < $1.id }) {
            values += [
                card.id,
                card.semanticText,
                card.sourcePaths.sorted().joined(separator: "\n"),
                String(card.roleRelevance)
            ]
        }
        return hash(values)
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

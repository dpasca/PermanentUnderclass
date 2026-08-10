import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import PUnderclass

final class LiveAssistantPrivateBenchmarkTests: XCTestCase {
    func testPrivateModelPromptMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_ANSWER_MIRROR_PRIVATE_BENCHMARK"] == "1" else {
            throw XCTSkip(
                "Set RUN_ANSWER_MIRROR_PRIVATE_BENCHMARK=1 to run the private benchmark."
            )
        }
        let apiKey = try XCTUnwrap(environment["OPENAI_API_KEY"])
        let fixturePath = try XCTUnwrap(
            environment["ANSWER_MIRROR_PRIVATE_BENCHMARK_PATH"],
            "Set ANSWER_MIRROR_PRIVATE_BENCHMARK_PATH to an external JSON file."
        )
        let suite = try JSONDecoder().decode(
            PrivateBenchmarkSuite.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixturePath))
        )
        XCTAssertFalse(suite.cases.isEmpty, "The private benchmark has no cases.")
        let configurations = try Self.configurations(
            from: environment["ANSWER_MIRROR_BENCHMARK_CONFIGS"]
        )
        let variants = suite.promptVariants?.isEmpty == false
            ? suite.promptVariants!
            : [PrivatePromptVariant(name: "production", instructions: nil)]
        let repetitions = max(
            1,
            Int(environment["ANSWER_MIRROR_BENCHMARK_REPETITIONS"] ?? "1")
                ?? 1
        )
        let judge = AnswerMirrorQualityJudge(
            apiKey: apiKey,
            model: environment["ANSWER_MIRROR_EVAL_JUDGE_MODEL"]
                ?? "gpt-5.6-sol"
        )
        var results: [PrivateBenchmarkResult] = []
        var attemptCounts: [String: Int] = [:]
        var failureCounts: [String: Int] = [:]
        var snapshotsBySource: [String: ReferenceLibrarySnapshot] = [:]

        for configuration in configurations {
            for variant in variants {
                let candidateConfiguration = LiveAssistantConfiguration(
                    model: configuration.model,
                    reasoningEffort: configuration.reasoningEffort,
                    additionalBehaviorInstructions: variant.instructions ?? "",
                    maximumOutputTokens:
                        configuration.reasoningEffort == .xhigh ? 1_200 : nil
                )
                let client = LiveAssistantClient(
                    configuration: candidateConfiguration
                )
                for benchmarkCase in suite.cases {
                    let sourceKey = benchmarkCase.referenceSourceKey
                    let references: ReferenceLibrarySnapshot
                    if let cached = snapshotsBySource[sourceKey] {
                        references = cached
                    } else {
                        references = try await Self.references(
                            for: benchmarkCase
                        )
                        snapshotsBySource[sourceKey] = references
                    }
                    for repetition in 1...repetitions {
                        let aggregateKey = "\(configuration.id)|\(variant.name)"
                        attemptCounts[aggregateKey, default: 0] += 1
                        do {
                            let generation = try await client.generate(
                                apiKey: apiKey,
                                references: references,
                                recentTranscript:
                                    benchmarkCase.recentTranscript ?? "",
                                currentPartial:
                                    benchmarkCase.currentPartial ?? "",
                                otherSpeakerText: benchmarkCase.question,
                                sessionContext:
                                    benchmarkCase.sessionContext ?? "",
                                purpose: .interview,
                                basedOnSequence: repetition,
                                trigger: .finalizedTurn,
                                answerMode: benchmarkCase.answerMode
                            )
                            guard let suggestion = generation.suggestion else {
                                failureCounts[aggregateKey, default: 0] += 1
                                print(
                                    "ANSWER_MIRROR_BENCHMARK_FAILURE "
                                        + "case=\(benchmarkCase.name) "
                                        + "configuration=\(configuration.id) "
                                        + "variant=\(variant.name) "
                                        + "reason=no_suggestion"
                                )
                                continue
                            }
                            let assessment = try await judge.assess(
                                question: benchmarkCase.question,
                                recentTranscript:
                                    benchmarkCase.recentTranscript ?? "",
                                expectedGrounding:
                                    benchmarkCase.expectedGrounding,
                                references: references,
                                suggestion: suggestion
                            )
                            let result = PrivateBenchmarkResult(
                                caseName: benchmarkCase.name,
                                configuration: configuration.id,
                                promptVariant: variant.name,
                                repetition: repetition,
                                generationMilliseconds:
                                    generation.generationMilliseconds,
                                modelCalls: generation.usage.requestCount,
                                qualityMean: assessment.meanScore,
                                directness: assessment.directness,
                                spokenNaturalness:
                                    assessment.spokenNaturalness,
                                plainSpokenLanguage:
                                    assessment.plainSpokenLanguage,
                                specificity: assessment.specificity,
                                anchorRelevance:
                                    assessment.anchorRelevance,
                                temporalJudgment:
                                    assessment.temporalJudgment,
                                causalUsefulness:
                                    assessment.causalUsefulness,
                                mechanisticDepth:
                                    assessment.mechanisticDepth,
                                verificationRigor:
                                    assessment.verificationRigor,
                                groundingSafety:
                                    assessment.groundingSafety,
                                plausibilitySafety:
                                    assessment.plausibilitySafety,
                                answerModeUsefulness:
                                    assessment.answerModeUsefulness,
                                conciseUsability:
                                    assessment.conciseUsability,
                                grounding: suggestion.grounding.rawValue,
                                answerMode: suggestion.answerMode.rawValue,
                                cue: ([suggestion.preamble].compactMap { $0 }
                                    + suggestion.beats.map(\.point))
                                    .joined(separator: " / "),
                                plausibleAssumptions:
                                    suggestion.plausibleAssumptions,
                                plausibleRehearsalPlan:
                                    suggestion.plausibleRehearsalPlan,
                                rationale: assessment.rationale
                            )
                            results.append(result)
                            print(try Self.encodedLine(result))
                        } catch {
                            failureCounts[aggregateKey, default: 0] += 1
                            print(
                                "ANSWER_MIRROR_BENCHMARK_FAILURE "
                                    + "case=\(benchmarkCase.name) "
                                    + "configuration=\(configuration.id) "
                                    + "variant=\(variant.name) "
                                    + "reason=\(error.localizedDescription)"
                            )
                        }
                    }
                }
            }
        }

        XCTAssertFalse(results.isEmpty, "Every private benchmark run failed.")
        for summary in Self.summaries(
            from: results,
            attemptCounts: attemptCounts,
            failureCounts: failureCounts
        ) {
            print(try Self.encodedLine(summary))
        }
    }

    private static func configurations(
        from value: String?
    ) throws -> [PrivateModelConfiguration] {
        let raw = value ?? [
            "gpt-5.6-luna:none",
            "gpt-5.6-luna:low",
            "gpt-5.6-luna:xhigh",
            "gpt-5.6-terra:none",
            "gpt-5.6-terra:low",
            "gpt-5.6-terra:medium"
        ].joined(separator: ",")
        return try raw.split(separator: ",").map { item in
            guard
                let separator = item.lastIndex(of: ":"),
                separator != item.startIndex,
                let effort = LiveAssistantReasoningEffort(
                    rawValue: String(item[item.index(after: separator)...])
                )
            else {
                throw PrivateBenchmarkError.invalidConfiguration(String(item))
            }
            return PrivateModelConfiguration(
                model: String(item[..<separator]),
                reasoningEffort: effort
            )
        }
    }

    private static func references(
        for benchmarkCase: PrivateBenchmarkCase
    ) async throws -> ReferenceLibrarySnapshot {
        let local = try ReferenceLibraryScanner().scan(
            folderURL: URL(
                fileURLWithPath: benchmarkCase.referenceFolderPath,
                isDirectory: true
            )
        )
        let webDocuments = try await referenceDocuments(
            from: benchmarkCase.referenceURLs ?? []
        )
        guard !webDocuments.isEmpty else { return local }

        let documents = local.documents + webDocuments
        return ReferenceLibrarySnapshot(
            folderURL: local.folderURL,
            documents: documents,
            revision: revision(for: documents),
            indexedAt: local.indexedAt,
            ignoredFileCount: local.ignoredFileCount,
            issues: local.issues
        )
    }

    private static func referenceDocuments(
        from values: [String]
    ) async throws -> [ReferenceDocument] {
        var documents: [ReferenceDocument] = []
        for value in values {
            guard
                let url = URL(string: value),
                let scheme = url.scheme?.lowercased(),
                scheme == "https" || scheme == "http"
            else {
                throw PrivateBenchmarkError.invalidReferenceURL(value)
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(
                "PermanentUnderclass URL discovery benchmark",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                throw PrivateBenchmarkError.referenceFetchFailed(value)
            }

            let rawText: String
            if httpResponse.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().contains("text/html") == true
            {
                rawText = try NSAttributedString(
                    data: data,
                    options: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ],
                    documentAttributes: nil
                ).string
            } else {
                rawText = String(decoding: data, as: UTF8.self)
            }

            let normalized = normalizedWebText(rawText)
            let maximumCharacters = 200_000
            let isTruncated = normalized.count > maximumCharacters
            documents.append(
                ReferenceDocument(
                    relativePath: url.absoluteString,
                    kind: .structuredText,
                    content: isTruncated
                        ? String(normalized.prefix(maximumCharacters))
                        : normalized,
                    sourceByteCount: data.count,
                    isTruncated: isTruncated
                )
            )
        }
        return documents
    }

    private static func normalizedWebText(_ text: String) -> String {
        var lines: [String] = []
        var previousLineWasEmpty = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !previousLineWasEmpty {
                    lines.append("")
                }
                previousLineWasEmpty = true
            } else {
                lines.append(line)
                previousLineWasEmpty = false
            }
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func revision(
        for documents: [ReferenceDocument]
    ) -> String {
        var hasher = SHA256()
        for document in documents {
            hasher.update(data: Data(document.relativePath.utf8))
            hasher.update(data: Data(document.content.utf8))
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func summaries(
        from results: [PrivateBenchmarkResult],
        attemptCounts: [String: Int],
        failureCounts: [String: Int]
    ) -> [PrivateBenchmarkSummary] {
        let grouped = Dictionary(grouping: results) {
            "\($0.configuration)|\($0.promptVariant)"
        }
        return grouped.values.map { group in
            let first = group[0]
            let key = "\(first.configuration)|\(first.promptVariant)"
            let latencies = group.map(\.generationMilliseconds).sorted()
            let middle = latencies.count / 2
            let median = latencies.count.isMultiple(of: 2)
                ? Double(latencies[middle - 1] + latencies[middle]) / 2
                : Double(latencies[middle])
            let attemptCount = attemptCounts[key] ?? group.count
            let meanLatency = Double(latencies.reduce(0, +))
                / Double(latencies.count)
            let p95Index = max(
                0,
                Int(ceil(Double(latencies.count) * 0.95)) - 1
            )
            return PrivateBenchmarkSummary(
                type: "ANSWER_MIRROR_BENCHMARK_SUMMARY",
                configuration: first.configuration,
                promptVariant: first.promptVariant,
                attemptCount: attemptCount,
                successCount: group.count,
                failureCount: failureCounts[key] ?? 0,
                successRate: Double(group.count)
                    / Double(max(1, attemptCount)),
                meanQuality: group.map(\.qualityMean).reduce(0, +)
                    / Double(group.count),
                meanSpokenNaturalness: group
                    .map { Double($0.spokenNaturalness) }
                    .reduce(0, +) / Double(group.count),
                meanSpecificity: group
                    .map { Double($0.specificity) }
                    .reduce(0, +) / Double(group.count),
                meanAnchorRelevance: group
                    .map { Double($0.anchorRelevance) }
                    .reduce(0, +) / Double(group.count),
                meanTemporalJudgment: group
                    .map { Double($0.temporalJudgment) }
                    .reduce(0, +) / Double(group.count),
                meanGenerationMilliseconds: meanLatency,
                medianGenerationMilliseconds: median,
                p95GenerationMilliseconds: latencies[p95Index],
                maximumGenerationMilliseconds: latencies.last ?? 0
            )
        }
        .sorted {
            if $0.successRate != $1.successRate {
                return $0.successRate > $1.successRate
            }
            if $0.meanQuality == $1.meanQuality {
                return $0.medianGenerationMilliseconds
                    < $1.medianGenerationMilliseconds
            }
            return $0.meanQuality > $1.meanQuality
        }
    }

    private static func encodedLine<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct PrivateBenchmarkSuite: Decodable {
    let cases: [PrivateBenchmarkCase]
    let promptVariants: [PrivatePromptVariant]?
}

private struct PrivateBenchmarkCase: Decodable {
    let name: String
    let question: String
    let recentTranscript: String?
    let currentPartial: String?
    let sessionContext: String?
    let referenceFolderPath: String
    let referenceURLs: [String]?
    let answerMode: AssistantAnswerMode
    let expectedGrounding: CompanionSuggestionGrounding

    var referenceSourceKey: String {
        ([referenceFolderPath] + (referenceURLs ?? []))
            .joined(separator: "\n")
    }
}

private struct PrivatePromptVariant: Decodable {
    let name: String
    let instructions: String?
}

private struct PrivateModelConfiguration {
    let model: String
    let reasoningEffort: LiveAssistantReasoningEffort

    var id: String { "\(model):\(reasoningEffort.rawValue)" }
}

private struct PrivateBenchmarkResult: Encodable {
    let type = "ANSWER_MIRROR_BENCHMARK_RESULT"
    let caseName: String
    let configuration: String
    let promptVariant: String
    let repetition: Int
    let generationMilliseconds: Int
    let modelCalls: Int
    let qualityMean: Double
    let directness: Int
    let spokenNaturalness: Int
    let plainSpokenLanguage: Int
    let specificity: Int
    let anchorRelevance: Int
    let temporalJudgment: Int
    let causalUsefulness: Int
    let mechanisticDepth: Int
    let verificationRigor: Int
    let groundingSafety: Int
    let plausibilitySafety: Int
    let answerModeUsefulness: Int
    let conciseUsability: Int
    let grounding: String
    let answerMode: String
    let cue: String
    let plausibleAssumptions: [String]
    let plausibleRehearsalPlan: CompanionPlausibleRehearsalPlan?
    let rationale: String
}

private struct PrivateBenchmarkSummary: Encodable {
    let type: String
    let configuration: String
    let promptVariant: String
    let attemptCount: Int
    let successCount: Int
    let failureCount: Int
    let successRate: Double
    let meanQuality: Double
    let meanSpokenNaturalness: Double
    let meanSpecificity: Double
    let meanAnchorRelevance: Double
    let meanTemporalJudgment: Double
    let meanGenerationMilliseconds: Double
    let medianGenerationMilliseconds: Double
    let p95GenerationMilliseconds: Int
    let maximumGenerationMilliseconds: Int
}

private enum PrivateBenchmarkError: LocalizedError {
    case invalidConfiguration(String)
    case invalidReferenceURL(String)
    case referenceFetchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(value):
            "Invalid benchmark configuration: \(value)"
        case let .invalidReferenceURL(value):
            "Invalid benchmark reference URL: \(value)"
        case let .referenceFetchFailed(value):
            "Could not fetch benchmark reference URL: \(value)"
        }
    }
}

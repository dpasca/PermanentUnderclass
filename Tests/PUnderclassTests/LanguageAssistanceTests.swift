import Foundation
import XCTest
@testable import PUnderclass

final class LanguageAssistanceTests: XCTestCase {
    func testLateTranslationsCanFinishTheTailButCannotRewriteCompletedPassages() {
        let completed = Passage(source: "はい。", translation: "Yes.", isComplete: true)
        let previous = language([completed, .init(source: "次に", translation: "Next…", isComplete: false)])
        let finished = language([completed, .init(source: "次に確認します。", translation: "Next, I'll check.", isComplete: true)])
        XCTAssertTrue(finished.preservesCompletedPassages(of: previous))
        XCTAssertFalse(language([.init(source: "はい。次に確認します。", translation: "Yes. Next, I'll check.", isComplete: true)])
            .preservesCompletedPassages(of: previous))
        XCTAssertFalse(language([]).preservesCompletedPassages(of: previous))
    }

    func testStoppedHistoryRetainsLivePassagesAcrossFinalCorrectionsAndReconnects() async throws {
        let hub = CompanionEventHub(streamID: "stopped-language")
        await hub.updateSession(isListening: true, status: "Listening", languageAssistanceMode: .translation)
        var live = try XCTUnwrap(parse(Self.response(reply: nil), mode: .translation).suggestion)
        live.topicID = "turn"
        await hub.assistantSuggested(live)
        await hub.updateSession(isListening: false, status: "Stopped", languageAssistanceMode: .translation)
        var final = live
        final.question = "Revised final source"
        final.languageAssistance = CompanionLanguageAssistance(sourceLanguage: "ja", translation: "Revised translation", reply: nil)
        await hub.assistantSuggested(final)
        let snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.translationHistory?.first?.question, final.question)
        XCTAssertEqual(snapshot.assistant.stoppedTranslationHistory?.first?.languageAssistance, live.languageAssistance)
        let reconnected = try JSONDecoder().decode(CompanionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(reconnected.assistant.stoppedTranslationHistory, snapshot.assistant.stoppedTranslationHistory)
        var late = final
        late.topicID = "late-turn"
        await hub.assistantSuggested(late)
        let withLateTurn = await hub.snapshot()
        XCTAssertEqual(withLateTurn.assistant.stoppedTranslationHistory?.count, 2)
        await hub.clearTranscript()
        let cleared = await hub.snapshot()
        XCTAssertNil(cleared.assistant.stoppedTranslationHistory)
    }

    func testTranscriptExportKeepsPairedPassagesAndDoesNotDropFinalCorrections() {
        let original = language([
            .init(source: "はい。", translation: "Yes.", isComplete: true),
            .init(source: "次に", translation: "Next…", isComplete: false)
        ])
        let text = LanguageTranscriptPresentation.text(source: "はい。次に領収書です。", language: original)
        XCTAssertTrue(text.contains("Passage 1\nはい。\nYes."))
        XCTAssertTrue(text.contains("Passage 2 (live draft)\n次に\nNext…"))
        XCTAssertTrue(text.hasSuffix("はい。次に領収書です。"))
        XCTAssertEqual(LanguageTranscriptPresentation.text(source: "Ordinary meeting", language: nil), "Ordinary meeting")
    }

    private typealias Passage = CompanionLanguageAssistance.Passage

    private func language(_ passages: [Passage]) -> CompanionLanguageAssistance {
        .init(sourceLanguage: "ja", translation: passages.map(\.translation).joined(separator: " "),
            reply: nil, passages: passages)
    }

    func testLongSpeechCommitsShortPassagesAndOnlyRetranslatesTheRemainder() throws {
        let first = Passage(source: "今日は税金の話です。", translation: "Today we're discussing taxes.", isComplete: true)
        let draft = Passage(source: "まず", translation: "First…", isComplete: false)
        let initial = language([first, draft])
        let progress = LiveLanguageTranslationProgress(source: first.source + "まず領収書を確認します。次に", previous: initial)
        XCTAssertEqual(progress.completed, [first])
        XCTAssertEqual(progress.target, "まず領収書を確認します。次に")
        XCTAssertTrue(progress.context.contains(first.translation))
        let second = Passage(source: "まず領収書を確認します。", translation: "First, we'll check the receipts.", isComplete: true)
        let nextDraft = Passage(source: "次に", translation: "Next…", isComplete: false)
        let merged = progress.merging(language([second, nextDraft]), finalized: false)
        XCTAssertEqual(merged.passages, [first, second, nextDraft])
        XCTAssertEqual(merged.translation, [first.translation, second.translation, nextDraft.translation].joined(separator: "\n\n"))
        XCTAssertEqual(try JSONDecoder().decode(CompanionLanguageAssistance.self,
            from: JSONEncoder().encode(merged)), merged)
    }

    func testHundredsOfPodcastUpdatesKeepCompletedEnglishUnchanged() {
        var previous: CompanionLanguageAssistance?
        var source = ""
        for index in 0..<100 {
            let next = Passage(source: "項目\(index)です。", translation: "This is item \(index).", isComplete: true)
            source += next.source
            let progress = LiveLanguageTranslationProgress(source: source, previous: previous)
            XCTAssertEqual(progress.target, next.source)
            let update = progress.merging(language([next]), finalized: false)
            XCTAssertEqual(Array(update.passages!.dropLast()), previous?.passages ?? [])
            previous = update
        }
        XCTAssertEqual(previous?.passages?.count, 100)
        XCTAssertEqual(previous?.passages?.map(\.source).joined(), source)
    }

    func testASRCorrectionsInvalidateOnlyTheAffectedPassageAndLaterText() {
        let first = Passage(source: "期限は金曜日です。", translation: "The deadline is Friday.", isComplete: true)
        let wrong = Passage(source: "金額は五万円です。", translation: "The amount is 50,000 yen.", isComplete: true)
        let corrected = Passage(source: "金額は十五万円です。", translation: "The amount is 150,000 yen.", isComplete: true)
        let progress = LiveLanguageTranslationProgress(source: first.source + corrected.source, previous: language([first, wrong]))
        XCTAssertEqual(progress.completed, [first])
        XCTAssertEqual(progress.target, corrected.source)
        XCTAssertTrue(progress.revisesCompletedPassage)
        let merged = progress.merging(language([corrected]), finalized: true)
        XCTAssertEqual(merged.passages?.first, first)
        XCTAssertEqual(merged.passages?.last?.wasRevised, true)
        XCTAssertEqual(merged.passages?.last?.translation, corrected.translation)
        XCTAssertFalse(merged.translation.contains(wrong.translation))
    }

    func testMisalignedOrOutOfOrderPassagesStayDraftsWithoutDroppingSource() {
        let source = "今日は  日本語です。\n続きです。"
        let invalidPartitions: [[Passage]] = [
            [],
            [.init(source: "invented", translation: "Invented.", isComplete: true)],
            [.init(source: source, translation: " ", isComplete: true)],
            [.init(source: "今日は  日本語です。\n", translation: "Japanese today…", isComplete: false),
             .init(source: "続きです。", translation: "Continuing.", isComplete: true)]
        ]
        for passages in invalidPartitions {
            let result = CompanionLanguageAssistance(sourceLanguage: "ja", translation: "Japanese today. Continuing.", reply: nil, passages: passages)
            let merged = LiveLanguageTranslationProgress(source: source, previous: nil).merging(result, finalized: true)
            XCTAssertEqual(merged.passages?.count, 1)
            XCTAssertEqual(merged.passages?.first?.source, source)
            XCTAssertEqual(merged.passages?.first?.isComplete, false)
            XCTAssertEqual(LiveLanguageTranslationProgress(source: source + "続き", previous: merged).completed, [])
        }
    }

    func testFinalizationKeepsAlreadyCompletedWordingAndFinishesAlignedDraft() {
        let first = Passage(source: "はい。", translation: "Yes.", isComplete: true)
        let progress = LiveLanguageTranslationProgress(source: first.source, previous: language([first]))
        let rewritten = Passage(source: first.source, translation: "That's correct.", isComplete: true)
        XCTAssertEqual(progress.merging(language([rewritten]), finalized: true).passages, [first])
        let unfinished = Passage(source: "こちらは", translation: "This is…", isComplete: false)
        let finalized = LiveLanguageTranslationProgress(source: unfinished.source, previous: nil)
            .merging(language([unfinished]), finalized: true)
        XCTAssertEqual(finalized.passages?.first?.isComplete, true)
        XCTAssertEqual(finalized.passages?.first?.translation, "This is…")
    }

    func testAlignedPassagesPreserveUnicodeAndWhitespaceExactly() {
        let passages: [Passage] = [
            .init(source: "日本語です。\n", translation: "It's Japanese.", isComplete: true),
            .init(source: "  続きです。🙂", translation: "Continuing. 🙂", isComplete: true)
        ]
        let source = passages.map(\.source).joined()
        let merged = LiveLanguageTranslationProgress(source: source, previous: nil)
            .merging(language(passages), finalized: false)
        XCTAssertEqual(merged.passages, passages)
        XCTAssertEqual(LiveLanguageTranslationProgress(source: source + " 次は", previous: merged).target, " 次は")
    }

    func testJapaneseHintsAndEngineCapabilityRouting() throws {
        let languages = LanguageAssistanceMode.translation.transcriptionLanguages(from: ["en", "de"])
        XCTAssertEqual(languages, ["de", "en", "ja"])
        XCTAssertEqual(LanguageAssistanceMode.off.transcriptionLanguages(from: []), [])
        XCTAssertNil(WhisperTranscriber.singleLanguageHint(from: languages))
        XCTAssertEqual(WhisperTranscriber.singleLanguageHint(from: ["ja"]), "ja")
        for code in ["ja", "JA", "ja-JP", "ja_JP"] {
            XCTAssertEqual(TranscriptionLanguagePolicy.resolvedEngine(
                preferring: .localParakeet, languages: ["en", code]
            ), .localWhisper)
        }
        XCTAssertEqual(TranscriptionLanguagePolicy.resolvedEngine(
            preferring: .localParakeet, languages: ["en", "fr"]
        ), .localParakeet)
        XCTAssertEqual(TranscriptionLanguagePolicy.resolvedEngine(
            preferring: .openAITranscribe, languages: languages
        ), .openAITranscribe)
        let privateCapability = CloudCapability(hasAPIKey: true, privacyLockEnabled: true)
        XCTAssertEqual(TranscriptionLanguagePolicy.resolvedEngine(
            preferring: privateCapability.resolvedEngine(preferring: .openAITranscribe),
            languages: languages
        ), .localWhisper)

        let context = TranscriptionContext(prompt: "Transcribe verbatim.", keywords: [], languages: languages, delay: .medium)
        let event = try object(RealtimeTranscriptionClient.sessionUpdateJSON(context))
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["languages"] as? [String], languages)
    }

    func testTranslationOnlyAcceptsStatementsWithoutAnswerBeats() throws {
        let result = try parse(Self.response(reply: nil), mode: .translation)
        let suggestion = try XCTUnwrap(result.suggestion)
        XCTAssertEqual(suggestion.languageAssistance?.translation, "Please send the receipts by Friday.")
        XCTAssertTrue(suggestion.beats.isEmpty)
        XCTAssertNil(suggestion.languageAssistance?.reply)
        XCTAssertEqual(suggestion.question, "金曜日までに領収書を送ってください。")
        XCTAssertThrowsError(try parse(Self.response(reply: nil), mode: .off))
    }

    func testReplyReadingsSurviveCompanionAndArchiveEncoding() throws {
        let result = try parse(Self.response(reply: Self.reply), mode: .translationAndReplies)
        let suggestion = try XCTUnwrap(result.suggestion)
        let encoded = try JSONEncoder().encode(suggestion)
        let decoded = try JSONDecoder().decode(CompanionAssistantSuggestion.self, from: encoded)
        XCTAssertEqual(decoded, suggestion)
        XCTAssertEqual(decoded.languageAssistance?.reply?.segments.map(\.text).joined(), "確認します。")
        XCTAssertEqual(decoded.languageAssistance?.reply?.segments.first?.reading, "かくにん")
        XCTAssertEqual(decoded.languageAssistance?.reply?.kana, "かくにんします。")
        XCTAssertEqual(decoded.languageAssistance?.reply?.romaji, "Kakunin shimasu.")

        // Existing archived cues predate the optional language payload.
        var legacy = try object(encoded)
        legacy.removeValue(forKey: "languageAssistance")
        let legacyCue = try JSONDecoder().decode(CompanionAssistantSuggestion.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyCue.languageAssistance)
    }

    func testRejectsMissingTranslationOrUnreadableReplyAndEnforcesTranslationOnly() throws {
        XCTAssertThrowsError(try parse(Self.response(reply: Self.reply), mode: .translation))
        var unreadable = Self.reply
        unreadable["romaji"] = "  "
        XCTAssertThrowsError(try parse(Self.response(reply: unreadable), mode: .translationAndReplies))
        XCTAssertThrowsError(try parse(Self.response(reply: nil, translation: "  "), mode: .translation))
    }

    func testBothProvidersUseTheSameStrictTranslationSchema() throws {
        let plan = AssistantPromptPlan(cachedPrefix: "Translate", volatileSuffix: "領収書", promptCacheKey: "language-test")
        let openAI = try object(LiveAssistantClient.requestBody(
            for: plan, purpose: .meeting, webSearchMode: .disabled, languageAssistance: .translationAndReplies))
        let gemini = try object(GeminiLiveAssistantAPI.requestBody(
            for: plan, purpose: .meeting, webSearchMode: .disabled, languageAssistance: .translationAndReplies))
        let text = try XCTUnwrap(openAI["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let geminiFormat = try XCTUnwrap(gemini["response_format"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: schema).isEqual(to: try XCTUnwrap(geminiFormat["schema"] as? [String: Any])))
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(openAI["max_output_tokens"] as? Int ?? 0, 1_600)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["languageAssistance"])
        XCTAssertNil(properties["plausibleRehearsalPlan"])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(Set(required), Set(properties.keys))
        XCTAssertNil(openAI["tools"])
        XCTAssertNil(gemini["tools"])
    }

    func testGenerationOverridesRehearsalAndSearchWithLanguageContract() async throws {
        let recorder = LanguageRequestRecorder()
        let response = try Self.response(reply: Self.reply)
        let client = LiveAssistantClient(responseLoader: { _, body in
            await recorder.record(body)
            return response
        })
        let result = try await client.generate(
            apiKey: "fixture-key", references: nil, recentTranscript: "", currentPartial: "",
            otherSpeakerText: "金曜日までに領収書を送ってください。",
            purpose: .interview, basedOnSequence: 3, webSearchMode: .required,
            answerMode: .plausibleRehearsal, deliveryMode: .instantText,
            languageAssistance: .translationAndReplies)
        XCTAssertEqual(result.suggestion?.answerMode, .grounded)
        XCTAssertEqual(result.deliveryMode, .verified)
        let recorded = await recorder.body
        let body = try object(XCTUnwrap(recorded))
        XCTAssertNil(body["tools"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let prompt = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(prompt.contains("Translate the response target into English"))
        XCTAssertTrue(prompt.contains("Never invent the user's finances"))
        XCTAssertFalse(prompt.contains("ANSWER MODE: PLAUSIBLE REHEARSAL"))
    }

    func testFinalizationRechecksPartialTranslationsEvenWhenTextIsUnchanged() {
        XCTAssertTrue(AssistantEvaluationPolicy.shouldReevaluateFinalizedLanguageTurn(
            mode: .translationAndReplies, trigger: .finalizedTurn, previousTrigger: .partialTranscript))
        XCTAssertFalse(AssistantEvaluationPolicy.shouldReevaluateFinalizedLanguageTurn(
            mode: .off, trigger: .finalizedTurn, previousTrigger: .partialTranscript))
        XCTAssertFalse(AssistantEvaluationPolicy.shouldReevaluateFinalizedLanguageTurn(
            mode: .translation, trigger: .finalizedTurn, previousTrigger: .finalizedTurn))
    }

    func testContinuousTranslationOmitsReferenceCorpusAndDescribesOngoingSpeech() async throws {
        let recorder = LanguageRequestRecorder()
        let response = try Self.response(reply: nil)
        let client = LiveAssistantClient(responseLoader: { _, body in
            await recorder.record(body)
            return response
        })
        let references = ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/fixture"),
            documents: [ReferenceDocument(relativePath: "notes.txt", kind: .text,
                content: "UNRELATED_REFERENCE_CORPUS", sourceByteCount: 26, isTruncated: false)],
            revision: "fixture", indexedAt: Date(), ignoredFileCount: 0, issues: [])
        _ = try await client.generate(apiKey: "fixture-key", references: references,
            recentTranscript: "", currentPartial: "領収書を", otherSpeakerText: "領収書を",
            purpose: .meeting, basedOnSequence: 1, trigger: .partialTranscript,
            languageAssistance: .translation, translatedSpeechContext: "Earlier translated speech in this turn: PREVIOUS_PASSAGE")
        let recorded = await recorder.body
        let body = String(decoding: try XCTUnwrap(recorded), as: UTF8.self)
        XCTAssertFalse(body.contains("UNRELATED_REFERENCE_CORPUS"))
        XCTAssertTrue(body.contains("PREVIOUS_PASSAGE"))
        XCTAssertTrue(body.contains("short, aligned passages"))
        XCTAssertTrue(body.contains("while the speaker may still be talking"))
    }

    func testLanguageSessionKeepsUnavailableAssistantStatus() async {
        let hub = CompanionEventHub(streamID: "language-session")
        _ = await hub.updateSession(isListening: true, status: "Listening", purpose: .meeting,
            languageAssistanceMode: .translationAndReplies)
        let active = await hub.snapshot()
        XCTAssertEqual(active.session.languageAssistanceMode, .translationAndReplies)
        XCTAssertEqual(active.session.behaviorName, "Japanese language assistance")
        _ = await hub.updateSession(isListening: true, status: "Local only", purpose: .meeting,
            assistantAvailable: false, languageAssistanceMode: .translationAndReplies)
        let privateSession = await hub.snapshot()
        XCTAssertFalse(privateSession.session.assistantAvailable)
        XCTAssertEqual(privateSession.session.behaviorName, "Local transcript")
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testContinuousSpeechCoalescesWithoutReplacingInFlightText() throws {
        var queue = LiveLanguageTranslationQueue()
        queue.enqueue(request("one", "first words"))
        let inFlight = try XCTUnwrap(queue.takeNext())
        for index in 1...100 {
            queue.enqueue(request("one", "growing speech \(index)"))
        }
        XCTAssertEqual(inFlight.text, "first words")
        XCTAssertEqual(queue.takeNext()?.text, "growing speech 100")
        XCTAssertNil(queue.takeNext())
    }

    func testFinalTurnsSurviveNewSpeechAndRejectLatePartials() {
        var queue = LiveLanguageTranslationQueue()
        queue.enqueue(request("one", "partial"))
        queue.enqueue(request("one", "complete sentence", final: true))
        queue.enqueue(request("two", "next speaker turn"))
        queue.enqueue(request("one", "late partial"))
        XCTAssertEqual(queue.takeNext()?.text, "complete sentence")
        XCTAssertEqual(queue.takeNext()?.turnID, "two")
        queue.enqueue(request("one", "corrected sentence", final: true))
        XCTAssertEqual(queue.takeNext()?.text, "corrected sentence")
        XCTAssertNil(queue.takeNext())
        queue.reset()
        queue.enqueue(request("one", "new session"))
        XCTAssertEqual(queue.takeNext()?.text, "new session")
    }

    func testTranslationHistoryRetainsTurnsBeyondCueLimitAndReconnects() async throws {
        let hub = CompanionEventHub(streamID: "translation-history")
        for index in 0..<12 {
            var suggestion = try XCTUnwrap(parse(Self.response(reply: nil), mode: .translation).suggestion)
            suggestion.topicID = "turn-\(index)"
            _ = await hub.assistantSuggested(suggestion)
        }
        for _ in 0..<8 {
            var update = try XCTUnwrap(parse(Self.response(reply: nil), mode: .translation).suggestion)
            update.topicID = "turn-11"
            _ = await hub.assistantSuggested(update)
        }
        let snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.assistant.suggestionHistory.count, 4)
        XCTAssertEqual(snapshot.assistant.translationHistory?.count, 12)
        XCTAssertEqual(snapshot.assistant.translationHistory?.first?.topicID, "turn-0")
        let reconnected = try JSONDecoder().decode(CompanionSnapshot.self,
            from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(reconnected.assistant.translationHistory, snapshot.assistant.translationHistory)
        _ = await hub.clearTranscript()
        let cleared = await hub.snapshot()
        XCTAssertNil(cleared.assistant.translationHistory)
    }

    private func request(_ turnID: String, _ text: String, final: Bool = false) -> LiveLanguageTranslationRequest {
        LiveLanguageTranslationRequest(turnID: turnID, text: text,
            trigger: final ? .finalizedTurn : .partialTranscript,
            speaker: .other, purpose: .meeting, observedAt: Date())
    }

    private func parse(_ data: Data, mode: LanguageAssistanceMode) throws -> LiveAssistantGeneration {
        try LiveAssistantClient.parseResponse(data, allowedReferencePaths: [], basedOnSequence: 1,
            generationMilliseconds: 100, purpose: .meeting, languageAssistance: mode)
    }

    private static let reply: [String: Any] = [
        "segments": [["text": "確認", "reading": "かくにん"], ["text": "します。", "reading": ""]],
        "kana": "かくにんします。", "romaji": "Kakunin shimasu.", "meaning": "I'll check."
    ]

    private static func response(reply: [String: Any]?, translation: String = "Please send the receipts by Friday.") throws -> Data {
        let output: [String: Any] = [
            "shouldShow": true, "grounding": "generalKnowledge",
            "question": "金曜日までに領収書を送ってください。", "preamble": "", "beats": [],
            "citations": [], "confidence": "high", "usedExtrapolation": false,
            "plausibleAssumptions": [], "spokenCueContainsMetaCommentary": false,
            "languageAssistance": ["sourceLanguage": "ja", "translation": translation,
                "passages": [["source": "金曜日までに領収書を送ってください。", "translation": translation, "isComplete": true]],
                "reply": reply as Any? ?? NSNull()]
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]
        ])
    }
}

private actor LanguageRequestRecorder {
    var body: Data?
    func record(_ data: Data) { body = data }
}

import AppKit
import AVFAudio
import CoreGraphics
import XCTest
@testable import PUnderclass

final class PUnderclassTests: XCTestCase {
    func testVisibleAppTerminatesAfterItsLastWindowCloses() {
        let delegate = PUnderclassAppDelegate()

        XCTAssertTrue(
            delegate.applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }

    func testAppDelegateHandlesReopenWithoutDefaultWindowCreation() {
        let delegate = PUnderclassAppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(
                .shared,
                hasVisibleWindows: false
            )
        )
    }

    func testHeadlessModeUsesDocumentedShortcut() {
        XCTAssertEqual(
            HeadlessModeHotKey.displayName,
            "Control + Command + H"
        )
    }

    func testHeadlessModeNotificationReadsState() {
        let notification = Notification(
            name: .headlessModeDidChange,
            userInfo: [HeadlessModeNotification.isHeadlessKey: true]
        )

        XCTAssertEqual(HeadlessModeNotification.isHeadless(notification), true)
    }

    func testSpeakerLabelsAreDeterministic() {
        XCTAssertEqual(SpeakerTag.you.rawValue, "You")
        XCTAssertEqual(SpeakerTag.other.rawValue, "Other")
        XCTAssertEqual(SpeakerTag.other.displayName(for: .meeting), "Other")
        XCTAssertEqual(
            SpeakerTag.other.displayName(for: .interview),
            "Interviewer"
        )
    }

    func testRealtimeDeltaParsing() throws {
        let data = try XCTUnwrap(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_42","content_index":0,"delta":"Hello"}"#
                .data(using: .utf8)
        )
        XCTAssertEqual(
            RealtimeServerEvent.parse(data),
            .transcriptionDelta(itemID: "item_42", delta: "Hello")
        )
    }

    func testWebSocketRequestsATranscriptionSession() {
        XCTAssertEqual(
            RealtimeTranscriptionClient.webSocketURL.query,
            "intent=transcription"
        )
    }

    func testRealtimeSpeechTimingParsing() throws {
        let data = try XCTUnwrap(
            #"{"type":"input_audio_buffer.speech_started","audio_start_ms":1234,"item_id":"item_9"}"#
                .data(using: .utf8)
        )
        XCTAssertEqual(
            RealtimeServerEvent.parse(data),
            .speechStarted(itemID: "item_9", audioStartMS: 1234)
        )
    }

    func testRealtimeCommitParsing() throws {
        let data = try XCTUnwrap(
            #"{"type":"input_audio_buffer.committed","event_id":"event_1","previous_item_id":null,"item_id":"item_11"}"#
                .data(using: .utf8)
        )
        XCTAssertEqual(
            RealtimeServerEvent.parse(data),
            .audioCommitted(itemID: "item_11")
        )
    }

    func testTranscriptionCompletionUsageParsesDurationAndTokens() throws {
        let durationData = try XCTUnwrap(
            """
            {
              "type": "conversation.item.input_audio_transcription.completed",
              "item_id": "item_duration",
              "transcript": "Hello",
              "usage": {"type": "duration", "seconds": 12.75}
            }
            """.data(using: .utf8)
        )
        XCTAssertEqual(
            TranscriptionCompletionUsage.parse(from: durationData),
            TranscriptionCompletionUsage(
                billingUnit: .duration,
                seconds: 12.75,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                audioInputTokens: nil,
                textInputTokens: nil
            )
        )

        let tokenData = try XCTUnwrap(
            """
            {
              "type": "conversation.item.input_audio_transcription.completed",
              "item_id": "item_tokens",
              "transcript": "Hello",
              "usage": {
                "type": "tokens",
                "input_tokens": 13,
                "output_tokens": 9,
                "total_tokens": 22,
                "input_token_details": {"audio_tokens": 13, "text_tokens": 0}
              }
            }
            """.data(using: .utf8)
        )
        XCTAssertEqual(
            TranscriptionCompletionUsage.parse(from: tokenData),
            TranscriptionCompletionUsage(
                billingUnit: .tokens,
                seconds: nil,
                inputTokens: 13,
                outputTokens: 9,
                totalTokens: 22,
                audioInputTokens: 13,
                textInputTokens: 0
            )
        )
    }

    func testAPIExpenseSummarySeparatesLiveAndFinalAudio() {
        var summary = APIExpenseSummary()
        summary.record(
            OpenAITranscriptionUsageRecord(
                pass: .live,
                model: "gpt-live-transcribe",
                audioSeconds: 120,
                measurement: .serverReported
            )
        )
        summary.record(
            OpenAITranscriptionUsageRecord(
                pass: .final,
                model: "gpt-transcribe",
                audioSeconds: 60,
                measurement: .submittedAudioEstimate
            )
        )

        XCTAssertEqual(summary.liveAudioSeconds, 120)
        XCTAssertEqual(summary.finalAudioSeconds, 60)
        XCTAssertEqual(summary.liveCostUSD, 0.034, accuracy: 0.000_001)
        XCTAssertEqual(summary.finalCostUSD, 0.0045, accuracy: 0.000_001)
        XCTAssertEqual(summary.totalCostUSD, 0.0385, accuracy: 0.000_001)
        XCTAssertEqual(summary.serverReportedRecords, 1)
        XCTAssertEqual(summary.estimatedRecords, 1)
        XCTAssertEqual(summary.displayCost, "$0.04")
    }

    func testReferenceLibraryIndexesSupportedFilesInStableOrder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = folder.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        try "Senior software engineer".write(
            to: folder.appendingPathComponent("Resume.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Reduced p95 latency by 41%.".write(
            to: nested.appendingPathComponent("Checkout.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0x89, 0x50, 0x4e, 0x47]).write(
            to: folder.appendingPathComponent("portrait.png")
        )

        let scanner = ReferenceLibraryScanner()
        let first = try scanner.scan(
            folderURL: folder,
            indexedAt: Date(timeIntervalSince1970: 100)
        )
        let second = try scanner.scan(
            folderURL: folder,
            indexedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            first.documents.map(\.relativePath),
            ["Projects/Checkout.txt", "Resume.md"]
        )
        XCTAssertEqual(first.documents[0].content, "Reduced p95 latency by 41%.")
        XCTAssertEqual(first.documents[1].kind, .markdown)
        XCTAssertEqual(first.ignoredFileCount, 1)
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertNotEqual(first.indexedAt, second.indexedAt)
    }

    func testReferenceLibraryReportsExplicitTruncation() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try "0123456789".write(
            to: folder.appendingPathComponent("long.txt"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = ReferenceLibraryScanner(
            limits: ReferenceLibraryLimits(
                maximumFileBytes: 100,
                maximumDocumentCharacters: 5,
                maximumTotalCharacters: 5
            )
        )
        let snapshot = try scanner.scan(folderURL: folder)

        XCTAssertEqual(snapshot.documents.map(\.content), ["01234"])
        XCTAssertTrue(snapshot.documents[0].isTruncated)
        XCTAssertEqual(snapshot.issues.count, 1)
        XCTAssertTrue(snapshot.issues[0].message.contains("first 5 characters"))
    }

    func testReferenceLibraryServiceReindexesAfterFolderChange() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try "First fact".write(
            to: folder.appendingPathComponent("one.txt"),
            atomically: true,
            encoding: .utf8
        )

        let initialIndex = expectation(description: "Initial reference index")
        let changedIndex = expectation(description: "Changed reference index")
        var initialRevision: String?
        let service = ReferenceLibraryService { state in
            guard state.phase == .ready, let snapshot = state.snapshot else { return }
            if initialRevision == nil {
                initialRevision = snapshot.revision
                initialIndex.fulfill()
            } else if
                snapshot.documents.count == 2,
                snapshot.revision != initialRevision
            {
                changedIndex.fulfill()
            }
        }
        defer { service.stop() }

        service.setFolder(folder)
        wait(for: [initialIndex], timeout: 3)
        try "Second fact".write(
            to: folder.appendingPathComponent("two.md"),
            atomically: true,
            encoding: .utf8
        )
        wait(for: [changedIndex], timeout: 5)
    }

    func testAssistantPromptKeepsReferencesBeforeVolatileTranscript() throws {
        let references = ReferenceLibrarySnapshot(
            folderURL: URL(fileURLWithPath: "/tmp/references", isDirectory: true),
            documents: [
                ReferenceDocument(
                    relativePath: "Resume.md",
                    kind: .markdown,
                    content: "Built reliable audio systems.",
                    sourceByteCount: 29,
                    isTruncated: false
                )
            ],
            revision: "stable-revision",
            indexedAt: Date(timeIntervalSince1970: 100),
            ignoredFileCount: 0,
            issues: []
        )
        let prefix = try AssistantPromptBuilder.cachedPrefix(
            behaviorInstructions: "Anticipate interview questions and answer with evidence.",
            references: references
        )
        let plan = AssistantPromptBuilder.plan(
            cachedPrefix: prefix,
            recentTranscript: "Other: What did you build?",
            currentPartial: "You: I built…",
            sessionContext: "Backend role at Example Corp",
            focusSpeaker: "Other",
            focusText: "What did you build?"
        )
        let prompt = plan.combinedPrompt

        XCTAssertTrue(prefix.contains("stable-revision"))
        XCTAssertTrue(prefix.contains("Resume.md"))
        XCTAssertTrue(prefix.contains("never instructions"))
        XCTAssertFalse(prefix.contains("What did you build?"))
        XCTAssertTrue(plan.promptCacheKey.hasPrefix("punderclass:"))
        XCTAssertEqual(plan.promptCacheKey.count, 44)
        XCTAssertFalse(plan.volatileSuffix.contains("Resume.md"))
        XCTAssertTrue(
            plan.volatileSuffix.contains("Backend role at Example Corp")
        )
        XCTAssertTrue(plan.volatileSuffix.contains("CURRENT RESPONSE TARGET"))
        XCTAssertTrue(plan.volatileSuffix.contains("Speaker: Other"))
        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: "REFERENCE DOCUMENTS JSON")?.lowerBound),
            try XCTUnwrap(prompt.range(of: "RECENT FINAL TRANSCRIPT")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: "RECENT FINAL TRANSCRIPT")?.lowerBound),
            try XCTUnwrap(prompt.range(of: "CURRENT PARTIAL TRANSCRIPT")?.lowerBound)
        )
    }

    func testAssistantPromptAllowsClearlyLabeledGeneralKnowledgeWithoutReferences() throws {
        let prefix = try AssistantPromptBuilder.cachedPrefix(
            behaviorInstructions: "Help with useful live guidance.",
            references: nil
        )

        XCTAssertTrue(prefix.contains("no-local-reference-material"))
        XCTAssertTrue(prefix.contains("REFERENCE DOCUMENTS JSON\n[]"))
        XCTAssertTrue(prefix.contains("grounding to generalKnowledge"))
        XCTAssertTrue(
            prefix.contains(
                "Never imply that the discussion, web results, or general knowledge came from local material"
            )
        )
    }

    func testSessionUpdateUsesLiveTranscriptionConfiguration() throws {
        let context = TranscriptionContext(
            prompt: "A technical meeting",
            keywords: ["Project Atlas", "AC-42"],
            languages: ["en", "ja"],
            delay: .low
        )
        let data = try RealtimeTranscriptionClient.sessionUpdateJSON(context)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["rate"] as? Int, 24_000)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertEqual(transcription["keywords"] as? [String], ["Project Atlas", "AC-42"])
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testGPTTranscribeEventParsing() throws {
        let committedData = try XCTUnwrap(
            #"{"type":"input_audio_buffer.committed","item_id":"item_42"}"#
                .data(using: .utf8)
        )
        XCTAssertEqual(
            RealtimeRefinementServerEvent.parse(committedData),
            .audioCommitted(itemID: "item_42")
        )

        let completedData = try XCTUnwrap(
            """
            {
              "type": "conversation.item.input_audio_transcription.completed",
              "item_id": "item_42",
              "transcript": "Thread blocks and warps.",
              "languages": [{"code": "en"}]
            }
            """.data(using: .utf8)
        )
        XCTAssertEqual(
            RealtimeRefinementServerEvent.parse(completedData),
            .transcriptionCompleted(
                itemID: "item_42",
                transcript: "Thread blocks and warps.",
                languages: ["en"]
            )
        )

        let failedData = try XCTUnwrap(
            """
            {
              "type": "conversation.item.input_audio_transcription.failed",
              "item_id": "item_43",
              "error": {"message": "The audio could not be transcribed."}
            }
            """.data(using: .utf8)
        )
        XCTAssertEqual(
            RealtimeRefinementServerEvent.parse(failedData),
            .transcriptionFailed(
                itemID: "item_43",
                message: "The audio could not be transcribed."
            )
        )
    }

    func testCancelledTranscriptionEventsCannotEnterTheNextDictation() {
        var filter = CancelledTranscriptionEventFilter()
        filter.abandon(
            acknowledgedItemIDs: ["item_known"],
            unacknowledgedCommitCount: 1
        )

        XCTAssertTrue(
            filter.shouldIgnore(
                .transcriptionDelta(itemID: "item_known", delta: "Old")
            )
        )
        XCTAssertTrue(
            filter.shouldIgnore(.audioCommitted(itemID: "item_late"))
        )
        XCTAssertTrue(
            filter.shouldIgnore(
                .transcriptionCompleted(
                    itemID: "item_known",
                    transcript: "Old text",
                    languages: ["en"]
                )
            )
        )
        XCTAssertTrue(
            filter.shouldIgnore(
                .transcriptionFailed(
                    itemID: "item_late",
                    message: "Cancelled"
                )
            )
        )

        XCTAssertFalse(
            filter.shouldIgnore(.audioCommitted(itemID: "item_current"))
        )
        XCTAssertFalse(
            filter.shouldIgnore(
                .transcriptionDelta(itemID: "item_current", delta: "New")
            )
        )
    }

    func testRefinementSessionUsesGPTTranscribe() throws {
        XCTAssertEqual(RealtimeRefinementClient.model, "gpt-transcribe")
        XCTAssertEqual(
            RealtimeRefinementClient.webSocketURL.query,
            "intent=transcription"
        )

        let data = try RealtimeRefinementClient.sessionUpdateJSON()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        // The endpoint rejects anything below 24 kHz, so capture audio goes out
        // unchanged.
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertEqual(RealtimeRefinementClient.captureSampleRate, 24_000)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-transcribe")
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testRefinementRequestConfiguresContextAndCommitsRawAudio() throws {
        let audio = Data([0, 1, 2, 3])
        let request = RealtimeRefinementRequest(
            transcriptID: "You-item_7",
            speaker: .you,
            pcm16Audio: audio,
            context: TranscriptionContext(
                prompt: "A GPU architecture discussion.",
                keywords: ["CUDA", "thread block", "warp"],
                languages: ["en"],
                delay: .medium
            ),
            recentTranscript: "Other: How are thread blocks organized?"
        )
        let data = try RealtimeRefinementClient.sessionUpdateJSON(request)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        let sessionAudio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(sessionAudio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-transcribe")
        XCTAssertEqual(
            transcription["keywords"] as? [String],
            ["CUDA", "thread block", "warp"]
        )
        XCTAssertEqual(transcription["languages"] as? [String], ["en"])
        let prompt = try XCTUnwrap(transcription["prompt"] as? String)
        XCTAssertTrue(prompt.contains("GPU architecture discussion"))
        XCTAssertTrue(prompt.contains("thread blocks organized"))
        XCTAssertNil(transcription["delay"])

        let appendData = try RealtimeRefinementClient.inputAudioAppendJSON(audio)
        let append = try XCTUnwrap(
            JSONSerialization.jsonObject(with: appendData) as? [String: String]
        )
        XCTAssertEqual(append["type"], "input_audio_buffer.append")
        XCTAssertEqual(append["audio"], audio.base64EncodedString())

        let commitData = try RealtimeRefinementClient.inputAudioCommitJSON()
        let commit = try XCTUnwrap(
            JSONSerialization.jsonObject(with: commitData) as? [String: String]
        )
        XCTAssertEqual(commit["type"], "input_audio_buffer.commit")

        let clearData = try RealtimeRefinementClient.inputAudioClearJSON()
        let clear = try XCTUnwrap(
            JSONSerialization.jsonObject(with: clearData) as? [String: String]
        )
        XCTAssertEqual(clear["type"], "input_audio_buffer.clear")
    }

    func testRefinementRejectsTurnsAfterFinishing() {
        let rejected = expectation(description: "Late refinement request rejected")
        let client = RealtimeRefinementClient(
            apiKey: "unused",
            onState: { _ in },
            onRefined: { _, _ in
                XCTFail("A closed refinement client must not return a transcript.")
            },
            onFailure: { transcriptID, message in
                XCTAssertEqual(transcriptID, "late-turn")
                XCTAssertTrue(message.contains("capture ended"))
                rejected.fulfill()
            }
        )

        client.finishWhenIdle()
        client.refine(
            RealtimeRefinementRequest(
                transcriptID: "late-turn",
                speaker: .you,
                pcm16Audio: Data([0, 1]),
                context: TranscriptionContext(
                    prompt: "",
                    keywords: [],
                    languages: ["en"],
                    delay: .medium
                ),
                recentTranscript: ""
            )
        )

        wait(for: [rejected], timeout: 2)
    }

    func testAudioPipelineConvertsToTwentyMillisecondPCMChunks() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)
        )
        buffer.frameLength = 4_800
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else {
                XCTFail("Missing float channel data")
                return
            }
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = sin(Float(frame) * 0.02) * 0.2
            }
        }

        let received = expectation(description: "Converted chunks")
        received.expectedFulfillmentCount = 4
        received.assertForOverFulfill = false
        let lock = NSLock()
        var sizes: [Int] = []
        let pipeline = AudioTrackPipeline(
            label: "PUnderclassTests.Audio",
            onChunk: { data in
                lock.lock()
                sizes.append(data.count)
                lock.unlock()
                received.fulfill()
            },
            onTelemetry: { _ in }
        )
        pipeline.submit(buffer)
        wait(for: [received], timeout: 2)
        pipeline.finish()

        lock.lock()
        let capturedSizes = sizes
        lock.unlock()
        XCTAssertGreaterThanOrEqual(capturedSizes.count, 4)
        XCTAssertTrue(capturedSizes.allSatisfy { $0 == 960 })
    }

    func testWhisperAudioConversionResamplesPCM16WithoutLosingSignal() throws {
        let inputSamples = (0..<24_000).map { frame in
            Int16(sin(Double(frame) * 0.04) * 12_000)
        }
        let pcm16Audio = inputSamples.withUnsafeBufferPointer { samples in
            Data(
                bytes: samples.baseAddress!,
                count: samples.count * MemoryLayout<Int16>.size
            )
        }

        let outputSamples = try WhisperTranscriber.audioSamples(
            from: pcm16Audio
        )
        let peak = outputSamples.map(abs).max() ?? 0

        XCTAssertGreaterThanOrEqual(outputSamples.count, 15_990)
        XCTAssertLessThanOrEqual(outputSamples.count, 16_010)
        XCTAssertGreaterThan(peak, 0.3)
        XCTAssertThrowsError(
            try WhisperTranscriber.audioSamples(from: Data([0]))
        )
    }

    func testDefaultInputMonitorPublishesTheCurrentDevice() throws {
        guard let expectedDevice = CoreAudioUtilities.defaultInputDevice() else {
            throw XCTSkip("This Mac currently has no default input device.")
        }

        let received = expectation(description: "Initial default input device")
        var observedDevice: AudioInputDeviceInfo?
        let monitor = DefaultInputDeviceMonitor { device in
            observedDevice = device
            received.fulfill()
        }
        try monitor.start()
        wait(for: [received], timeout: 2)
        monitor.stop()

        XCTAssertEqual(observedDevice, expectedDevice)
    }

    func testDefaultOutputMonitorPublishesTheCurrentDevice() throws {
        guard let expectedDevice = CoreAudioUtilities.defaultOutputDevice() else {
            throw XCTSkip("This Mac currently has no default output device.")
        }

        let received = expectation(description: "Initial default output device")
        var observedDevice: AudioOutputDeviceInfo?
        let monitor = DefaultOutputDeviceMonitor { device in
            observedDevice = device
            received.fulfill()
        }
        try monitor.start()
        wait(for: [received], timeout: 2)
        monitor.stop()

        XCTAssertEqual(observedDevice, expectedDevice)
    }

    func testAudioDeviceMenusIncludeTheCurrentDefaultsFirst() throws {
        var testedADeviceType = false

        if let defaultInput = CoreAudioUtilities.defaultInputDevice() {
            let inputs = try CoreAudioUtilities.availableInputDevices()
            XCTAssertEqual(inputs.first?.id, defaultInput.id)
            XCTAssertEqual(inputs.first?.name, defaultInput.name)
            testedADeviceType = true
        }

        if let defaultOutput = CoreAudioUtilities.defaultOutputDevice() {
            let outputs = try CoreAudioUtilities.availableOutputDevices()
            XCTAssertEqual(outputs.first?.id, defaultOutput.id)
            XCTAssertEqual(outputs.first?.name, defaultOutput.name)
            testedADeviceType = true
        }

        if !testedADeviceType {
            throw XCTSkip("This Mac currently has no default audio devices.")
        }
    }

    func testAudioHealthDistinguishesReadyHealthyDropsAndStalls() {
        let now = Date(timeIntervalSince1970: 100)
        var telemetry = TrackTelemetry(monitoringStartedAt: now.addingTimeInterval(-1))

        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: false,
                telemetry: telemetry,
                now: now
            ),
            .ready
        )
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now,
                detectDigitalSilence: true
            ),
            .checking
        )

        telemetry.packets = 12
        telemetry.lastPacketAt = now.addingTimeInterval(-0.2)
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now,
                detectDigitalSilence: true
            ),
            .healthy
        )

        telemetry.droppedBuffers = 1
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now,
                detectDigitalSilence: true
            ),
            .dropping
        )

        telemetry.lastPacketAt = now.addingTimeInterval(-3)
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now
            ),
            .noData
        )
    }

    func testAudioHealthPrioritizesAvailabilityAndMicrophoneAccess() {
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: false,
                permissionGranted: true,
                isMonitoring: false,
                telemetry: TrackTelemetry()
            ),
            .unavailable
        )
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                permissionGranted: false,
                isMonitoring: false,
                telemetry: TrackTelemetry()
            ),
            .permissionRequired
        )
    }

    func testAudioHealthDistinguishesDigitalSilenceFromStoppedPackets() {
        let now = Date(timeIntervalSince1970: 100)
        var telemetry = TrackTelemetry(
            packets: 20,
            monitoringStartedAt: now.addingTimeInterval(-8),
            lastPacketAt: now
        )

        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now
            ),
            .healthy,
            "Legitimate silence on the remote/system-audio track is not a microphone fault."
        )
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now,
                detectDigitalSilence: true
            ),
            .noSignal
        )

        telemetry.lastSignalAt = now.addingTimeInterval(-1)
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now,
                detectDigitalSilence: true
            ),
            .healthy
        )

        telemetry.lastPacketAt = now.addingTimeInterval(-3)
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now,
                detectDigitalSilence: true
            ),
            .noData
        )
    }

    func testAudioCaptureLivenessWaitsForTheTimeoutAndResetsOnBuffers() {
        let second: UInt64 = 1_000_000_000

        XCTAssertFalse(
            AudioCaptureLivenessPolicy.hasStalled(
                startedAtUptime: 10 * second,
                lastBufferAtUptime: nil,
                nowUptime: 12 * second - 1
            )
        )
        XCTAssertTrue(
            AudioCaptureLivenessPolicy.hasStalled(
                startedAtUptime: 10 * second,
                lastBufferAtUptime: nil,
                nowUptime: 12 * second
            )
        )
        XCTAssertFalse(
            AudioCaptureLivenessPolicy.hasStalled(
                startedAtUptime: 10 * second,
                lastBufferAtUptime: 11 * second,
                nowUptime: 12 * second
            )
        )
        XCTAssertTrue(
            AudioCaptureLivenessPolicy.hasStalled(
                startedAtUptime: 10 * second,
                lastBufferAtUptime: 11 * second,
                nowUptime: 13 * second
            )
        )
    }

    func testAudioCaptureWatchdogReportsMissingBufferDelivery() {
        let stalled = expectation(description: "Audio capture stalled")
        let watchdog = AudioBufferWatchdog(
            timeout: 0.04,
            checkInterval: 0.005
        ) {
            stalled.fulfill()
        }

        watchdog.start()
        wait(for: [stalled], timeout: 0.5)
        watchdog.stop()
    }

    func testAudioCaptureRecoveryUsesFastRetriesThenCapsTheBackoff() {
        XCTAssertEqual(AudioCaptureRecoveryPolicy.quickDictationRestartLimit, 2)
        XCTAssertEqual(
            AudioCaptureRecoveryPolicy.meetingRestartDelay(after: 1),
            0.28,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioCaptureRecoveryPolicy.meetingRestartDelay(after: 2),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioCaptureRecoveryPolicy.meetingRestartDelay(after: 3),
            3,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioCaptureRecoveryPolicy.meetingRestartDelay(after: 20),
            10,
            accuracy: 0.001
        )
    }

    func testAudioProcessSelectionSurvivesCoreAudioObjectReplacement() {
        let previous = AudioProcessInfo(
            id: 41,
            pid: 1_001,
            name: "LINE.MediaService",
            bundleIdentifier: "jp.naver.line.mac",
            isProducingOutput: true
        )
        let replacement = AudioProcessInfo(
            id: 77,
            pid: 2_002,
            name: "LINE.MediaService",
            bundleIdentifier: "jp.naver.line.mac",
            isProducingOutput: true
        )
        let unrelated = AudioProcessInfo(
            id: 88,
            pid: 3_003,
            name: "Music",
            bundleIdentifier: "com.apple.Music",
            isProducingOutput: true
        )

        XCTAssertEqual(
            AudioProcessSelectionResolver.resolve(
                previous: previous,
                candidates: [unrelated, replacement]
            ),
            replacement
        )
    }

    func testAudioProcessSelectionPrefersSamePIDWhenObjectIDChanges() {
        let previous = AudioProcessInfo(
            id: 41,
            pid: 1_001,
            name: "Old helper name",
            bundleIdentifier: nil,
            isProducingOutput: true
        )
        let replacement = AudioProcessInfo(
            id: 77,
            pid: 1_001,
            name: "New helper name",
            bundleIdentifier: nil,
            isProducingOutput: true
        )

        XCTAssertEqual(
            AudioProcessSelectionResolver.resolve(
                previous: previous,
                candidates: [replacement]
            ),
            replacement
        )
    }

    func testModifierOnlyDictationChordStartsAndStops() {
        var state = ModifierHoldState()

        XCTAssertNil(state.update(flags: .maskCommand))
        XCTAssertEqual(
            state.update(flags: [.maskCommand, .maskAlternate]),
            .pressed
        )
        XCTAssertTrue(state.isHeld)
        XCTAssertNil(state.update(flags: [.maskCommand, .maskAlternate]))
        XCTAssertEqual(state.update(flags: .maskCommand), .released)
        XCTAssertFalse(state.isHeld)
    }

    func testModifierChordRejectsAdditionalModifiers() {
        var state = ModifierHoldState()

        XCTAssertNil(
            state.update(flags: [.maskCommand, .maskAlternate, .maskShift])
        )
        XCTAssertFalse(state.isHeld)
    }

    func testTypingAnotherKeyLeavesModifierOnlyDictationRunning() {
        var state = ModifierHoldState()

        XCTAssertEqual(
            state.update(flags: [.maskCommand, .maskAlternate]),
            .pressed
        )
        let shouldInterrupt = ModifierHoldMonitor.shouldInterruptForKeyDown(
            keyCode: 0,
            eventTag: 0,
            isDiagnosticHold: false
        )
        if shouldInterrupt {
            _ = state.interruptForEscape()
        }

        XCTAssertFalse(shouldInterrupt)
        XCTAssertTrue(state.isHeld)
    }

    func testAddedModifierLeavesActiveDictationRunning() {
        var state = ModifierHoldState()

        XCTAssertEqual(
            state.update(flags: [.maskCommand, .maskAlternate]),
            .pressed
        )
        XCTAssertNil(
            state.update(
                flags: [.maskCommand, .maskAlternate, .maskShift]
            )
        )
        XCTAssertTrue(state.isHeld)
        XCTAssertEqual(state.update(flags: [.maskCommand, .maskShift]), .released)
    }

    func testEscapeInterruptsModifierOnlyDictation() {
        var state = ModifierHoldState()

        XCTAssertEqual(
            state.update(flags: [.maskCommand, .maskAlternate]),
            .pressed
        )
        XCTAssertTrue(
            ModifierHoldMonitor.shouldInterruptForKeyDown(
                keyCode: ModifierHoldMonitor.escapeKeyCode,
                eventTag: 0,
                isDiagnosticHold: false
            )
        )
        XCTAssertEqual(state.interruptForEscape(), .interrupted)
        XCTAssertFalse(state.isHeld)
        XCTAssertNil(state.interruptForEscape())
    }

    func testAutomaticPasteDoesNotCancelParallelDictation() {
        var state = ModifierHoldState()
        XCTAssertEqual(
            state.update(flags: [.maskCommand, .maskAlternate]),
            .pressed
        )

        let shouldInterrupt = ModifierHoldMonitor.shouldInterruptForKeyDown(
            keyCode: ModifierHoldMonitor.escapeKeyCode,
            eventTag: ModifierHoldMonitor.pasteEventTag,
            isDiagnosticHold: false
        )
        if shouldInterrupt {
            _ = state.interruptForEscape()
        }

        XCTAssertFalse(shouldInterrupt)
        XCTAssertTrue(state.isHeld)
        XCTAssertFalse(
            ModifierHoldMonitor.shouldInterruptForKeyDown(
                keyCode: ModifierHoldMonitor.escapeKeyCode,
                eventTag: 0,
                isDiagnosticHold: true
            )
        )
    }

    func testPasteVerificationUsesAccessibilityUTF16SelectionRange() throws {
        let original = "alpha 👋 omega"
        let selectedRange = (original as NSString).range(of: "👋")
        let verification = try XCTUnwrap(
            QuickDictationPasteVerification(
                originalValue: original,
                selectedRange: CFRange(
                    location: selectedRange.location,
                    length: selectedRange.length
                ),
                insertedText: "beta"
            )
        )

        XCTAssertEqual(verification.expectedValue, "alpha beta omega")
        XCTAssertEqual(verification.expectedSelectedRange.location, 10)
        XCTAssertEqual(verification.expectedSelectedRange.length, 0)
        XCTAssertTrue(
            verification.matches(
                currentValue: "alpha beta omega",
                selectedRange: CFRange(location: 10, length: 0)
            )
        )
        XCTAssertFalse(
            verification.matches(
                currentValue: "alpha 👋 omega",
                selectedRange: CFRange(location: 6, length: 2)
            )
        )
    }

    func testITermPasteDeliveryDoesNotUseExactAccessibilityVerification() {
        let bundleIdentifier =
            QuickDictationPasteVerificationPolicy.iTermBundleIdentifier

        XCTAssertFalse(
            QuickDictationPasteVerificationPolicy.shouldVerify(
                bundleIdentifier: bundleIdentifier
            )
        )
        XCTAssertEqual(
            QuickDictationPasteVerificationPolicy
                .unverifiedDeliveryDelaySeconds(
                    bundleIdentifier: bundleIdentifier
                ),
            0.25
        )
    }

    func testOrdinaryTextTargetsKeepExactPasteVerification() {
        let bundleIdentifier = "com.apple.TextEdit"

        XCTAssertTrue(
            QuickDictationPasteVerificationPolicy.shouldVerify(
                bundleIdentifier: bundleIdentifier
            )
        )
        XCTAssertEqual(
            QuickDictationPasteVerificationPolicy
                .unverifiedDeliveryDelaySeconds(
                    bundleIdentifier: bundleIdentifier
                ),
            2
        )
    }

    func testClipboardRestoresAfterUnchangedPaste() {
        XCTAssertTrue(
            QuickDictationClipboardRestorationPolicy.shouldRestore(
                insertedChangeCount: 12,
                currentChangeCount: 12
            )
        )
        XCTAssertFalse(
            QuickDictationClipboardRestorationPolicy.shouldRestore(
                insertedChangeCount: 12,
                currentChangeCount: 13
            )
        )
    }

    func testUnprovenDeliveryKeepsDictationOnClipboardForTheDwell() {
        let dwell = QuickDictationClipboardRestorationPolicy.minimumDwellSeconds

        // The window that made a target paste the *previous* clipboard: the
        // restore used to run microseconds after the paste keystroke.
        XCTAssertEqual(
            QuickDictationClipboardRestorationPolicy.restoreDelaySeconds(
                elapsedSincePaste: 0,
                isDeliveryProven: false
            ),
            dwell
        )
        XCTAssertEqual(
            QuickDictationClipboardRestorationPolicy.restoreDelaySeconds(
                elapsedSincePaste: dwell / 2,
                isDeliveryProven: false
            ),
            dwell / 2,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            QuickDictationClipboardRestorationPolicy.restoreDelaySeconds(
                elapsedSincePaste: dwell * 4,
                isDeliveryProven: false
            ),
            0
        )
    }

    func testProvenDeliveryRestoresTheClipboardImmediately() {
        XCTAssertEqual(
            QuickDictationClipboardRestorationPolicy.restoreDelaySeconds(
                elapsedSincePaste: 0,
                isDeliveryProven: true
            ),
            0
        )
    }

    /// `.inserted` is the one outcome trusted enough to hand the clipboard back
    /// without waiting out the dwell, so it must never fire against a screen
    /// that already contained the text.
    func testTextAlreadyOnScreenIsNotMistakenForAFreshPaste() {
        let repeated = "please add the retry budget to the queue"
        let evidence = QuickDictationContentEvidence(
            originalValue: "$ echo \(repeated)",
            insertedText: repeated
        )

        XCTAssertEqual(
            evidence.evaluate(currentValue: "$ echo \(repeated)"),
            .unchanged
        )
        XCTAssertEqual(
            evidence.evaluate(currentValue: "$ echo \(repeated)\n$ \(repeated)"),
            .changed
        )
    }

    func testQuickDictationDoesNotSendSilenceToParakeet() {
        let silence = Data(repeating: 0, count: 9_600)
        XCTAssertFalse(PCM16SignalGate.containsAudibleSignal(silence))

        var audible = Data(repeating: 0, count: 9_600)
        withUnsafeBytes(of: Int16(65).littleEndian) { bytes in
            audible.replaceSubrange(100..<102, with: bytes)
        }
        XCTAssertTrue(PCM16SignalGate.containsAudibleSignal(audible))
    }

    func testQuickDictationFactoryBuildsTheSelectedPrimaryTranscriber() {
        let callbacks = DictationTranscriberCallbacks(
            onState: { _ in },
            onRefined: { _, _ in },
            onFailure: { _, _ in }
        )

        let whisper = QuickDictationTranscriberFactory.make(
            engine: .localWhisper,
            apiKey: "",
            callbacks: callbacks
        )
        let parakeet = QuickDictationTranscriberFactory.make(
            engine: .localParakeet,
            apiKey: "",
            callbacks: callbacks
        )
        let cloud = QuickDictationTranscriberFactory.make(
            engine: .openAITranscribe,
            apiKey: "test-key",
            callbacks: callbacks
        )

        XCTAssertTrue(whisper is WhisperRefinementClient)
        XCTAssertTrue(parakeet is ParakeetRefinementClient)
        XCTAssertTrue(cloud is RealtimeRefinementClient)
    }

    func testQuickDictationContextSharesTerminologyLanguagesAndCleanupStyle() {
        let base = TranscriptionContext(
            prompt: "  ",
            keywords: ["WhisperKit", "AVAudioConverter"],
            languages: ["en", "ja"],
            delay: .high
        )

        let context = QuickDictationContextPolicy.context(
            from: base,
            cleanDictation: true,
            delay: .medium
        )

        XCTAssertEqual(context.prompt, "")
        XCTAssertEqual(context.keywords, ["WhisperKit", "AVAudioConverter"])
        XCTAssertEqual(context.languages, ["en", "ja"])
        XCTAssertEqual(context.delay, .medium)
        XCTAssertEqual(context.outputStyle, .cleanDictation)
    }

    func testCleanDictationInstructionIsSentToGPTTranscribe() {
        let context = TranscriptionContext(
            prompt: "Technical dictation.",
            keywords: ["WhisperKit"],
            languages: ["en"],
            delay: .medium,
            outputStyle: .cleanDictation
        )
        let request = RealtimeRefinementRequest(
            transcriptID: "clean-dictation",
            speaker: .you,
            pcm16Audio: Data([0, 1]),
            context: context,
            recentTranscript: ""
        )

        XCTAssertTrue(
            RealtimeRefinementClient.transcriptionPrompt(for: request)
                .contains("Omit hesitation fillers")
        )
    }

    func testWhisperUsesOneLanguageHintOrAutomaticMultilingualDetection() {
        XCTAssertEqual(
            WhisperTranscriber.singleLanguageHint(from: ["EN-us", "en"]),
            "en"
        )
        XCTAssertNil(
            WhisperTranscriber.singleLanguageHint(from: ["en", "ja"])
        )
        XCTAssertNil(WhisperTranscriber.singleLanguageHint(from: []))
        XCTAssertEqual(
            WhisperTranscriber.modelVariant,
            "large-v3-v20240930_626MB"
        )
    }

    func testQuickDictationHistoryPersistsNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = folder.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let older = QuickDictationHistoryEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "First dictation"
        )
        let newer = QuickDictationHistoryEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 2_000),
            text: "A later dictation with 日本語 and\na second line"
        )
        let store = QuickDictationHistoryStore(fileURL: historyURL)

        XCTAssertEqual(try store.load(), [])
        try store.save([older, newer])

        XCTAssertEqual(try store.load(), [newer, older])
    }

    func testQuickDictationHistoryCanPersistDeletionAndEraseAll() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = folder.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = QuickDictationHistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_000),
            text: "Keep me"
        )
        let second = QuickDictationHistoryEntry(
            createdAt: Date(timeIntervalSince1970: 2_000),
            text: "Delete me"
        )
        let store = QuickDictationHistoryStore(fileURL: historyURL)

        try store.save([second, first])
        try store.save([first])
        XCTAssertEqual(try store.load(), [first])

        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }

    func testQuickDictationRecoveryWaveFileRoundTripsPCM16Audio() throws {
        let audio = Data((0..<4_800).map { UInt8($0 % 251) })

        let waveData = try PCM16WaveFile.encode(audio)

        XCTAssertEqual(String(data: waveData[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: waveData[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(try PCM16WaveFile.decode(waveData), audio)
    }

    func testQuickDictationRecoverySurvivesStoreRecreationUntilRemoved() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = Data(repeating: 7, count: PCM16WaveFile.bytesPerSecond * 2)
        let createdAt = Date(timeIntervalSince1970: 10_000)
        let firstStore = QuickDictationRecoveryStore(directoryURL: folder)

        let retained = try firstStore.preserve(
            pcm16Audio: audio,
            languages: ["en", "ja"],
            createdAt: createdAt
        )
        let failed = try firstStore.recordFailure(
            for: retained,
            message: "Provider unavailable"
        )

        let relaunchedStore = QuickDictationRecoveryStore(directoryURL: folder)
        XCTAssertEqual(try relaunchedStore.load(), [failed])
        XCTAssertEqual(try relaunchedStore.pcm16Audio(for: failed), audio)
        XCTAssertEqual(failed.audioDurationSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(failed.attemptCount, 1)
        XCTAssertEqual(failed.lastError, "Provider unavailable")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: relaunchedStore.audioURL(for: failed).path
            )
        )

        try relaunchedStore.remove(failed)
        XCTAssertEqual(try relaunchedStore.load(), [])
    }

    func testQuickDictationRecoveryPreservesTheFailedLongRecordingSize() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = QuickDictationRecoveryStore(directoryURL: folder)
        let audio = Data(repeating: 19, count: 3_959_040)

        let retained = try store.preserve(
            pcm16Audio: audio,
            languages: ["en"]
        )

        XCTAssertEqual(retained.audioDurationSeconds, 82.48, accuracy: 0.001)
        XCTAssertEqual(try store.pcm16Audio(for: retained), audio)
    }

    func testQuickDictationRecoveryUsesPackageIdentityWhenMetadataIsDamaged() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = QuickDictationRecoveryStore(directoryURL: folder)
        let audio = Data(repeating: 11, count: PCM16WaveFile.bytesPerSecond)
        let retained = try store.preserve(
            pcm16Audio: audio,
            languages: ["en"]
        )
        let mismatchedMetadata = QuickDictationRecoveryEntry(
            audioByteCount: audio.count,
            languages: ["en"]
        )
        let metadataURL = store.audioURL(for: retained)
            .deletingLastPathComponent()
            .appendingPathComponent("metadata.json")
        try JSONEncoder().encode(mismatchedMetadata).write(
            to: metadataURL,
            options: .atomic
        )

        let recovered = try XCTUnwrap(store.load().first)

        XCTAssertEqual(recovered.id, retained.id)
        XCTAssertEqual(recovered.audioByteCount, audio.count)
        XCTAssertEqual(try store.pcm16Audio(for: recovered), audio)
        XCTAssertEqual(
            recovered.lastError,
            "Recovery metadata was damaged, but the recording was retained."
        )
    }

    func testLiveDictationPreviewWaitsForEnoughNewAudio() {
        let minimum = QuickDictationLivePreviewPolicy.minimumAudioBytes
        let increment = QuickDictationLivePreviewPolicy.minimumAdditionalAudioBytes

        XCTAssertFalse(
            QuickDictationLivePreviewPolicy.shouldTranscribe(
                audioByteCount: minimum - 1,
                lastTranscribedByteCount: 0
            )
        )
        XCTAssertTrue(
            QuickDictationLivePreviewPolicy.shouldTranscribe(
                audioByteCount: minimum,
                lastTranscribedByteCount: 0
            )
        )
        XCTAssertFalse(
            QuickDictationLivePreviewPolicy.shouldTranscribe(
                audioByteCount: minimum + increment - 1,
                lastTranscribedByteCount: minimum
            )
        )
        XCTAssertTrue(
            QuickDictationLivePreviewPolicy.shouldTranscribe(
                audioByteCount: minimum + increment,
                lastTranscribedByteCount: minimum
            )
        )

        let longRecording = Data(
            repeating: 1,
            count: QuickDictationLivePreviewPolicy.maximumAudioBytes + 9_600
        )
        XCTAssertEqual(
            QuickDictationLivePreviewPolicy.previewAudio(from: longRecording).count,
            QuickDictationLivePreviewPolicy.maximumAudioBytes
        )
    }

    func testAdaptiveWaveformMakesQuietSpeechVisible() {
        let quietSamples = (0..<180).map { index in
            Float(index.isMultiple(of: 2) ? 0.01 : -0.01)
        }
        let scaled = WaveformDisplayNormalizer.adaptiveSamples(quietSamples)

        XCTAssertEqual(scaled.count, quietSamples.count)
        XCTAssertGreaterThan(
            scaled.map(abs).max() ?? 0,
            quietSamples.map(abs).max() ?? 0
        )
        XCTAssertLessThanOrEqual(scaled.map(abs).max() ?? 0, 1)
    }

    func testAdaptiveWaveformKeepsSilenceFlat() {
        let silence = Array(repeating: Float(0), count: 180)

        XCTAssertEqual(
            WaveformDisplayNormalizer.adaptiveSamples(silence),
            silence
        )
    }

    func testParakeetWarmupHintReportsProgressAndElapsedTime() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let checking = ParakeetPreparationState(
            stage: .checkingCache,
            startedAt: startedAt
        )
        XCTAssertEqual(
            checking.hint(at: startedAt.addingTimeInterval(7)),
            "Background Parakeet warmup · checking cache · 7s"
        )
        XCTAssertTrue(checking.isInProgress)

        let downloading = ParakeetPreparationState(
            stage: .downloading(fractionCompleted: 0.375),
            startedAt: startedAt
        )
        XCTAssertEqual(downloading.downloadFraction, 0.375)
        XCTAssertEqual(
            downloading.hint(at: startedAt.addingTimeInterval(65)),
            "Background Parakeet warmup · downloading 38% · 1m 5s"
        )

        let ready = ParakeetPreparationState(
            stage: .ready,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(9)
        )
        XCTAssertEqual(
            ready.hint(at: startedAt.addingTimeInterval(30)),
            "Local Parakeet ready · initialized in 9s"
        )
        XCTAssertTrue(ready.isReady)
        XCTAssertFalse(ready.isInProgress)
    }

    func testWhisperWarmupHintReportsProgressAndElapsedTime() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let downloading = WhisperPreparationState(
            stage: .downloading(fractionCompleted: 0.625),
            startedAt: startedAt
        )
        XCTAssertEqual(downloading.downloadFraction, 0.625)
        XCTAssertEqual(
            downloading.hint(at: startedAt.addingTimeInterval(65)),
            "Background Whisper warmup · downloading 63% · 1m 5s"
        )

        let ready = WhisperPreparationState(
            stage: .ready,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(11)
        )
        XCTAssertEqual(
            ready.hint(at: startedAt.addingTimeInterval(30)),
            "Local Whisper ready · initialized in 11s"
        )
        XCTAssertTrue(ready.isReady)
    }

    func testParakeetEncoderAvoidsCrashProneMetalBackend() {
        XCTAssertEqual(
            ParakeetTranscriber.encoderComputeUnits,
            .cpuOnly
        )
    }

    func testLoadingDictationStateNamesTheSelectedModel() {
        let whisper = DictationPhase.preparing(.localWhisper)
        XCTAssertEqual(whisper.label, "Loading Whisper…")
        XCTAssertEqual(
            whisper.detail,
            "Whisper is still loading. Release the shortcut and wait for Ready before dictating."
        )

        let local = DictationPhase.preparing(.localParakeet)
        XCTAssertEqual(local.label, "Loading Parakeet…")
        XCTAssertEqual(
            local.detail,
            "Parakeet is still loading. Release the shortcut and wait for Ready before dictating."
        )

        let cloud = DictationPhase.preparing(.openAITranscribe)
        XCTAssertEqual(cloud.label, "Connecting to GPT-Transcribe…")
        XCTAssertEqual(
            cloud.detail,
            "GPT-Transcribe is still connecting. Release the shortcut and wait for Ready before dictating."
        )
    }

    func testDictationNamesMicrophoneStartupAndRecoveryHonestly() {
        XCTAssertEqual(
            DictationPhase.startingMicrophone.label,
            "Starting microphone…"
        )
        XCTAssertEqual(
            DictationPhase.startingMicrophone.detail,
            "Waiting for the selected microphone to deliver its first audio buffer."
        )
        XCTAssertEqual(
            DictationPhase.recoveringMicrophone.label,
            "Recovering microphone…"
        )
        XCTAssertTrue(
            DictationPhase.recoveringMicrophone.detail?.contains(
                "stopped delivering audio"
            ) == true
        )
    }

    func testQuickDictationReconnectsAfterCloudSessionRollover() {
        var policy = QuickDictationReconnectPolicy()

        XCTAssertEqual(
            policy.reconnectDelay(after: .idle, engine: .openAITranscribe),
            0
        )
        XCTAssertNil(
            policy.reconnectDelay(after: .idle, engine: .localParakeet)
        )
        XCTAssertNil(
            policy.reconnectDelay(after: .idle, engine: .localWhisper)
        )
    }

    func testQuickDictationReconnectUsesCappedFailureBackoff() {
        var policy = QuickDictationReconnectPolicy()
        let failure = SocketState.failed("Network unavailable")

        XCTAssertEqual(
            (0..<7).compactMap {
                _ in policy.reconnectDelay(
                    after: failure,
                    engine: .openAITranscribe
                )
            },
            [1, 2, 5, 15, 30, 30, 30]
        )

        XCTAssertNil(
            policy.reconnectDelay(after: .connected, engine: .openAITranscribe)
        )
        XCTAssertEqual(
            policy.reconnectDelay(after: failure, engine: .openAITranscribe),
            1
        )
    }

    func testQuickDictationCanRecordWhileEarlierTranscriptionIsPending() {
        var state = QuickDictationWorkState<String>()
        state.submit(transcriptID: "first", target: "first window")

        XCTAssertEqual(
            state.phase(
                isRunning: true,
                isRecording: false,
                isModelReady: true,
                engine: .localParakeet
            ),
            .transcribing
        )
        XCTAssertEqual(
            state.phase(
                isRunning: true,
                isRecording: true,
                isModelReady: false,
                engine: .localParakeet
            ),
            .recording
        )

        state.submit(transcriptID: "second", target: "second window")
        XCTAssertEqual(
            state.complete(transcriptID: "first"),
            "first window"
        )
        XCTAssertEqual(
            state.phase(
                isRunning: true,
                isRecording: false,
                isModelReady: true,
                engine: .localParakeet
            ),
            .transcribing
        )
        XCTAssertEqual(
            state.complete(transcriptID: "second"),
            "second window"
        )
        XCTAssertEqual(
            state.phase(
                isRunning: true,
                isRecording: false,
                isModelReady: true,
                engine: .localParakeet
            ),
            .ready
        )
    }

    func testQuickDictationWorkStateIgnoresUnknownCompletion() {
        var state = QuickDictationWorkState<String>()
        state.submit(transcriptID: "active", target: "original field")

        XCTAssertNil(state.complete(transcriptID: "stale-preview"))
        XCTAssertEqual(state.pendingTranscriptionIDs, ["active"])
    }

    func testQuickDictationKeepsEachRecordingTargetUntilItsResultArrives() {
        var state = QuickDictationWorkState<String>()
        state.submit(transcriptID: "first", target: "mail compose field")
        state.submit(transcriptID: "second", target: "notes window")

        XCTAssertEqual(
            state.complete(transcriptID: "second"),
            "notes window"
        )
        XCTAssertEqual(
            state.complete(transcriptID: "first"),
            "mail compose field"
        )
        XCTAssertFalse(state.hasPendingTranscriptions)
    }

    func testGPTTranscribeConnectionAttemptHasABoundedTimeout() {
        XCTAssertEqual(
            RealtimeRefinementClient.connectionTimeoutSeconds,
            30
        )
    }

    func testCloudWatchdogStartsOnlyAfterCommitAndAllowsProviderTime() {
        XCTAssertEqual(
            QuickDictationFallbackPolicy.responseWatchdogSeconds,
            30
        )
    }

    func testReadyLocalFallbackKeepsCloudDictationAvailable() {
        XCTAssertTrue(
            QuickDictationTranscriberAvailability.isReady(
                primaryReady: false,
                engine: .openAITranscribe,
                fallbackState: .connected
            )
        )
        XCTAssertFalse(
            QuickDictationTranscriberAvailability.isReady(
                primaryReady: false,
                engine: .localWhisper,
                fallbackState: .connected
            )
        )
    }

    func testQuickDictationPreviewTracksCaptureAndTranscription() {
        var state = QuickDictationPreviewState()

        XCTAssertEqual(state.content, .hidden)
        state.handle(phase: .recording)
        XCTAssertEqual(state.content, .listening)
        state.handle(phase: .transcribing)
        XCTAssertEqual(state.content, .transcribing)

        state.show(result: "A useful preview")
        XCTAssertEqual(
            state.content,
            .result(
                QuickDictationResultPresentation(
                    text: "A useful preview",
                    delivery: .delivering
                )
            )
        )
        state.handle(phase: .ready)
        XCTAssertEqual(
            state.content,
            .result(
                QuickDictationResultPresentation(
                    text: "A useful preview",
                    delivery: .delivering
                )
            )
        )
    }

    func testQuickDictationPreviewSeparatesListeningFromBackgroundResult() {
        var state = QuickDictationPreviewState()

        state.handle(phase: .transcribing)
        state.handle(phase: .recording)
        XCTAssertEqual(state.content, .listening)
        XCTAssertEqual(state.backgroundContent, .transcribing)

        state.show(result: "The previous dictation")
        XCTAssertEqual(state.content, .listening)
        XCTAssertEqual(
            state.backgroundContent,
            .result("The previous dictation")
        )

        state.hideBackground()
        XCTAssertEqual(state.content, .listening)
        XCTAssertNil(state.backgroundContent)
    }

    func testQuickDictationPreviewOnlyClaimsListeningAfterAudioStarts() {
        var state = QuickDictationPreviewState()

        state.handle(phase: .startingMicrophone)
        XCTAssertEqual(state.content, .startingMicrophone)

        state.handle(phase: .recording)
        XCTAssertEqual(state.content, .listening)

        state.handle(phase: .recoveringMicrophone)
        XCTAssertEqual(state.content, .recoveringMicrophone)

        state.handle(phase: .recording)
        XCTAssertEqual(state.content, .listening)
    }

    func testQuickDictationPreviewHidesCancelledCapture() {
        var state = QuickDictationPreviewState()

        state.handle(phase: .recording)
        state.handle(phase: .ready)

        XCTAssertEqual(state.content, .hidden)
        XCTAssertFalse(state.isVisible)
    }

    func testQuickDictationPreviewOnlyShowsFailuresForActiveDictation() {
        var state = QuickDictationPreviewState()

        state.handle(phase: .failed("Model unavailable"))
        XCTAssertEqual(state.content, .hidden)

        state.handle(phase: .recording)
        state.handle(phase: .failed("Microphone disconnected"))
        XCTAssertEqual(state.content, .failure("Microphone disconnected"))
    }

    // MARK: - Streamed dictation

    func testStreamAssemblyOrdersSegmentsByCommitNotCompletion() {
        var assembly = DictationStreamAssembly()
        assembly.registerCommitted(itemID: "item_1")
        assembly.registerCommitted(itemID: "item_2")

        // The second segment finishes first; commit order still wins.
        assembly.finalize(itemID: "item_2", text: "the second part")
        XCTAssertFalse(assembly.isComplete(expectedSegments: 2))
        assembly.finalize(itemID: "item_1", text: "This is")

        XCTAssertTrue(assembly.isComplete(expectedSegments: 2))
        XCTAssertEqual(assembly.text, "This is the second part")
    }

    func testStreamAssemblyShowsDeltasUntilASegmentFinalizes() {
        var assembly = DictationStreamAssembly()
        assembly.finalize(itemID: "item_1", text: "Committed text")
        assembly.appendDelta(itemID: "item_2", delta: "in ")
        assembly.appendDelta(itemID: "item_2", delta: "progress")

        XCTAssertEqual(assembly.text, "Committed text in progress")
        XCTAssertFalse(assembly.isComplete(expectedSegments: 2))

        assembly.finalize(itemID: "item_2", text: "in progress now")
        XCTAssertEqual(assembly.text, "Committed text in progress now")
        XCTAssertTrue(assembly.isComplete(expectedSegments: 2))
    }

    func testSegmentCommitPolicyCutsOnPausesAndBoundsSegmentLength() {
        // Too short to commit at all, pause or not.
        XCTAssertFalse(
            DictationSegmentCommitPolicy.shouldCommit(
                segmentSeconds: 0.1,
                trailingIsSilent: true
            )
        )
        // Mid-sentence: wait rather than cut a word in half.
        XCTAssertFalse(
            DictationSegmentCommitPolicy.shouldCommit(
                segmentSeconds: 10,
                trailingIsSilent: false
            )
        )
        // A pause after enough speech is the right place to cut.
        XCTAssertTrue(
            DictationSegmentCommitPolicy.shouldCommit(
                segmentSeconds: 10,
                trailingIsSilent: true
            )
        )
        // An unbroken monologue still gets bounded so the tail stays short.
        XCTAssertTrue(
            DictationSegmentCommitPolicy.shouldCommit(
                segmentSeconds: 25,
                trailingIsSilent: false
            )
        )
    }

    func testUnresolvedDeliveryKeepsResultOnScreen() {
        var state = QuickDictationPreviewState()
        state.handle(phase: .transcribing)
        state.show(result: "Some dictated text")

        XCTAssertFalse(state.content.needsAcknowledgement)

        state.resolve(delivery: .unverified(applicationName: "iTerm2"))
        XCTAssertTrue(state.content.needsAcknowledgement)
        XCTAssertEqual(
            state.content,
            .result(
                QuickDictationResultPresentation(
                    text: "Some dictated text",
                    delivery: .unverified(applicationName: "iTerm2")
                )
            )
        )

        state.resolve(delivery: .pasted)
        XCTAssertFalse(state.content.needsAcknowledgement)
    }

    func testInterruptedDeliveryOffersCopyOrDismissWithoutResolving() {
        var state = QuickDictationPreviewState()
        state.handle(phase: .transcribing)
        state.show(result: "Text captured before Escape")

        state.resolve(delivery: .interrupted)

        XCTAssertTrue(state.content.needsAcknowledgement)
        XCTAssertEqual(
            state.content,
            .result(
                QuickDictationResultPresentation(
                    text: "Text captured before Escape",
                    delivery: .interrupted
                )
            )
        )
        XCTAssertEqual(
            QuickDictationDeliveryOutcome.interrupted.detail,
            "Recording stopped with Escape. Copy the text, or dismiss this message."
        )
    }

    // MARK: - Local-first capability

    func testFreshInstallCanDictateWithoutAnAPIKey() {
        let capability = CloudCapability(hasAPIKey: false)

        // The whole point: dictation must work before anything is configured.
        XCTAssertFalse(
            capability.resolvedEngine(preferring: .localWhisper).isCloud
        )
        XCTAssertFalse(capability.isCloudEnabled)
        // Everything that genuinely cannot run locally is locked, and says so.
        for feature in CloudFeature.allCases {
            XCTAssertEqual(capability.access(to: feature), .needsAPIKey)
            XCTAssertNotNil(capability.lockMessage(for: feature))
            XCTAssertEqual(
                capability.actionTitle(for: feature),
                "Set Up OpenAI…"
            )
        }
    }

    func testAKeyUnlocksEverything() {
        let capability = CloudCapability(hasAPIKey: true)

        XCTAssertTrue(capability.isCloudEnabled)
        for feature in CloudFeature.allCases {
            XCTAssertEqual(capability.access(to: feature), .available)
            XCTAssertNil(capability.lockMessage(for: feature))
        }
        XCTAssertEqual(
            capability.resolvedEngine(preferring: .openAITranscribe),
            .openAITranscribe
        )
    }

    func testPrivacyLockOverridesASavedKey() {
        let capability = CloudCapability(
            hasAPIKey: true,
            privacyLockEnabled: true
        )

        XCTAssertFalse(capability.isCloudEnabled)
        XCTAssertEqual(
            capability.access(to: .meetingCapture),
            .blockedByPrivacyLock
        )
        // A cloud engine chosen earlier must not silently keep sending audio.
        XCTAssertEqual(
            capability.resolvedEngine(preferring: .openAITranscribe),
            .localWhisper
        )
    }

    func testRemovingAKeyDoesNotStrandDictationOnACloudEngine() {
        // The stored preference is still the cloud model from when a key
        // existed; dictation has to keep working anyway.
        let capability = CloudCapability(hasAPIKey: false)

        XCTAssertEqual(
            capability.resolvedEngine(preferring: .openAITranscribe),
            .localWhisper
        )
        // A deliberate local choice is never overridden.
        XCTAssertEqual(
            capability.resolvedEngine(preferring: .localParakeet),
            .localParakeet
        )
    }

    func testOnlyDictationAccuracyIsAnOptionalUpgrade() {
        XCTAssertTrue(CloudFeature.bestAccuracyDictation.isOptionalUpgrade)
        XCTAssertFalse(CloudFeature.meetingCapture.isOptionalUpgrade)
        XCTAssertFalse(CloudFeature.answerMirror.isOptionalUpgrade)
        XCTAssertFalse(CloudFeature.mockInterview.isOptionalUpgrade)
    }

    // MARK: - Settings migration

    private func scratchDefaults() throws -> UserDefaults {
        let name = "PUnderclassTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testLegacyLocalOnlyModeBecomesThePrivacyLock() throws {
        let defaults = try scratchDefaults()
        defaults.set(true, forKey: MeetingController.legacyLocalOnlyModeDefaultsKey)

        MeetingController.migrateLegacyLocalOnlyMode(defaults: defaults)

        XCTAssertTrue(
            defaults.bool(forKey: MeetingController.privacyLockDefaultsKey)
        )
        // The old key must not linger; a stale flag is worse than none.
        XCTAssertNil(
            defaults.object(
                forKey: MeetingController.legacyLocalOnlyModeDefaultsKey
            )
        )
    }

    func testLegacyLocalOnlyModeNeverOverridesANewerChoice() throws {
        let defaults = try scratchDefaults()
        defaults.set(true, forKey: MeetingController.legacyLocalOnlyModeDefaultsKey)
        // Choosing a cloud engine is only possible under the new model, so it
        // is proof of a more recent decision than the old flag.
        defaults.set(
            TranscriptRefinementEngine.openAITranscribe.rawValue,
            forKey: MeetingController.refinementEngineDefaultsKey
        )

        MeetingController.migrateLegacyLocalOnlyMode(defaults: defaults)

        XCTAssertFalse(
            defaults.bool(forKey: MeetingController.privacyLockDefaultsKey)
        )
        XCTAssertNil(
            defaults.object(
                forKey: MeetingController.legacyLocalOnlyModeDefaultsKey
            )
        )
    }

    func testMigrationIsANoOpWithoutTheLegacyKey() throws {
        let defaults = try scratchDefaults()

        MeetingController.migrateLegacyLocalOnlyMode(defaults: defaults)

        XCTAssertNil(
            defaults.object(forKey: MeetingController.privacyLockDefaultsKey)
        )
    }

    func testAPIExpensesSurviveARelaunch() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("APIExpenses.json")
        defer {
            try? FileManager.default.removeItem(
                at: fileURL.deletingLastPathComponent()
            )
        }
        let store = APIExpenseStore(fileURL: fileURL)

        // Nothing recorded yet: a fresh counter, not an error.
        XCTAssertEqual(try store.load().totalCostUSD, 0)

        var summary = APIExpenseSummary(
            startedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        summary.record(
            OpenAITranscriptionUsageRecord(
                pass: .final,
                model: "gpt-transcribe",
                audioSeconds: 120,
                measurement: .serverReported
            )
        )
        try store.save(summary)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.finalAudioSeconds, 120)
        XCTAssertEqual(reloaded.totalCostUSD, summary.totalCostUSD)
        // The start date is what makes the running total interpretable.
        XCTAssertEqual(
            reloaded.startedAt.timeIntervalSince1970,
            1_000_000,
            accuracy: 0.001
        )
    }

    func testExpenseAccumulationDescriptionNamesThePeriod() {
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let summary = APIExpenseSummary(startedAt: started)

        XCTAssertTrue(
            summary.accumulationDescription(now: started).hasSuffix("(today)")
        )
        XCTAssertTrue(
            summary.accumulationDescription(
                now: started.addingTimeInterval(86_400)
            ).hasSuffix("(1 day)")
        )
        XCTAssertTrue(
            summary.accumulationDescription(
                now: started.addingTimeInterval(86_400 * 9)
            ).hasSuffix("(9 days)")
        )
    }

    func testLocalOnlyModeIdentifiesCloudEngines() {
        XCTAssertTrue(TranscriptRefinementEngine.openAITranscribe.isCloud)
        XCTAssertFalse(TranscriptRefinementEngine.localWhisper.isCloud)
        XCTAssertFalse(TranscriptRefinementEngine.localParakeet.isCloud)
    }

    func testTerminalPasteEvidenceRecognizesVisibleText() {
        let screen = "user@host ~/dev % ls -la\ntotal 8\nuser@host ~/dev % "
        let evidence = QuickDictationContentEvidence(
            originalValue: screen,
            insertedText: "Please refactor the transcription client."
        )

        // Terminals wrap mid-token, so the echoed text is checked without
        // whitespace.
        XCTAssertEqual(
            evidence.evaluate(
                currentValue: screen + "Please refactor the transcr\niption client."
            ),
            .inserted
        )
    }

    func testTerminalPasteEvidenceAcceptsAPlaceholderRedraw() {
        let screen = "╭─ Claude Code ─╮\n│ > │\n╰───────────────╯"
        let evidence = QuickDictationContentEvidence(
            originalValue: screen,
            insertedText: String(repeating: "long dictated text. ", count: 40)
        )

        // A TUI that renders a placeholder never shows the literal text, but
        // the screen still changed, which is proof enough that it arrived.
        XCTAssertEqual(
            evidence.evaluate(
                currentValue: "╭─ Claude Code ─╮\n│ > [Pasted text #1 +12 lines] │\n╰───────────────╯"
            ),
            .changed
        )
    }

    func testTerminalPasteEvidenceReportsAnUntouchedScreen() {
        let screen = "user@host ~/dev % "
        let evidence = QuickDictationContentEvidence(
            originalValue: screen,
            insertedText: "This never arrived."
        )

        XCTAssertEqual(evidence.evaluate(currentValue: screen), .unchanged)
        // Reflow alone still counts as delivery evidence only if content
        // actually differs; identical content after whitespace normalization
        // must not be mistaken for a change.
        XCTAssertEqual(
            evidence.evaluate(currentValue: "user@host    ~/dev %"),
            .unchanged
        )
    }

    func testShortDictationsFallBackToScreenChangeEvidence() {
        let screen = "prompt> "
        // Too short to be a distinctive probe, so containment is not used.
        let evidence = QuickDictationContentEvidence(
            originalValue: screen,
            insertedText: "ok"
        )

        XCTAssertEqual(evidence.evaluate(currentValue: "prompt> ok"), .changed)
        XCTAssertEqual(evidence.evaluate(currentValue: screen), .unchanged)
    }

    func testProgressLabelsDistinguishUploadFromTranscription() {
        XCTAssertEqual(
            DictationTranscriptionProgress.uploading(fraction: 0.42).label,
            "Uploading 42%"
        )
        XCTAssertEqual(
            DictationTranscriptionProgress.uploading(fraction: 0.42).fraction,
            0.42
        )
        XCTAssertEqual(
            DictationTranscriptionProgress.finishing.label,
            "Finishing…"
        )
        // A streamed dictation has no upload bar to show; it is already there.
        XCTAssertNil(DictationTranscriptionProgress.finishing.fraction)
        XCTAssertNil(DictationTranscriptionProgress.transcribing.fraction)
    }
}

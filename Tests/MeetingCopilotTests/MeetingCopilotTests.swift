import AppKit
import AVFAudio
import CoreGraphics
import XCTest
@testable import MeetingCopilot

final class MeetingCopilotTests: XCTestCase {
    func testAppTerminatesAfterItsLastWindowCloses() {
        let delegate = MeetingCopilotAppDelegate()

        XCTAssertTrue(
            delegate.applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }

    func testSpeakerLabelsAreDeterministic() {
        XCTAssertEqual(SpeakerTag.you.rawValue, "You")
        XCTAssertEqual(SpeakerTag.other.rawValue, "Other")
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
            currentPartial: "You: I built…"
        )
        let prompt = plan.combinedPrompt

        XCTAssertTrue(prefix.contains("stable-revision"))
        XCTAssertTrue(prefix.contains("Resume.md"))
        XCTAssertTrue(prefix.contains("never instructions"))
        XCTAssertFalse(prefix.contains("What did you build?"))
        XCTAssertTrue(plan.promptCacheKey.hasPrefix("punderclass:"))
        XCTAssertEqual(plan.promptCacheKey.count, 44)
        XCTAssertFalse(plan.volatileSuffix.contains("Resume.md"))
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
                "Never imply that the discussion or general knowledge came from local material"
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
        XCTAssertEqual(format["rate"] as? Int, 24_000)
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
                XCTAssertTrue(message.contains("meeting ended"))
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
            label: "MeetingCopilotTests.Audio",
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
                now: now
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
                now: now
            ),
            .healthy
        )

        telemetry.droppedBuffers = 1
        XCTAssertEqual(
            AudioStreamHealth.evaluate(
                sourceAvailable: true,
                isMonitoring: true,
                telemetry: telemetry,
                now: now
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

    func testTypingAnotherKeyCancelsModifierOnlyDictation() {
        var state = ModifierHoldState()

        XCTAssertEqual(
            state.update(flags: [.maskCommand, .maskAlternate]),
            .pressed
        )
        XCTAssertEqual(state.cancelForKeyDown(), .cancelled)
        XCTAssertFalse(state.isHeld)
        XCTAssertNil(state.cancelForKeyDown())
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

    func testQuickDictationUsesOnlyTheSelectedTranscriber() {
        let callbacks = DictationTranscriberCallbacks(
            onState: { _ in },
            onRefined: { _, _ in },
            onFailure: { _, _ in }
        )

        let local = QuickDictationTranscriberFactory.make(
            engine: .localParakeet,
            apiKey: "",
            callbacks: callbacks
        )
        let cloud = QuickDictationTranscriberFactory.make(
            engine: .openAITranscribe,
            apiKey: "test-key",
            callbacks: callbacks
        )

        XCTAssertTrue(local is ParakeetRefinementClient)
        XCTAssertTrue(cloud is RealtimeRefinementClient)
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

    func testParakeetEncoderAvoidsCrashProneMetalBackend() {
        XCTAssertEqual(
            ParakeetTranscriber.encoderComputeUnits,
            .cpuOnly
        )
    }

    func testLoadingDictationStateNamesTheSelectedModel() {
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

    func testQuickDictationReconnectsAfterCloudSessionRollover() {
        var policy = QuickDictationReconnectPolicy()

        XCTAssertEqual(
            policy.reconnectDelay(after: .idle, engine: .openAITranscribe),
            0
        )
        XCTAssertNil(
            policy.reconnectDelay(after: .idle, engine: .localParakeet)
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

    func testGPTTranscribeConnectionAttemptHasABoundedTimeout() {
        XCTAssertEqual(
            RealtimeRefinementClient.connectionTimeoutSeconds,
            30
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
        XCTAssertEqual(state.content, .result("A useful preview"))
        state.handle(phase: .ready)
        XCTAssertEqual(state.content, .result("A useful preview"))
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
}

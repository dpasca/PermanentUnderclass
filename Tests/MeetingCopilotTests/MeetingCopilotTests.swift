import AVFAudio
import CoreGraphics
import XCTest
@testable import MeetingCopilot

final class MeetingCopilotTests: XCTestCase {
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
}

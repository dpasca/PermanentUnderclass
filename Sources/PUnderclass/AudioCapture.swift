import AVFAudio
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

struct AudioCaptureLivenessPolicy {
    static let bufferTimeout: TimeInterval = 2
    static let checkInterval: TimeInterval = 0.25

    static func hasStalled(
        startedAtUptime: UInt64,
        lastBufferAtUptime: UInt64?,
        nowUptime: UInt64,
        timeout: TimeInterval = bufferTimeout
    ) -> Bool {
        let referenceUptime = lastBufferAtUptime ?? startedAtUptime
        guard nowUptime >= referenceUptime else { return false }
        let elapsedNanoseconds = nowUptime - referenceUptime
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        return elapsedNanoseconds >= timeoutNanoseconds
    }
}

struct AudioCaptureRecoveryPolicy {
    static let quickDictationRestartLimit = 2

    static func meetingRestartDelay(after attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1:
            0.28
        case 2:
            1
        case 3:
            3
        default:
            10
        }
    }
}

/// Watches buffer delivery rather than signal amplitude. A silent room still
/// produces buffers, while a wedged Bluetooth route does not.
final class AudioBufferWatchdog {
    typealias StallHandler = () -> Void

    private let timeout: TimeInterval
    private let checkInterval: TimeInterval
    private let callbackQueue: DispatchQueue
    private let onStall: StallHandler
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var startedAtUptime: UInt64 = 0
    private var lastBufferAtUptime: UInt64?
    private var hasReportedCurrentStall = false
    private var isRunning = false

    init(
        timeout: TimeInterval = AudioCaptureLivenessPolicy.bufferTimeout,
        checkInterval: TimeInterval = AudioCaptureLivenessPolicy.checkInterval,
        callbackQueue: DispatchQueue = .main,
        onStall: @escaping StallHandler
    ) {
        self.timeout = timeout
        self.checkInterval = checkInterval
        self.callbackQueue = callbackQueue
        self.onStall = onStall
    }

    func start() {
        stop()

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        timer.schedule(
            deadline: .now() + checkInterval,
            repeating: checkInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.checkForStall()
        }

        lock.lock()
        startedAtUptime = DispatchTime.now().uptimeNanoseconds
        lastBufferAtUptime = nil
        hasReportedCurrentStall = false
        isRunning = true
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func noteBuffer() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        lastBufferAtUptime = DispatchTime.now().uptimeNanoseconds
        hasReportedCurrentStall = false
        lock.unlock()
    }

    func stop() {
        lock.lock()
        isRunning = false
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func checkForStall() {
        lock.lock()
        guard
            isRunning,
            !hasReportedCurrentStall,
            AudioCaptureLivenessPolicy.hasStalled(
                startedAtUptime: startedAtUptime,
                lastBufferAtUptime: lastBufferAtUptime,
                nowUptime: DispatchTime.now().uptimeNanoseconds,
                timeout: timeout
            )
        else {
            lock.unlock()
            return
        }
        hasReportedCurrentStall = true
        lock.unlock()

        callbackQueue.async { [weak self] in
            self?.deliverStallIfCurrent()
        }
    }

    private func deliverStallIfCurrent() {
        lock.lock()
        let shouldDeliver = isRunning && hasReportedCurrentStall
        lock.unlock()
        guard shouldDeliver else { return }
        onStall()
    }

    deinit {
        stop()
    }
}

final class MicrophoneCapture {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void
    typealias FirstBufferHandler = () -> Void
    typealias ConfigurationChangeHandler = () -> Void
    typealias StallHandler = () -> Void

    private let engine = AVAudioEngine()
    private let bufferStateLock = NSLock()
    private var isStarted = false
    private var isCancelled = false
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: AudioBufferWatchdog?
    private var receivedBuffer = false

    var hasReceivedBuffer: Bool {
        bufferStateLock.lock()
        defer { bufferStateLock.unlock() }
        return receivedBuffer
    }

    func start(
        onBuffer: @escaping BufferHandler,
        onFirstBuffer: @escaping FirstBufferHandler,
        onConfigurationChange: @escaping ConfigurationChangeHandler,
        onStall: @escaping StallHandler,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        isCancelled = false
        resetBufferState()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine(
                onBuffer: onBuffer,
                onFirstBuffer: onFirstBuffer,
                onConfigurationChange: onConfigurationChange,
                onStall: onStall,
                completion: completion
            )
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, !self.isCancelled else { return }
                    guard granted else {
                        completion(.failure(PUnderclassError.audio(
                            "Microphone permission was denied."
                        )))
                        return
                    }
                    self.startEngine(
                        onBuffer: onBuffer,
                        onFirstBuffer: onFirstBuffer,
                        onConfigurationChange: onConfigurationChange,
                        onStall: onStall,
                        completion: completion
                    )
                }
            }
        default:
            completion(.failure(PUnderclassError.audio(
                "Microphone access is disabled. Enable it in System Settings → Privacy & Security → Microphone."
            )))
        }
    }

    func stop() {
        isCancelled = true
        watchdog?.stop()
        watchdog = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard isStarted else { return }
        isStarted = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    private func startEngine(
        onBuffer: @escaping BufferHandler,
        onFirstBuffer: @escaping FirstBufferHandler,
        onConfigurationChange: @escaping ConfigurationChangeHandler,
        onStall: @escaping StallHandler,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !isCancelled else { return }
        guard !isStarted else {
            completion(.success(()))
            return
        }

        do {
            let inputNode = engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                throw PUnderclassError.audio("The selected default microphone has no usable input format.")
            }

            let watchdog = AudioBufferWatchdog(onStall: onStall)
            self.watchdog = watchdog
            inputNode.installTap(
                onBus: 0,
                bufferSize: 960,
                format: inputFormat
            ) { [weak self, weak watchdog] buffer, _ in
                guard let self else { return }
                watchdog?.noteBuffer()
                if self.recordBufferArrival() {
                    onFirstBuffer()
                }
                guard let copy = buffer.ownedCopy() else { return }
                onBuffer(copy)
            }
            watchdog.start()
            engine.prepare()
            try engine.start()
            isStarted = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isStarted, !self.isCancelled else { return }
                onConfigurationChange()
            }
            completion(.success(()))
        } catch {
            watchdog?.stop()
            watchdog = nil
            inputNodeIfAvailable()?.removeTap(onBus: 0)
            engine.stop()
            completion(.failure(error))
        }
    }

    private func inputNodeIfAvailable() -> AVAudioInputNode? {
        engine.inputNode
    }

    private func resetBufferState() {
        bufferStateLock.lock()
        receivedBuffer = false
        bufferStateLock.unlock()
    }

    private func recordBufferArrival() -> Bool {
        bufferStateLock.lock()
        defer { bufferStateLock.unlock() }
        guard !receivedBuffer else { return false }
        receivedBuffer = true
        return true
    }

    deinit {
        stop()
    }
}

/// Input-only capture for short dictation clips. Unlike AVAudioEngine, an
/// AVCaptureSession does not build an output graph, which avoids repeatedly
/// renegotiating the Bose QC45 Bluetooth output profile when its microphone is
/// activated.
final class CaptureSessionMicrophoneCapture: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void
    typealias FirstBufferHandler = () -> Void
    typealias StallHandler = () -> Void

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "PUnderclass.Dictation.CaptureSession",
        qos: .userInitiated
    )
    private let outputQueue = DispatchQueue(
        label: "PUnderclass.Dictation.AudioOutput",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var isCancelled = false
    private var audioOutput: AVCaptureAudioDataOutput?
    private var onBuffer: BufferHandler?
    private var onFirstBuffer: FirstBufferHandler?
    private var onStall: StallHandler?
    private var watchdog: AudioBufferWatchdog?
    private var receivedBuffer = false

    var hasReceivedBuffer: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return receivedBuffer
    }

    func start(
        onBuffer: @escaping BufferHandler,
        onFirstBuffer: @escaping FirstBufferHandler,
        onStall: @escaping StallHandler,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        stateLock.lock()
        isCancelled = false
        self.onBuffer = onBuffer
        self.onFirstBuffer = onFirstBuffer
        self.onStall = onStall
        receivedBuffer = false
        stateLock.unlock()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureAndStart(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart(completion: completion)
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(PUnderclassError.audio(
                            "Microphone permission was denied."
                        )))
                    }
                }
            }
        default:
            completion(.failure(PUnderclassError.audio(
                "Microphone access is disabled. Enable it in System Settings → Privacy & Security → Microphone."
            )))
        }
    }

    func stop() {
        stateLock.lock()
        isCancelled = true
        let watchdog = self.watchdog
        self.watchdog = nil
        stateLock.unlock()
        watchdog?.stop()

        sessionQueue.sync {
            audioOutput?.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning {
                session.stopRunning()
            }
            audioOutput = nil
        }
        outputQueue.sync {}
        stateLock.lock()
        onBuffer = nil
        onFirstBuffer = nil
        onStall = nil
        stateLock.unlock()
    }

    private func configureAndStart(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            do {
                guard let device = AVCaptureDevice.default(for: .audio) else {
                    throw PUnderclassError.audio("No default microphone is available.")
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.outputQueue)

                self.session.beginConfiguration()
                do {
                    guard self.session.canAddInput(input) else {
                        throw PUnderclassError.audio("Could not attach the default microphone.")
                    }
                    self.session.addInput(input)
                    guard self.session.canAddOutput(output) else {
                        throw PUnderclassError.audio("Could not create microphone audio output.")
                    }
                    self.session.addOutput(output)
                    self.audioOutput = output
                    self.session.commitConfiguration()
                } catch {
                    self.session.commitConfiguration()
                    throw error
                }

                guard !self.cancelled else { return }
                let watchdog = AudioBufferWatchdog { [weak self] in
                    self?.notifyStall()
                }
                self.stateLock.lock()
                self.watchdog = watchdog
                self.stateLock.unlock()
                watchdog.start()
                self.session.startRunning()
                guard self.session.isRunning else {
                    throw PUnderclassError.audio("The microphone capture session did not start.")
                }
                DispatchQueue.main.async {
                    completion(.success(device.localizedName))
                }
            } catch {
                self.stopWatchdog()
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private var cancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCancelled
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard
            !cancelled,
            CMSampleBufferDataIsReady(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard
            frameCount > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        else {
            return
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        stateLock.lock()
        watchdog?.noteBuffer()
        let isFirstBuffer = !receivedBuffer
        receivedBuffer = true
        let firstBufferHandler = onFirstBuffer
        let handler = onBuffer
        stateLock.unlock()
        if isFirstBuffer {
            firstBufferHandler?()
        }
        handler?(buffer)
    }

    private func notifyStall() {
        stateLock.lock()
        let handler = isCancelled ? nil : onStall
        stateLock.unlock()
        handler?()
    }

    private func stopWatchdog() {
        stateLock.lock()
        let watchdog = self.watchdog
        self.watchdog = nil
        stateLock.unlock()
        watchdog?.stop()
    }

    deinit {
        stop()
    }
}

@available(macOS 14.2, *)
final class ProcessTapCapture {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    private let queue = DispatchQueue(
        label: "PUnderclass.ProcessTap",
        qos: .userInteractive
    )
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var started = false

    /// A nil process captures the global system mix; an ID narrows the tap to
    /// that process.
    func start(processObjectID: AudioObjectID?, onBuffer: @escaping BufferHandler) throws {
        guard !started else { return }

        let tapDescription: CATapDescription
        if let processObjectID {
            tapDescription = CATapDescription(
                monoMixdownOfProcesses: [processObjectID]
            )
            tapDescription.name = "PermanentUnderclass call audio"
        } else {
            tapDescription = CATapDescription(
                monoGlobalTapButExcludeProcesses: []
            )
            tapDescription.name = "PermanentUnderclass system audio"
        }
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        do {
            try CoreAudioUtilities.check(
                AudioHardwareCreateProcessTap(tapDescription, &tapID),
                operation: "Create process audio tap"
            )

            let tapUID = try CoreAudioUtilities.string(
                objectID: tapID,
                selector: kAudioTapPropertyUID
            )
            var basicDescription = try CoreAudioUtilities.streamFormat(
                objectID: tapID,
                selector: kAudioTapPropertyFormat
            )
            guard let audioFormat = AVAudioFormat(streamDescription: &basicDescription) else {
                throw PUnderclassError.audio("Core Audio returned an unsupported process-tap format.")
            }
            format = audioFormat

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "PermanentUnderclass Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try CoreAudioUtilities.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                operation: "Create process-tap aggregate device"
            )

            var createdIOProcID: AudioDeviceIOProcID?
            try CoreAudioUtilities.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &createdIOProcID,
                    aggregateDeviceID,
                    queue
                ) { [weak self] _, inputData, _, _, _ in
                    guard
                        let self,
                        let format = self.format,
                        let copy = Self.copyBufferList(inputData, format: format)
                    else {
                        return
                    }
                    onBuffer(copy)
                },
                operation: "Create process-tap IO callback"
            )
            ioProcID = createdIOProcID

            try CoreAudioUtilities.check(
                AudioDeviceStart(aggregateDeviceID, createdIOProcID),
                operation: "Start process audio capture"
            )
            started = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
        started = false
    }

    private static func copyBufferList(
        _ sourcePointer: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: sourcePointer)
        )
        guard
            let first = source.first,
            first.mData != nil,
            format.streamDescription.pointee.mBytesPerFrame > 0
        else {
            return nil
        }

        let frames = AVAudioFrameCount(
            first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame
        )
        guard
            frames > 0,
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else {
            return nil
        }
        output.frameLength = frames

        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard
                let sourceData = source[index].mData,
                let destinationData = destination[index].mData
            else {
                continue
            }
            let byteCount = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return output
    }

    deinit {
        stop()
    }
}

private extension AVAudioPCMBuffer {
    func ownedCopy() -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ) else {
            return nil
        }
        result.frameLength = frameLength

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard
                let sourceData = source[index].mData,
                let destinationData = destination[index].mData
            else {
                continue
            }
            let byteCount = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }
        return result
    }
}

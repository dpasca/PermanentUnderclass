import AVFAudio
import AVFoundation
import CoreAudio
import Foundation

final class MicrophoneCapture {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void
    typealias ConfigurationChangeHandler = () -> Void

    private let engine = AVAudioEngine()
    private var isStarted = false
    private var isCancelled = false
    private var configurationObserver: NSObjectProtocol?

    func start(
        onBuffer: @escaping BufferHandler,
        onConfigurationChange: @escaping ConfigurationChangeHandler,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        isCancelled = false
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine(
                onBuffer: onBuffer,
                onConfigurationChange: onConfigurationChange,
                completion: completion
            )
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, !self.isCancelled else { return }
                    guard granted else {
                        completion(.failure(MeetingCopilotError.audio(
                            "Microphone permission was denied."
                        )))
                        return
                    }
                    self.startEngine(
                        onBuffer: onBuffer,
                        onConfigurationChange: onConfigurationChange,
                        completion: completion
                    )
                }
            }
        default:
            completion(.failure(MeetingCopilotError.audio(
                "Microphone access is disabled. Enable it in System Settings → Privacy & Security → Microphone."
            )))
        }
    }

    func stop() {
        isCancelled = true
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
        onConfigurationChange: @escaping ConfigurationChangeHandler,
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
                throw MeetingCopilotError.audio("The selected default microphone has no usable input format.")
            }

            inputNode.installTap(
                onBus: 0,
                bufferSize: 960,
                format: inputFormat
            ) { buffer, _ in
                guard let copy = buffer.ownedCopy() else { return }
                onBuffer(copy)
            }
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
            inputNodeIfAvailable()?.removeTap(onBus: 0)
            engine.stop()
            completion(.failure(error))
        }
    }

    private func inputNodeIfAvailable() -> AVAudioInputNode? {
        engine.inputNode
    }

    deinit {
        stop()
    }
}

@available(macOS 14.2, *)
final class ProcessTapCapture {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    private let queue = DispatchQueue(
        label: "MeetingCopilot.ProcessTap",
        qos: .userInteractive
    )
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var started = false

    func start(processObjectID: AudioObjectID, onBuffer: @escaping BufferHandler) throws {
        guard !started else { return }

        let tapDescription = CATapDescription(
            monoMixdownOfProcesses: [processObjectID]
        )
        tapDescription.name = "Meeting Copilot remote participant"
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
                throw MeetingCopilotError.audio("Core Audio returned an unsupported process-tap format.")
            }
            format = audioFormat

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meeting Copilot Capture",
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

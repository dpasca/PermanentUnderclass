import AVFAudio
import Foundation

final class AudioTrackPipeline {
    typealias ChunkHandler = (Data) -> Void
    typealias TelemetryHandler = (TrackTelemetry) -> Void

    private let processingQueue: DispatchQueue
    private let pendingLock = NSLock()
    private let maxPendingBuffers = 12
    private var pendingBuffers = 0
    private var converter: PCM16Converter?
    private var chunker = PCMChunker(chunkSize: 960)
    private var telemetry = TrackTelemetry()
    private var lastTelemetryUpdate = DispatchTime.now()
    private let onChunk: ChunkHandler
    private let onTelemetry: TelemetryHandler

    init(
        label: String,
        onChunk: @escaping ChunkHandler,
        onTelemetry: @escaping TelemetryHandler
    ) {
        processingQueue = DispatchQueue(label: label, qos: .userInitiated)
        self.onChunk = onChunk
        self.onTelemetry = onTelemetry
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        pendingLock.lock()
        guard pendingBuffers < maxPendingBuffers else {
            pendingLock.unlock()
            processingQueue.async { [weak self] in
                guard let self else { return }
                self.telemetry.droppedBuffers += 1
                self.publishTelemetry(force: true)
            }
            return
        }
        pendingBuffers += 1
        pendingLock.unlock()

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock()
                self.pendingBuffers -= 1
                self.pendingLock.unlock()
            }

            do {
                if self.converter?.matches(buffer.format) != true {
                    self.converter = try PCM16Converter(sourceFormat: buffer.format)
                    self.telemetry.sourceFormat = Self.describe(buffer.format)
                }
                guard let pcmData = try self.converter?.convert(buffer), !pcmData.isEmpty else {
                    return
                }

                let chunks = self.chunker.append(pcmData)
                for chunk in chunks {
                    self.telemetry.packets += 1
                    self.telemetry.bytes += UInt64(chunk.count)
                    self.updateLevels(with: chunk)
                    self.onChunk(chunk)
                }
                self.publishTelemetryIfNeeded()
            } catch {
                self.telemetry.droppedBuffers += 1
                self.telemetry.sourceFormat = "Conversion error: \(error.localizedDescription)"
                self.publishTelemetry(force: true)
            }
        }
    }

    func finish() {
        processingQueue.sync {}
        publishTelemetry(force: true)
    }

    private func updateLevels(with data: Data) {
        var sumSquares: Double = 0
        var peak: Float = 0
        var samples: [Float] = []

        data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Int16.self)
            let stride = max(1, values.count / 10)
            for (index, value) in values.enumerated() {
                let normalized = Float(value) / Float(Int16.max)
                let magnitude = abs(normalized)
                peak = max(peak, magnitude)
                sumSquares += Double(normalized * normalized)
                if index.isMultiple(of: stride) {
                    samples.append(normalized)
                }
            }
            let count = max(1, values.count)
            telemetry.rms = Float(sqrt(sumSquares / Double(count)))
        }

        telemetry.peak = peak
        telemetry.waveform.append(contentsOf: samples.prefix(10))
        if telemetry.waveform.count > 180 {
            telemetry.waveform.removeFirst(telemetry.waveform.count - 180)
        }
    }

    private func publishTelemetryIfNeeded() {
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - lastTelemetryUpdate.uptimeNanoseconds >= 50_000_000 {
            publishTelemetry(force: true)
            lastTelemetryUpdate = now
        }
    }

    private func publishTelemetry(force: Bool) {
        guard force else { return }
        let snapshot = telemetry
        DispatchQueue.main.async { [onTelemetry] in
            onTelemetry(snapshot)
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let sampleRate = Int(format.sampleRate.rounded())
        return "\(sampleRate) Hz · \(format.channelCount) ch → 24 kHz mono PCM16"
    }
}

private final class PCM16Converter {
    private let sourceFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(sourceFormat: AVAudioFormat) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            throw MeetingCopilotError.audio("Could not create the 24 kHz transcription format.")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw MeetingCopilotError.audio(
                "Could not convert \(Int(sourceFormat.sampleRate)) Hz audio to 24 kHz PCM16."
            )
        }
        self.sourceFormat = sourceFormat
        outputFormat = targetFormat
        self.converter = converter
    }

    func matches(_ format: AVAudioFormat) -> Bool {
        sourceFormat == format
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(
            ceil(Double(input.frameLength) * ratio) + 32
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: estimatedFrames
        ) else {
            throw MeetingCopilotError.audio("Could not allocate the audio conversion buffer.")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw MeetingCopilotError.audio("Audio conversion failed.")
        }
        guard
            output.frameLength > 0,
            let pointer = output.audioBufferList.pointee.mBuffers.mData
        else {
            return Data()
        }
        let byteCount = Int(output.audioBufferList.pointee.mBuffers.mDataByteSize)
        return Data(bytes: pointer, count: byteCount)
    }
}

private struct PCMChunker {
    private let chunkSize: Int
    private var storage = Data()
    private var readOffset = 0

    init(chunkSize: Int) {
        self.chunkSize = chunkSize
    }

    mutating func append(_ data: Data) -> [Data] {
        storage.append(data)
        var result: [Data] = []

        while storage.count - readOffset >= chunkSize {
            let end = readOffset + chunkSize
            result.append(storage.subdata(in: readOffset..<end))
            readOffset = end
        }

        if readOffset > 32 * chunkSize {
            storage.removeSubrange(0..<readOffset)
            readOffset = 0
        }
        return result
    }
}

import Foundation

struct QuickDictationPreparedAudio: Equatable {
    let pcm16Audio: Data
    let sourceRange: Range<Int>
    let speechFrameCount: Int
    let noiseFloorRMS: Float
    let speechThresholdRMS: Float

    func leadingMilliseconds(sampleRate: Int) -> Int {
        Self.milliseconds(
            forByteCount: sourceRange.lowerBound,
            sampleRate: sampleRate
        )
    }

    func trailingMilliseconds(
        sourceByteCount: Int,
        sampleRate: Int
    ) -> Int {
        Self.milliseconds(
            forByteCount: max(0, sourceByteCount - sourceRange.upperBound),
            sampleRate: sampleRate
        )
    }

    private static func milliseconds(
        forByteCount byteCount: Int,
        sampleRate: Int
    ) -> Int {
        guard sampleRate > 0 else { return 0 }
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        return Int((Double(sampleCount) * 1_000 / Double(sampleRate)).rounded())
    }
}

/// Rejects captures without sustained speech and removes release-time room tone
/// before ASR sees it. The decision uses temporal energy, not transcript text:
/// a single click or microphone spike cannot turn an otherwise empty recording
/// into a plausible-looking phrase.
enum QuickDictationAudioPolicy {
    static let sampleRate = RealtimeRefinementClient.captureSampleRate
    static let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
    static let minimumAudioBytes = Int(Double(bytesPerSecond) * 0.2)

    private static let frameDurationSeconds = 0.02
    private static let frameSampleCount = Int(
        Double(sampleRate) * frameDurationSeconds
    )
    static let frameByteCount = frameSampleCount * MemoryLayout<Int16>.size

    private static let minimumSpeechRMS: Float = 0.004
    private static let maximumAdaptiveThresholdRMS: Float = 0.018
    private static let noiseFloorMultiplier: Float = 2.4
    private static let minimumSpeechFrameCount = 6
    private static let minimumConsecutiveSpeechFrames = 2
    private static let maximumQuietFramesWithinSpeech = 3
    private static let paddingFrameCount = 10

    static func prepare(_ pcm16Audio: Data) -> QuickDictationPreparedAudio? {
        guard
            pcm16Audio.count >= minimumAudioBytes,
            pcm16Audio.count.isMultiple(of: MemoryLayout<Int16>.size)
        else {
            return nil
        }

        let frameLevels = rmsLevels(in: pcm16Audio)
        guard !frameLevels.isEmpty else { return nil }

        let noiseFloor = estimatedNoiseFloor(from: frameLevels)
        let threshold = min(
            maximumAdaptiveThresholdRMS,
            max(minimumSpeechRMS, noiseFloor * noiseFloorMultiplier)
        )
        let activeFrames = frameLevels.map { $0 >= threshold }
        let regions = supportedSpeechRegions(in: activeFrames)
        guard let firstRegion = regions.first, let lastRegion = regions.last else {
            return nil
        }

        let firstFrame = max(0, firstRegion.lowerBound - paddingFrameCount)
        let lastFrame = min(
            frameLevels.count - 1,
            lastRegion.upperBound + paddingFrameCount
        )
        let lowerByte = firstFrame * frameByteCount
        let upperByte = min(
            pcm16Audio.count,
            (lastFrame + 1) * frameByteCount
        )
        guard lowerByte < upperByte else { return nil }

        return QuickDictationPreparedAudio(
            pcm16Audio: Data(pcm16Audio[lowerByte..<upperByte]),
            sourceRange: lowerByte..<upperByte,
            speechFrameCount: regions.reduce(0) { count, region in
                count + activeFrames[region].filter { $0 }.count
            },
            noiseFloorRMS: noiseFloor,
            speechThresholdRMS: threshold
        )
    }

    private static func rmsLevels(in pcm16Audio: Data) -> [Float] {
        pcm16Audio.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return [] }

            var result: [Float] = []
            result.reserveCapacity(
                (samples.count + frameSampleCount - 1) / frameSampleCount
            )
            var frameStart = 0
            while frameStart < samples.count {
                let frameEnd = min(samples.count, frameStart + frameSampleCount)
                var sumSquares = 0.0
                for index in frameStart..<frameEnd {
                    let normalized = Double(samples[index]) / Double(Int16.max)
                    sumSquares += normalized * normalized
                }
                let sampleCount = max(1, frameEnd - frameStart)
                result.append(Float(sqrt(sumSquares / Double(sampleCount))))
                frameStart = frameEnd
            }
            return result
        }
    }

    private static func estimatedNoiseFloor(from levels: [Float]) -> Float {
        let sorted = levels.sorted()
        let sampleCount = max(1, sorted.count / 10)
        return sorted.prefix(sampleCount).reduce(0, +) / Float(sampleCount)
    }

    private static func supportedSpeechRegions(
        in activeFrames: [Bool]
    ) -> [ClosedRange<Int>] {
        struct Candidate {
            var firstActiveFrame: Int
            var lastActiveFrame: Int
            var activeFrameCount: Int
            var consecutiveActiveFrames: Int
            var maximumConsecutiveActiveFrames: Int
        }

        var regions: [ClosedRange<Int>] = []
        var candidate: Candidate?

        func appendIfSupported(_ candidate: Candidate?) {
            guard
                let candidate,
                candidate.activeFrameCount >= minimumSpeechFrameCount,
                candidate.maximumConsecutiveActiveFrames
                    >= minimumConsecutiveSpeechFrames
            else {
                return
            }
            regions.append(
                candidate.firstActiveFrame...candidate.lastActiveFrame
            )
        }

        for (index, isActive) in activeFrames.enumerated() {
            guard isActive else {
                if var current = candidate {
                    current.consecutiveActiveFrames = 0
                    candidate = current
                }
                continue
            }

            if var current = candidate {
                let quietFrameCount = index - current.lastActiveFrame - 1
                if quietFrameCount > maximumQuietFramesWithinSpeech {
                    appendIfSupported(current)
                    candidate = Candidate(
                        firstActiveFrame: index,
                        lastActiveFrame: index,
                        activeFrameCount: 1,
                        consecutiveActiveFrames: 1,
                        maximumConsecutiveActiveFrames: 1
                    )
                    continue
                }
                current.lastActiveFrame = index
                current.activeFrameCount += 1
                current.consecutiveActiveFrames += 1
                current.maximumConsecutiveActiveFrames = max(
                    current.maximumConsecutiveActiveFrames,
                    current.consecutiveActiveFrames
                )
                candidate = current
            } else {
                candidate = Candidate(
                    firstActiveFrame: index,
                    lastActiveFrame: index,
                    activeFrameCount: 1,
                    consecutiveActiveFrames: 1,
                    maximumConsecutiveActiveFrames: 1
                )
            }
        }
        appendIfSupported(candidate)
        return regions
    }
}

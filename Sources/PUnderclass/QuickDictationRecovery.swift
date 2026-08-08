import Foundation

struct QuickDictationRecoveryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let audioByteCount: Int
    let languages: [String]
    var attemptCount: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        audioByteCount: Int,
        languages: [String],
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioByteCount = audioByteCount
        self.languages = languages
        self.attemptCount = attemptCount
        self.lastError = lastError
    }

    var audioDurationSeconds: TimeInterval {
        Double(audioByteCount) / Double(PCM16WaveFile.bytesPerSecond)
    }
}

enum PCM16WaveFile {
    static let sampleRate = 24_000
    static let channelCount = 1
    static let bitsPerSample = 16
    static let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
    private static let headerByteCount = 44

    static func encode(_ pcm16Audio: Data) throws -> Data {
        guard pcm16Audio.count <= Int(UInt32.max) - 36 else {
            throw QuickDictationRecoveryError.audioTooLarge
        }

        var data = Data()
        data.reserveCapacity(headerByteCount + pcm16Audio.count)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm16Audio.count), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(channelCount), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(bytesPerSecond), to: &data)
        append(UInt16(MemoryLayout<Int16>.size), to: &data)
        append(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm16Audio.count), to: &data)
        data.append(pcm16Audio)
        return data
    }

    static func decode(_ waveData: Data) throws -> Data {
        guard waveData.count >= headerByteCount else {
            throw QuickDictationRecoveryError.invalidWaveFile
        }
        guard
            String(data: waveData[0..<4], encoding: .ascii) == "RIFF",
            String(data: waveData[8..<12], encoding: .ascii) == "WAVE",
            String(data: waveData[12..<16], encoding: .ascii) == "fmt ",
            readUInt32(waveData, at: 16) == 16,
            readUInt16(waveData, at: 20) == 1,
            readUInt16(waveData, at: 22) == UInt16(channelCount),
            readUInt32(waveData, at: 24) == UInt32(sampleRate),
            readUInt16(waveData, at: 34) == UInt16(bitsPerSample),
            String(data: waveData[36..<40], encoding: .ascii) == "data"
        else {
            throw QuickDictationRecoveryError.unsupportedWaveFile
        }

        let audioByteCount = Int(readUInt32(waveData, at: 40))
        guard
            audioByteCount >= 0,
            headerByteCount + audioByteCount <= waveData.count
        else {
            throw QuickDictationRecoveryError.invalidWaveFile
        }
        return Data(waveData[headerByteCount..<(headerByteCount + audioByteCount)])
    }

    private static func append<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset])
            | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

struct QuickDictationRecoveryStore {
    private static let applicationDirectoryName =
        "com.newtypekk.punderclass"
    private static let recoveryDirectoryName = "QuickDictationRecoveries"
    private static let packageExtension = "quickdictation"
    private static let metadataFileName = "metadata.json"
    private static let audioFileName = "recording.wav"

    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) -> QuickDictationRecoveryStore {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return QuickDictationRecoveryStore(
            directoryURL: applicationSupportURL
                .appendingPathComponent(applicationDirectoryName, isDirectory: true)
                .appendingPathComponent(recoveryDirectoryName, isDirectory: true),
            fileManager: fileManager
        )
    }

    func load() throws -> [QuickDictationRecoveryEntry] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let packageURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return packageURLs
            .filter { packageURL in
                guard packageURL.pathExtension == Self.packageExtension else {
                    return false
                }
                return (try? packageURL.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true
            }
            .compactMap(loadEntry)
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id.uuidString > rhs.id.uuidString
            }
    }

    func preserve(
        pcm16Audio: Data,
        languages: [String],
        createdAt: Date = Date()
    ) throws -> QuickDictationRecoveryEntry {
        let entry = QuickDictationRecoveryEntry(
            createdAt: createdAt,
            audioByteCount: pcm16Audio.count,
            languages: languages
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let temporaryPackageURL = directoryURL.appendingPathComponent(
            ".\(entry.id.uuidString).temporary",
            isDirectory: true
        )
        let finalPackageURL = packageURL(for: entry)
        try? fileManager.removeItem(at: temporaryPackageURL)
        do {
            try fileManager.createDirectory(
                at: temporaryPackageURL,
                withIntermediateDirectories: false
            )
            try PCM16WaveFile.encode(pcm16Audio).write(
                to: temporaryPackageURL.appendingPathComponent(Self.audioFileName),
                options: .atomic
            )
            try encodedMetadata(entry).write(
                to: temporaryPackageURL.appendingPathComponent(Self.metadataFileName),
                options: .atomic
            )
            try fileManager.moveItem(
                at: temporaryPackageURL,
                to: finalPackageURL
            )
            return entry
        } catch {
            try? fileManager.removeItem(at: temporaryPackageURL)
            throw error
        }
    }

    func pcm16Audio(for entry: QuickDictationRecoveryEntry) throws -> Data {
        let waveData = try Data(contentsOf: audioURL(for: entry))
        return try PCM16WaveFile.decode(waveData)
    }

    func recordFailure(
        for entry: QuickDictationRecoveryEntry,
        message: String
    ) throws -> QuickDictationRecoveryEntry {
        var updated = entry
        updated.attemptCount += 1
        updated.lastError = message
        try encodedMetadata(updated).write(
            to: metadataURL(for: updated),
            options: .atomic
        )
        return updated
    }

    func remove(_ entry: QuickDictationRecoveryEntry) throws {
        let url = packageURL(for: entry)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func audioURL(for entry: QuickDictationRecoveryEntry) -> URL {
        packageURL(for: entry).appendingPathComponent(Self.audioFileName)
    }

    private func loadEntry(
        from packageURL: URL
    ) -> QuickDictationRecoveryEntry? {
        guard
            let packageID = UUID(
                uuidString: packageURL.deletingPathExtension().lastPathComponent
            )
        else {
            return nil
        }
        let metadataURL = packageURL.appendingPathComponent(Self.metadataFileName)
        if
            let data = try? Data(contentsOf: metadataURL),
            let entry = try? JSONDecoder().decode(
                QuickDictationRecoveryEntry.self,
                from: data
            ),
            entry.id == packageID,
            entry.audioByteCount >= 0,
            entry.attemptCount >= 0
        {
            return entry
        }

        let audioURL = packageURL.appendingPathComponent(Self.audioFileName)
        let audioByteCount = (try? Data(contentsOf: audioURL))
            .flatMap { try? PCM16WaveFile.decode($0).count }
            ?? 0
        let values = try? packageURL.resourceValues(
            forKeys: [.creationDateKey]
        )
        return QuickDictationRecoveryEntry(
            id: packageID,
            createdAt: values?.creationDate ?? Date(),
            audioByteCount: audioByteCount,
            languages: [],
            lastError: "Recovery metadata was damaged, but the recording was retained."
        )
    }

    private func packageURL(for entry: QuickDictationRecoveryEntry) -> URL {
        directoryURL.appendingPathComponent(
            "\(entry.id.uuidString).\(Self.packageExtension)",
            isDirectory: true
        )
    }

    private func metadataURL(for entry: QuickDictationRecoveryEntry) -> URL {
        packageURL(for: entry).appendingPathComponent(Self.metadataFileName)
    }

    private func encodedMetadata(
        _ entry: QuickDictationRecoveryEntry
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entry)
    }
}

private enum QuickDictationRecoveryError: LocalizedError {
    case audioTooLarge
    case invalidWaveFile
    case unsupportedWaveFile

    var errorDescription: String? {
        switch self {
        case .audioTooLarge:
            "The dictation recording is too large to store as a WAV file."
        case .invalidWaveFile:
            "The retained dictation WAV file is incomplete."
        case .unsupportedWaveFile:
            "The retained dictation WAV file does not use 24 kHz mono PCM16 audio."
        }
    }
}

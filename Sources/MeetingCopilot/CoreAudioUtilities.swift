import AppKit
import CoreAudio
import Foundation

struct AudioInputDeviceInfo: Equatable {
    let id: AudioObjectID
    let name: String
}

enum CoreAudioUtilities {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw MeetingCopilotError.coreAudio(operation: operation, status: status)
        }
    }

    static func objectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var propertyAddress = address(selector, scope: scope)
        var byteCount: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &byteCount),
            operation: "Read Core Audio property size"
        )

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }

        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try values.withUnsafeMutableBytes { bytes in
            try check(
                AudioObjectGetPropertyData(
                    objectID,
                    &propertyAddress,
                    0,
                    nil,
                    &byteCount,
                    bytes.baseAddress!
                ),
                operation: "Read Core Audio object list"
            )
        }
        return values
    }

    static func pid(for processObjectID: AudioObjectID) throws -> pid_t {
        var propertyAddress = address(kAudioProcessPropertyPID)
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        try check(
            AudioObjectGetPropertyData(
                processObjectID,
                &propertyAddress,
                0,
                nil,
                &size,
                &value
            ),
            operation: "Read audio process PID"
        )
        return value
    }

    static func uint32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var propertyAddress = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &propertyAddress,
                0,
                nil,
                &size,
                &value
            ),
            operation: "Read Core Audio integer property"
        )
        return value
    }

    static func string(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var propertyAddress = address(selector, scope: scope)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(
                AudioObjectGetPropertyData(
                    objectID,
                    &propertyAddress,
                    0,
                    nil,
                    &size,
                    pointer
                ),
                operation: "Read Core Audio string property"
            )
        }
        return value as String
    }

    static func streamFormat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> AudioStreamBasicDescription {
        var propertyAddress = address(selector, scope: scope)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &propertyAddress,
                0,
                nil,
                &size,
                &format
            ),
            operation: "Read audio stream format"
        )
        return format
    }

    static func defaultInputDevice() -> AudioInputDeviceInfo? {
        var propertyAddress = address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        let name = (try? string(
            objectID: deviceID,
            selector: kAudioObjectPropertyName
        )) ?? "System default microphone"
        return AudioInputDeviceInfo(id: deviceID, name: name)
    }

    static func defaultInputDeviceName() -> String {
        defaultInputDevice()?.name ?? "No input device"
    }
}

enum AudioProcessCatalog {
    static func load() throws -> [AudioProcessInfo] {
        let processIDs = try CoreAudioUtilities.objectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )

        return processIDs.compactMap { objectID in
            guard
                let pid = try? CoreAudioUtilities.pid(for: objectID),
                pid != ProcessInfo.processInfo.processIdentifier
            else {
                return nil
            }

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let bundleID = runningApp?.bundleIdentifier
                ?? (try? CoreAudioUtilities.string(
                    objectID: objectID,
                    selector: kAudioProcessPropertyBundleID
                ))
            let name = runningApp?.localizedName
                ?? bundleID
                ?? "Audio process \(pid)"
            let isProducingOutput =
                (try? CoreAudioUtilities.uint32(
                    objectID: objectID,
                    selector: kAudioProcessPropertyIsRunningOutput
                )) == 1

            return AudioProcessInfo(
                id: objectID,
                pid: pid,
                name: name,
                bundleIdentifier: bundleID,
                isProducingOutput: isProducingOutput
            )
        }
        .sorted {
            if $0.isProducingOutput != $1.isProducingOutput {
                return $0.isProducingOutput && !$1.isProducingOutput
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

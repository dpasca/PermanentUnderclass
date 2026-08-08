import CoreAudio
import Foundation

final class DefaultInputDeviceMonitor {
    typealias ChangeHandler = (AudioInputDeviceInfo?) -> Void

    private let monitor: DefaultAudioDeviceMonitor<AudioInputDeviceInfo>

    init(onChange: @escaping ChangeHandler) {
        monitor = DefaultAudioDeviceMonitor(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            operationName: "Monitor the default microphone",
            resolveDevice: CoreAudioUtilities.defaultInputDevice,
            onChange: onChange
        )
    }

    func start() throws {
        try monitor.start()
    }

    func stop() {
        monitor.stop()
    }
}

final class DefaultOutputDeviceMonitor {
    typealias ChangeHandler = (AudioOutputDeviceInfo?) -> Void

    private let monitor: DefaultAudioDeviceMonitor<AudioOutputDeviceInfo>

    init(onChange: @escaping ChangeHandler) {
        monitor = DefaultAudioDeviceMonitor(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            operationName: "Monitor the default audio output",
            resolveDevice: CoreAudioUtilities.defaultOutputDevice,
            onChange: onChange
        )
    }

    func start() throws {
        try monitor.start()
    }

    func stop() {
        monitor.stop()
    }
}

private final class DefaultAudioDeviceMonitor<Device: Equatable> {
    typealias ChangeHandler = (Device?) -> Void

    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue.main
    private let selector: AudioObjectPropertySelector
    private let operationName: String
    private let resolveDevice: () -> Device?
    private let onChange: ChangeHandler
    private var listener: AudioObjectPropertyListenerBlock?
    private var pendingRefresh: DispatchWorkItem?
    private var lastDevice: Device?
    private var isStarted = false

    init(
        selector: AudioObjectPropertySelector,
        operationName: String,
        resolveDevice: @escaping () -> Device?,
        onChange: @escaping ChangeHandler
    ) {
        self.selector = selector
        self.operationName = operationName
        self.resolveDevice = resolveDevice
        self.onChange = onChange
    }

    func start() throws {
        guard !isStarted else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Device-list changes also need to refresh menu choices even when
            // the current default device itself did not change.
            self?.scheduleRefresh(force: true)
        }
        self.listener = listener

        var defaultDeviceAddress = CoreAudioUtilities.address(selector)
        try CoreAudioUtilities.check(
            AudioObjectAddPropertyListenerBlock(
                systemObjectID,
                &defaultDeviceAddress,
                queue,
                listener
            ),
            operation: operationName
        )

        do {
            var devicesAddress = CoreAudioUtilities.address(
                kAudioHardwarePropertyDevices
            )
            try CoreAudioUtilities.check(
                AudioObjectAddPropertyListenerBlock(
                    systemObjectID,
                    &devicesAddress,
                    queue,
                    listener
                ),
                operation: "Monitor connected audio devices"
            )
        } catch {
            AudioObjectRemovePropertyListenerBlock(
                systemObjectID,
                &defaultDeviceAddress,
                queue,
                listener
            )
            self.listener = nil
            throw error
        }

        isStarted = true
        scheduleRefresh(delay: .nanoseconds(0), force: true)
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard isStarted, let listener else { return }

        var defaultDeviceAddress = CoreAudioUtilities.address(selector)
        AudioObjectRemovePropertyListenerBlock(
            systemObjectID,
            &defaultDeviceAddress,
            queue,
            listener
        )
        var devicesAddress = CoreAudioUtilities.address(
            kAudioHardwarePropertyDevices
        )
        AudioObjectRemovePropertyListenerBlock(
            systemObjectID,
            &devicesAddress,
            queue,
            listener
        )
        self.listener = nil
        isStarted = false
    }

    private func scheduleRefresh(
        delay: DispatchTimeInterval = .milliseconds(180),
        force: Bool = false
    ) {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.publishCurrentDevice(force: force)
        }
        pendingRefresh = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publishCurrentDevice(force: Bool) {
        let device = resolveDevice()
        guard force || device != lastDevice else { return }
        lastDevice = device
        onChange(device)
    }

    deinit {
        stop()
    }
}

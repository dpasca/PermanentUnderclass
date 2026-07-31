import CoreAudio
import Foundation

final class DefaultInputDeviceMonitor {
    typealias ChangeHandler = (AudioInputDeviceInfo?) -> Void

    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue.main
    private let onChange: ChangeHandler
    private var listener: AudioObjectPropertyListenerBlock?
    private var pendingRefresh: DispatchWorkItem?
    private var lastDevice: AudioInputDeviceInfo?
    private var isStarted = false

    init(onChange: @escaping ChangeHandler) {
        self.onChange = onChange
    }

    func start() throws {
        guard !isStarted else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        self.listener = listener

        var defaultInputAddress = CoreAudioUtilities.address(
            kAudioHardwarePropertyDefaultInputDevice
        )
        try CoreAudioUtilities.check(
            AudioObjectAddPropertyListenerBlock(
                systemObjectID,
                &defaultInputAddress,
                queue,
                listener
            ),
            operation: "Monitor the default microphone"
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
                &defaultInputAddress,
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

        var defaultInputAddress = CoreAudioUtilities.address(
            kAudioHardwarePropertyDefaultInputDevice
        )
        AudioObjectRemovePropertyListenerBlock(
            systemObjectID,
            &defaultInputAddress,
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
        let device = CoreAudioUtilities.defaultInputDevice()
        guard force || device != lastDevice else { return }
        lastDevice = device
        onChange(device)
    }

    deinit {
        stop()
    }
}

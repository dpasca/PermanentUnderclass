import AppKit
import Carbon.HIToolbox
import OSLog

struct HeadlessModeHotKey {
    static let displayName = "Control + Command + H"

    fileprivate static let keyCode = UInt32(kVK_ANSI_H)
    fileprivate static let modifiers = UInt32(controlKey | cmdKey)
    fileprivate static let identifier = EventHotKeyID(
        signature: 0x5055_4844, // "PUHD"
        id: 1
    )
}

extension Notification.Name {
    static let headlessModeDidChange = Notification.Name(
        "PUnderclass.HeadlessModeDidChange"
    )
}

enum HeadlessModeNotification {
    static let isHeadlessKey = "isHeadless"

    static func isHeadless(_ notification: Notification) -> Bool? {
        notification.userInfo?[isHeadlessKey] as? Bool
    }
}

private struct GlobalHotKeyRegistrationError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        if status == eventHotKeyExistsErr {
            return "The shortcut \(HeadlessModeHotKey.displayName) is already in use."
        }
        return "Could not \(operation) the headless-mode shortcut (OSStatus \(status))."
    }
}

/// Registers a system-wide shortcut without requiring Accessibility access.
private final class HeadlessModeHotKeyMonitor {
    private let handler: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var isPressed = false

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func start() throws {
        guard eventHandler == nil, hotKey == nil else { return }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let monitor = Unmanaged<HeadlessModeHotKeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return monitor.handle(event)
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            eventHandler = nil
            throw GlobalHotKeyRegistrationError(
                operation: "install",
                status: installStatus
            )
        }

        let registrationStatus = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            Self.identifier,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &hotKey
        )
        guard registrationStatus == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
            eventHandler = nil
            hotKey = nil
            throw GlobalHotKeyRegistrationError(
                operation: "register",
                status: registrationStatus
            )
        }
    }

    func stop() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKey = nil
        eventHandler = nil
        isPressed = false
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard parameterStatus == noErr else { return parameterStatus }
        guard
            identifier.signature == Self.identifier.signature,
            identifier.id == Self.identifier.id
        else {
            return OSStatus(eventNotHandledErr)
        }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return noErr }
            isPressed = true
            handler()
        case UInt32(kEventHotKeyReleased):
            isPressed = false
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    private static var keyCode: UInt32 { HeadlessModeHotKey.keyCode }
    private static var modifiers: UInt32 { HeadlessModeHotKey.modifiers }
    private static var identifier: EventHotKeyID {
        HeadlessModeHotKey.identifier
    }

    deinit {
        stop()
    }
}

/// Hides every application window and removes PUnderclass from the Dock and
/// application switcher while leaving its capture and companion services alive.
final class HeadlessModeController {
    private static let logger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "HeadlessMode"
    )

    private let application: NSApplication
    private lazy var hotKeyMonitor = HeadlessModeHotKeyMonitor { [weak self] in
        self?.toggle()
    }
    private var windowsToRestore: [NSWindow] = []
    private(set) var isHeadless = false

    init(application: NSApplication = .shared) {
        self.application = application
    }

    func start() throws {
        try hotKeyMonitor.start()
        Self.logger.notice(
            "hotkey_registered shortcut=\(HeadlessModeHotKey.displayName, privacy: .public)"
        )
    }

    func stop() {
        hotKeyMonitor.stop()
    }

    func toggle() {
        if isHeadless {
            leaveHeadlessMode()
        } else {
            enterHeadlessMode()
        }
    }

    func showApplication() {
        if isHeadless {
            leaveHeadlessMode()
            return
        }
        restoreWindows([])
    }

    private func enterHeadlessMode() {
        let restorableWindows = application.windows.filter {
            $0.isVisible && $0.canBecomeMain
        }
        windowsToRestore = restorableWindows
        isHeadless = true
        guard application.setActivationPolicy(.accessory) else {
            windowsToRestore = []
            isHeadless = false
            Self.logger.error("enter_failed reason=activation_policy")
            return
        }

        publishState()
        application.windows.forEach { $0.orderOut(nil) }
        Self.logger.notice("entered")
    }

    private func leaveHeadlessMode() {
        let isRegular = application.activationPolicy() == .regular
        guard isRegular || application.setActivationPolicy(.regular) else {
            Self.logger.error("leave_failed reason=activation_policy")
            return
        }

        if !PUnderclassApplicationIcon.install(on: application) {
            Self.logger.error("icon_restore_failed")
        }

        isHeadless = false
        publishState()
        let restorableWindows = windowsToRestore
        windowsToRestore = []
        restoreWindows(restorableWindows)
        Self.logger.notice("left")
    }

    private func restoreWindows(_ restorableWindows: [NSWindow]) {
        application.unhide(nil)
        application.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let windows = restorableWindows.isEmpty
                ? self.application.windows.filter { $0.canBecomeMain }
                : restorableWindows
            for window in windows {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.orderFront(nil)
            }
            windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    private func publishState() {
        NotificationCenter.default.post(
            name: .headlessModeDidChange,
            object: self,
            userInfo: [HeadlessModeNotification.isHeadlessKey: isHeadless]
        )
    }

    deinit {
        stop()
    }
}

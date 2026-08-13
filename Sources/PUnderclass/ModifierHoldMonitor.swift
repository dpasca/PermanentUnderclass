import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

enum ModifierHoldSignal: Equatable {
    case pressed
    case released
    case interrupted
}

enum ModifierHoldSignalDisposition: Equatable {
    case emit(ModifierHoldSignal)
    case deferRelease
    case cancelDeferredRelease
}

/// Keeps a momentary modifier-key bounce from splitting one spoken thought
/// into two recordings. A real release is still delivered after the short
/// grace period; pressing the chord again before then cancels both boundary
/// signals and leaves the existing capture running.
struct ModifierHoldSignalCoalescer {
    private(set) var hasDeferredRelease = false

    mutating func receive(
        _ signal: ModifierHoldSignal
    ) -> ModifierHoldSignalDisposition {
        switch signal {
        case .pressed:
            guard hasDeferredRelease else { return .emit(.pressed) }
            hasDeferredRelease = false
            return .cancelDeferredRelease

        case .released:
            hasDeferredRelease = true
            return .deferRelease

        case .interrupted:
            hasDeferredRelease = false
            return .emit(.interrupted)
        }
    }

    mutating func releaseDelayElapsed() -> ModifierHoldSignal? {
        guard hasDeferredRelease else { return nil }
        hasDeferredRelease = false
        return .released
    }

    mutating func reset() {
        hasDeferredRelease = false
    }
}

struct ModifierHoldState {
    private(set) var isHeld = false

    mutating func update(flags: CGEventFlags) -> ModifierHoldSignal? {
        if isHeld {
            // Once dictation has started, adding Shift, Control, Fn, or another
            // modifier must not silently end it. Only releasing Command or
            // Option completes the hold.
            guard Self.hasRequiredModifiers(flags) else {
                isHeld = false
                return .released
            }
            return nil
        }

        let isExactChord = Self.isExactChord(flags)

        if isExactChord {
            isHeld = true
            return .pressed
        }
        return nil
    }

    mutating func synchronize(flags: CGEventFlags) {
        isHeld = Self.isExactChord(flags)
    }

    mutating func interruptForEscape() -> ModifierHoldSignal? {
        guard isHeld else { return nil }
        isHeld = false
        return .interrupted
    }

    mutating func reset() {
        isHeld = false
    }

    static func hasRequiredModifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand)
            && flags.contains(.maskAlternate)
    }

    private static func isExactChord(_ flags: CGEventFlags) -> Bool {
        let hasRequired = hasRequiredModifiers(flags)
        let hasDisallowedModifiers = flags.contains(.maskControl)
            || flags.contains(.maskShift)
            || flags.contains(.maskSecondaryFn)
        return hasRequired && !hasDisallowedModifiers
    }
}

final class ModifierHoldMonitor {
    typealias SignalHandler = (
        _ signal: ModifierHoldSignal,
        _ focusedApplication: NSRunningApplication?
    ) -> Void

    static let diagnosticEventTag: Int64 = 0x4D_43_44_54
    static let pasteEventTag: Int64 = 0x4D_43_50_53
    static let escapeKeyCode: Int64 = 53
    static let releaseBounceGraceSeconds: TimeInterval = 0.12
    private static let logger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "QuickDictationHotkey"
    )
    private let signalHandler: SignalHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installedRunLoop: CFRunLoop?
    private var retainedSelf: Unmanaged<ModifierHoldMonitor>?
    private var state = ModifierHoldState()
    private var signalCoalescer = ModifierHoldSignalCoalescer()
    private var deferredReleaseWorkItem: DispatchWorkItem?
    private var isDiagnosticHold = false
    private var isConsumingEscapeUntilChordRelease = false

    init(signalHandler: @escaping SignalHandler) {
        self.signalHandler = signalHandler
    }

    static func shouldInterruptForKeyDown(
        keyCode: Int64,
        eventTag: Int64,
        isDiagnosticHold: Bool
    ) -> Bool {
        keyCode == escapeKeyCode
            && !isDiagnosticHold
            && eventTag != pasteEventTag
    }

    func start() throws {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            throw PUnderclassError.audio(
                "Accessibility permission is required for the global dictation shortcut."
            )
        }

        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierHoldMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            retainedSelf = nil
            throw PUnderclassError.audio(
                "The global dictation shortcut could not be installed. Check Accessibility permission."
            )
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        eventTap = tap
        runLoopSource = source
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.synchronize(flags: CGEventSource.flagsState(.combinedSessionState))
        Self.logger.notice("event_tap_installed")
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource, let installedRunLoop {
            CFRunLoopRemoveSource(installedRunLoop, runLoopSource, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        state.reset()
        deferredReleaseWorkItem?.cancel()
        deferredReleaseWorkItem = nil
        signalCoalescer.reset()
        isDiagnosticHold = false
        isConsumingEscapeUntilChordRelease = false
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.logger.error("event_tap_disabled type=\(type.rawValue, privacy: .public)")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            state.synchronize(flags: CGEventSource.flagsState(.combinedSessionState))
            return Unmanaged.passUnretained(event)
        }

        let signal: ModifierHoldSignal?
        var shouldConsumeEvent = false
        switch type {
        case .flagsChanged:
            signal = state.update(flags: event.flags)
            if signal == .pressed {
                isDiagnosticHold = event.getIntegerValueField(.eventSourceUserData)
                    == Self.diagnosticEventTag
            } else if signal == .released {
                isDiagnosticHold = false
            }
            if !ModifierHoldState.hasRequiredModifiers(event.flags) {
                isConsumingEscapeUntilChordRelease = false
            }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let eventTag = event.getIntegerValueField(.eventSourceUserData)
            signal = Self.shouldInterruptForKeyDown(
                keyCode: keyCode,
                eventTag: eventTag,
                isDiagnosticHold: isDiagnosticHold
            ) ? state.interruptForEscape() : nil
            if signal == .interrupted {
                isDiagnosticHold = false
                isConsumingEscapeUntilChordRelease = true
            }
            shouldConsumeEvent = keyCode == Self.escapeKeyCode
                && isConsumingEscapeUntilChordRelease
        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            signal = nil
            shouldConsumeEvent = keyCode == Self.escapeKeyCode
                && isConsumingEscapeUntilChordRelease
        default:
            signal = nil
        }
        if let signal {
            route(
                signal,
                flags: event.flags,
                focusedApplication: signal == .pressed
                    ? NSWorkspace.shared.frontmostApplication
                    : nil
            )
        }
        return shouldConsumeEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func route(
        _ signal: ModifierHoldSignal,
        flags: CGEventFlags,
        focusedApplication: NSRunningApplication?
    ) {
        switch signalCoalescer.receive(signal) {
        case let .emit(signal):
            deferredReleaseWorkItem?.cancel()
            deferredReleaseWorkItem = nil
            publish(
                signal,
                flags: flags,
                focusedApplication: focusedApplication
            )

        case .deferRelease:
            deferredReleaseWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.deferredReleaseWorkItem = nil
                guard let signal = self.signalCoalescer.releaseDelayElapsed() else {
                    return
                }
                self.publish(signal, flags: flags, focusedApplication: nil)
            }
            deferredReleaseWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.releaseBounceGraceSeconds,
                execute: workItem
            )

        case .cancelDeferredRelease:
            deferredReleaseWorkItem?.cancel()
            deferredReleaseWorkItem = nil
            Self.logger.notice("shortcut_release_bounce_coalesced")
        }
    }

    private func publish(
        _ signal: ModifierHoldSignal,
        flags: CGEventFlags,
        focusedApplication: NSRunningApplication?
    ) {
        Self.logger.notice(
            "shortcut_signal=\(String(describing: signal), privacy: .public) flags=\(flags.rawValue, privacy: .public)"
        )
        DispatchQueue.main.async { [signalHandler, focusedApplication] in
            signalHandler(signal, focusedApplication)
        }
    }

    deinit {
        stop()
    }
}

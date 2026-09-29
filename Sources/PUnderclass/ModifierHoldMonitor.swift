import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

enum ModifierHoldSignal: Equatable {
    case pressed
    case released
    case interrupted
    case cancelled
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

        case .interrupted, .cancelled:
            hasDeferredRelease = false
            return .emit(signal)
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
    private var requiresChordRelease = false

    mutating func update(
        flags: CGEventFlags,
        isSelecting: Bool = false
    ) -> ModifierHoldSignal? {
        if isSelecting {
            return cancel(flags: flags)
        }
        if requiresChordRelease {
            requiresChordRelease = Self.hasRequiredModifiers(flags)
            return nil
        }
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
        // Releasing Control/Shift from a larger shortcut must not start one.
        requiresChordRelease = Self.hasRequiredModifiers(flags)
        return nil
    }

    mutating func synchronize(flags: CGEventFlags) {
        isHeld = false
        requiresChordRelease = Self.hasRequiredModifiers(flags)
    }

    /// Recover a missed release without starting a hold from a state snapshot.
    mutating func reconcile(flags: CGEventFlags) -> ModifierHoldSignal? {
        if !Self.hasRequiredModifiers(flags) {
            requiresChordRelease = false
        }
        guard isHeld else { return nil }
        return update(flags: flags)
    }

    mutating func interruptForEscape() -> ModifierHoldSignal? {
        guard isHeld else { return nil }
        isHeld = false
        requiresChordRelease = true
        return .interrupted
    }

    mutating func cancel(flags: CGEventFlags) -> ModifierHoldSignal? {
        let wasHeld = isHeld
        synchronize(flags: flags)
        return wasHeld ? .cancelled : nil
    }

    mutating func reset() {
        isHeld = false
        requiresChordRelease = false
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
    private let signalHandler: SignalHandler
    private var eventLoop: ModifierHoldRunLoop?
    private var generation = UUID()

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
        guard eventLoop == nil else { return }
        guard AXIsProcessTrusted() else {
            throw PUnderclassError.audio(
                "Accessibility permission is required for the global dictation shortcut."
            )
        }
        let generation = UUID()
        self.generation = generation
        let worker = ModifierHoldEventTap { [weak self] signal in
            // No AppKit, accessibility, audio, or transcription work belongs
            // on the filtering tap's thread. Discard callbacks after shutdown.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.signalHandler(
                    signal,
                    signal == .pressed ? NSWorkspace.shared.frontmostApplication : nil
                )
            }
        }
        eventLoop = try ModifierHoldRunLoop(
            install: { try worker.start() },
            uninstall: { worker.stop() }
        )
    }

    func stop() {
        generation = UUID()
        eventLoop?.stop()
        eventLoop = nil
    }

    deinit {
        stop()
    }
}

/// Owns a run loop that never waits for the main queue. In particular, the
/// system keyboard must keep flowing while microphone/model/UI work stalls.
final class ModifierHoldRunLoop: @unchecked Sendable {
    private var runLoop: CFRunLoop!
    private var startupError: Error?
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var isStopped = false

    init(install: @escaping () throws -> Void, uninstall: @escaping () -> Void) throws {
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            do {
                try install()
            } catch {
                startupError = error
            }
            ready.signal()
            if startupError == nil {
                CFRunLoopRun()
            }
            uninstall()
            finished.signal()
        }
        thread.name = "PUnderclass.ModifierHold"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if let startupError {
            finished.wait()
            isStopped = true
            throw startupError
        }
    }

    func perform(_ action: @escaping () -> Void) {
        guard !isStopped else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, action)
        CFRunLoopWakeUp(runLoop)
    }

    func stop() {
        guard !isStopped else { return }
        perform { [runLoop] in CFRunLoopStop(runLoop) }
        finished.wait()
        isStopped = true
    }
}

/// All mutable state below belongs exclusively to ModifierHoldRunLoop.
final class ModifierHoldEventTap {
    private static let logger = Logger(
        subsystem: "com.newtypekk.punderclass",
        category: "QuickDictationHotkey"
    )
    private let signalHandler: (ModifierHoldSignal) -> Void
    private let physicalFlags: () -> CGEventFlags
    private let isMouseDown: () -> Bool
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installedRunLoop: CFRunLoop?
    private var state = ModifierHoldState()
    private var signalCoalescer = ModifierHoldSignalCoalescer()
    private var deferredReleaseTimer: Timer?
    private var releaseWatchdog: Timer?
    private var isDiagnosticHold = false
    private var isConsumingEscapeUntilChordRelease = false

    init(
        physicalFlags: @escaping () -> CGEventFlags = {
            CGEventSource.flagsState(.hidSystemState)
        },
        isMouseDown: @escaping () -> Bool = {
            CGEventSource.buttonState(.hidSystemState, button: .left)
        },
        signalHandler: @escaping (ModifierHoldSignal) -> Void
    ) {
        self.physicalFlags = physicalFlags
        self.isMouseDown = isMouseDown
        self.signalHandler = signalHandler
    }

    func start() throws {
        guard eventTap == nil else { return }
        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        // The run-loop thread owns this worker until after stop invalidates
        // the tap, so the callback does not need a self-retaining cycle.
        let reference = Unmanaged.passUnretained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierHoldEventTap>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: reference.toOpaque()
        ) else {
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
        state.synchronize(flags: physicalFlags())
        let watchdog = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.recoverMissedRelease()
        }
        releaseWatchdog = watchdog
        RunLoop.current.add(watchdog, forMode: .common)
        Self.logger.notice("event_tap_installed")
    }

    func stop() {
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource, let installedRunLoop {
            CFRunLoopRemoveSource(installedRunLoop, runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        state.reset()
        deferredReleaseTimer?.invalidate()
        deferredReleaseTimer = nil
        signalCoalescer.reset()
        isDiagnosticHold = false
        isConsumingEscapeUntilChordRelease = false
    }

    func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.logger.error("event_tap_disabled type=\(type.rawValue, privacy: .public)")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            // A timed-out tap may have missed arbitrary transitions. End the
            // capture and require a fresh chord instead of reviving stale state.
            interruptAfterTapFailure()
            return Unmanaged.passUnretained(event)
        }

        let signal: ModifierHoldSignal?
        var shouldConsumeEvent = false
        switch type {
        case .flagsChanged:
            let isDiagnostic = event.getIntegerValueField(.eventSourceUserData)
                == ModifierHoldMonitor.diagnosticEventTag
            let isSelecting = !isDiagnostic && isMouseDown()
            signal = state.update(
                flags: event.flags,
                isSelecting: isSelecting
            ) ?? (isSelecting && signalCoalescer.hasDeferredRelease ? .cancelled : nil)
            if signal == .pressed {
                isDiagnosticHold = event.getIntegerValueField(.eventSourceUserData)
                    == ModifierHoldMonitor.diagnosticEventTag
            } else if signal == .released || signal == .cancelled {
                isDiagnosticHold = false
            }
            if isSelecting || !ModifierHoldState.hasRequiredModifiers(event.flags) {
                isConsumingEscapeUntilChordRelease = false
            }
        case .leftMouseDown, .leftMouseDragged:
            signal = state.cancel(flags: event.flags)
                ?? (signalCoalescer.hasDeferredRelease ? .cancelled : nil)
            isDiagnosticHold = false
            isConsumingEscapeUntilChordRelease = false
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let eventTag = event.getIntegerValueField(.eventSourceUserData)
            signal = ModifierHoldMonitor.shouldInterruptForKeyDown(
                keyCode: keyCode,
                eventTag: eventTag,
                isDiagnosticHold: isDiagnosticHold
            ) ? state.interruptForEscape() : nil
            if signal == .interrupted {
                isDiagnosticHold = false
                isConsumingEscapeUntilChordRelease = true
            }
            shouldConsumeEvent = keyCode == ModifierHoldMonitor.escapeKeyCode
                && isConsumingEscapeUntilChordRelease
        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            signal = nil
            shouldConsumeEvent = keyCode == ModifierHoldMonitor.escapeKeyCode
                && isConsumingEscapeUntilChordRelease
        default:
            signal = nil
        }
        if let signal {
            route(
                signal,
                flags: event.flags
            )
        }
        return shouldConsumeEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func interruptAfterTapFailure() {
        let flags = physicalFlags()
        let signal = state.cancel(flags: flags)
            ?? (signalCoalescer.hasDeferredRelease ? .cancelled : nil)
        deferredReleaseTimer?.invalidate()
        deferredReleaseTimer = nil
        signalCoalescer.reset()
        isDiagnosticHold = false
        isConsumingEscapeUntilChordRelease = false
        if signal != nil {
            // Keep any captured speech available, but never paste after losing
            // track of the user's shortcut transitions.
            publish(.interrupted, flags: flags)
        }
    }

    private func recoverMissedRelease() {
        // Diagnostic holds are synthetic. Read physical device state for real
        // holds so our own Command-V events cannot look like a key release.
        guard !isDiagnosticHold else { return }
        let flags = physicalFlags()
        if !ModifierHoldState.hasRequiredModifiers(flags) {
            isConsumingEscapeUntilChordRelease = false
        }
        guard let signal = state.reconcile(flags: flags) else { return }
        Self.logger.notice("shortcut_missed_release_recovered")
        route(signal, flags: flags)
    }

    private func route(
        _ signal: ModifierHoldSignal,
        flags: CGEventFlags
    ) {
        switch signalCoalescer.receive(signal) {
        case let .emit(signal):
            deferredReleaseTimer?.invalidate()
            deferredReleaseTimer = nil
            publish(
                signal,
                flags: flags
            )

        case .deferRelease:
            deferredReleaseTimer?.invalidate()
            let timer = Timer(
                timeInterval: ModifierHoldMonitor.releaseBounceGraceSeconds,
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                self.deferredReleaseTimer = nil
                guard let signal = self.signalCoalescer.releaseDelayElapsed() else {
                    return
                }
                self.publish(signal, flags: flags)
            }
            deferredReleaseTimer = timer
            RunLoop.current.add(timer, forMode: .common)

        case .cancelDeferredRelease:
            deferredReleaseTimer?.invalidate()
            deferredReleaseTimer = nil
            Self.logger.notice("shortcut_release_bounce_coalesced")
        }
    }

    private func publish(
        _ signal: ModifierHoldSignal,
        flags: CGEventFlags
    ) {
        Self.logger.notice(
            "shortcut_signal=\(String(describing: signal), privacy: .public) flags=\(flags.rawValue, privacy: .public)"
        )
        signalHandler(signal)
    }
}

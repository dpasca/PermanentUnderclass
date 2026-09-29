import CoreGraphics
import Foundation
import XCTest
@testable import PUnderclass

final class ModifierHoldMonitorTests: XCTestCase {
    private let chord: CGEventFlags = [.maskCommand, .maskAlternate]

    func testOptionControlDoesNotStartDictation() {
        var state = ModifierHoldState()
        XCTAssertNil(state.update(flags: .maskAlternate))
        XCTAssertNil(state.update(flags: [.maskAlternate, .maskControl]))
        XCTAssertNil(state.update(flags: .maskAlternate))
        XCTAssertNil(state.update(flags: []))
        XCTAssertFalse(state.isHeld)
    }

    func testReleasingExtraModifierDoesNotTurnLargerShortcutIntoDictation() {
        var state = ModifierHoldState()
        XCTAssertNil(state.update(flags: [.maskCommand, .maskAlternate, .maskControl]))
        XCTAssertNil(state.update(flags: chord))
        XCTAssertFalse(state.isHeld)
        XCTAssertNil(state.update(flags: .maskAlternate))
        XCTAssertEqual(state.update(flags: chord), .pressed)
    }

    func testInstallingWhileChordIsDownWaitsForFreshPress() {
        var state = ModifierHoldState()
        state.synchronize(flags: chord)
        XCTAssertFalse(state.isHeld)
        XCTAssertNil(state.update(flags: chord))
        XCTAssertNil(state.update(flags: []))
        XCTAssertEqual(state.update(flags: chord), .pressed)
    }

    func testEscapeCannotRestartUntilRequiredModifierIsReleased() {
        var state = ModifierHoldState()
        XCTAssertEqual(state.update(flags: chord), .pressed)
        XCTAssertEqual(state.interruptForEscape(), .interrupted)
        XCTAssertNil(state.update(flags: [.maskCommand, .maskAlternate, .maskShift]))
        XCTAssertNil(state.update(flags: chord))
        // A watchdog snapshot can recover the release even if its event is lost.
        XCTAssertNil(state.reconcile(flags: []))
        XCTAssertEqual(state.update(flags: chord), .pressed)
    }

    func testMouseSelectionPreventsStartingAndCancelsExistingHold() {
        var state = ModifierHoldState()
        XCTAssertNil(state.update(flags: chord, isSelecting: true))
        XCTAssertNil(state.update(flags: chord))
        XCTAssertNil(state.update(flags: []))
        XCTAssertEqual(state.update(flags: chord), .pressed)
        XCTAssertEqual(state.update(flags: chord, isSelecting: true), .cancelled)
        XCTAssertNil(state.update(flags: chord))
        XCTAssertNil(state.update(flags: []))
        XCTAssertEqual(state.update(flags: chord), .pressed)
    }

    func testMouseCancellationClearsDeferredRelease() {
        var coalescer = ModifierHoldSignalCoalescer()
        XCTAssertEqual(coalescer.receive(.pressed), .emit(.pressed))
        XCTAssertEqual(coalescer.receive(.released), .deferRelease)
        XCTAssertEqual(coalescer.receive(.cancelled), .emit(.cancelled))
        XCTAssertNil(coalescer.releaseDelayElapsed())
        XCTAssertEqual(coalescer.receive(.pressed), .emit(.pressed))
    }

    func testTapPassesKeyboardAndSelectionEventsAndReleasesEscapeAfterFailure() throws {
        var flags = chord
        var signals: [ModifierHoldSignal] = []
        let tap = ModifierHoldEventTap(
            physicalFlags: { flags },
            isMouseDown: { false },
            signalHandler: { signals.append($0) }
        )
        defer { tap.stop() }
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        event.flags = chord
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        event.setIntegerValueField(.keyboardEventKeycode, value: 0)
        XCTAssertNotNil(tap.handle(type: .keyDown, event: event))
        XCTAssertNotNil(tap.handle(type: .keyUp, event: event))
        event.setIntegerValueField(.keyboardEventKeycode, value: ModifierHoldMonitor.escapeKeyCode)
        XCTAssertNil(tap.handle(type: .keyDown, event: event))
        XCTAssertEqual(signals, [.pressed, .interrupted])

        // Even with stale physical flags, a disabled tap must drop suppression.
        XCTAssertNotNil(tap.handle(type: .tapDisabledByTimeout, event: event))
        XCTAssertNotNil(tap.handle(type: .keyDown, event: event))
        XCTAssertNotNil(tap.handle(type: .keyUp, event: event))
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        XCTAssertEqual(signals, [.pressed, .interrupted])

        flags = []
        event.flags = []
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        flags = chord
        event.flags = chord
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        XCTAssertNotNil(tap.handle(type: .leftMouseDown, event: event))
        XCTAssertNotNil(tap.handle(type: .leftMouseDragged, event: event))
        XCTAssertEqual(signals, [.pressed, .interrupted, .pressed, .cancelled])
        XCTAssertNotNil(tap.handle(type: .keyDown, event: event))
        XCTAssertNotNil(tap.handle(type: .keyUp, event: event))
    }

    func testTapFailureEndsHoldWithoutPastingAndRequiresFreshPress() throws {
        var signals: [ModifierHoldSignal] = []
        let tap = ModifierHoldEventTap(
            physicalFlags: { self.chord },
            isMouseDown: { false },
            signalHandler: { signals.append($0) }
        )
        defer { tap.stop() }
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.flags = chord
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        XCTAssertNotNil(tap.handle(type: .tapDisabledByUserInput, event: event))
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        XCTAssertEqual(signals, [.pressed, .interrupted])
    }

    func testSelectionDuringReleaseGracePeriodCancelsInsteadOfTranscribing() throws {
        var isSelecting = false
        var signals: [ModifierHoldSignal] = []
        let tap = ModifierHoldEventTap(
            physicalFlags: { [] },
            isMouseDown: { isSelecting },
            signalHandler: { signals.append($0) }
        )
        defer { tap.stop() }
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.flags = chord
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        event.flags = .maskAlternate
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        XCTAssertEqual(signals, [.pressed])

        // Recover selection from physical state even if mouse-down was missed.
        isSelecting = true
        event.flags = chord
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: event))
        XCTAssertEqual(signals, [.pressed, .cancelled])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(signals, [.pressed, .cancelled])
    }

    func testEventLoopKeepsRunningWhileMainThreadIsBlockedAndStopsSynchronously() throws {
        XCTAssertTrue(Thread.isMainThread)
        let handled = DispatchSemaphore(value: 0)
        let uninstalled = DispatchSemaphore(value: 0)
        var timer: Timer?
        let loop = try ModifierHoldRunLoop(
            install: {
                XCTAssertFalse(Thread.isMainThread)
                let keepAlive = Timer(timeInterval: 60, repeats: true) { _ in }
                timer = keepAlive
                RunLoop.current.add(keepAlive, forMode: .common)
            },
            uninstall: {
                XCTAssertFalse(Thread.isMainThread)
                timer?.invalidate()
                uninstalled.signal()
            }
        )
        loop.perform {
            XCTAssertFalse(Thread.isMainThread)
            handled.signal()
        }
        // Unlike an XCTest expectation, this does not pump the main run loop.
        XCTAssertEqual(handled.wait(timeout: .now() + 2), .success)
        loop.stop()
        XCTAssertEqual(uninstalled.wait(timeout: .now()), .success)
        loop.stop()
        loop.perform { XCTFail("Work must not run after shutdown") }
    }

    func testFailedTapInstallationCleansUpAndReturnsError() {
        enum InstallationError: Error { case denied }
        let uninstalled = DispatchSemaphore(value: 0)
        XCTAssertThrowsError(try ModifierHoldRunLoop(
            install: { throw InstallationError.denied },
            uninstall: { uninstalled.signal() }
        )) { error in
            XCTAssertTrue(error is InstallationError)
        }
        XCTAssertEqual(uninstalled.wait(timeout: .now()), .success)
    }
}

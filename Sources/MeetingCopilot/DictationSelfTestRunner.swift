import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Exercises the signed app's actual Accessibility event tap, local Parakeet
/// readiness gate, and current default microphone without requiring a person to
/// repeatedly press the shortcut while debugging.
final class DictationSelfTestRunner {
    static let argument = "--dictation-self-test"
    static var isRequested: Bool {
        CommandLine.arguments.contains(argument)
    }

    private var service: HoldToDictateService?
    private var overallTimeout: DispatchWorkItem?
    private var shortcutTimeout: DispatchWorkItem?
    private var completionCheck: DispatchWorkItem?
    private var postedShortcut = false
    private var sawRecordingStart = false
    private var sawRecordingStop = false
    private var telemetry = TrackTelemetry()
    private var isVerifyingPaste = false
    private let pasteInjector = PasteInjector()
    private var pasteWindow: NSWindow?
    private var focusStealingWindow: NSWindow?
    private var isFinished = false

    func start() {
        let permissions = HoldToDictateService.currentPermissions()
        log(
            "permissions accessibility=\(permissions.canMonitorKeyboard) "
                + "microphone=\(permissions.canUseMicrophone)"
        )
        guard permissions.allGranted else {
            finish(
                success: false,
                message: "The signed app does not currently have Accessibility and Microphone access."
            )
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(success: false, message: "Timed out waiting for the dictation pipeline.")
        }
        overallTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)

        let service = HoldToDictateService(
            canRecord: { true },
            expectedLanguages: { ["en"] },
            onPhase: { [weak self] phase in
                self?.handle(phase: phase)
            },
            onPermissions: { _ in },
            onRecording: { [weak self] isRecording in
                self?.handle(recording: isRecording)
            },
            onTelemetry: { [weak self] telemetry in
                self?.telemetry = telemetry
                self?.completeIfPossible()
            },
            onResult: { [weak self] text in
                self?.log("unexpected_transcription=\(text)")
            },
            transcribesAfterRecording: false
        )
        self.service = service
        guard service.enable(requestAccess: false) else {
            finish(success: false, message: "The dictation service could not start.")
            return
        }
    }

    private func handle(phase: DictationPhase) {
        log("phase=\(phase.label)")
        if case let .failed(message) = phase {
            if sawRecordingStop {
                // This microphone probe intentionally records ambient audio,
                // which may be silence. Model recognition is covered by the
                // separate synthetic-speech integration test.
                log("post_capture_transcription=\(message)")
                return
            }
            finish(success: false, message: message)
            return
        }
        guard phase == .ready, !postedShortcut, !isFinished else { return }
        postedShortcut = true
        log("posting command+option press through the macOS session event stream")
        postShortcut(isDown: true)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.sawRecordingStart else { return }
            self.finish(
                success: false,
                message: "The event tap was installed, but it did not receive Command+Option."
            )
        }
        shortcutTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func handle(recording: Bool) {
        guard !isFinished else { return }
        log("recording=\(recording)")
        if recording {
            sawRecordingStart = true
            shortcutTimeout?.cancel()
            shortcutTimeout = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, !self.isFinished else { return }
                self.log("posting command+option release")
                self.postShortcut(isDown: false)
            }
            return
        }

        guard sawRecordingStart else { return }
        sawRecordingStop = true
        let check = DispatchWorkItem { [weak self] in
            self?.completeIfPossible(force: true)
        }
        completionCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
    }

    private func completeIfPossible(force: Bool = false) {
        guard !isFinished, sawRecordingStart, sawRecordingStop else { return }
        guard telemetry.packets > 0 else {
            if force {
                finish(
                    success: false,
                    message: "The shortcut worked, but the current microphone produced no audio packets."
                )
            }
            return
        }
        verifyPasteInjection()
    }

    private func verifyPasteInjection() {
        guard !isVerifyingPaste else { return }
        isVerifyingPaste = true

        let marker = "MeetingCopilotPasteSelfTest"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = ""
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.contentView = textView
        pasteWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak textView] in
            guard let self, !self.isFinished, let textView else { return }
            guard let target = QuickDictationPasteTarget.capture() else {
                self.finish(
                    success: false,
                    message: "Could not capture the original paste target."
                )
                return
            }

            let distractionView = NSTextView(
                frame: NSRect(x: 0, y: 0, width: 320, height: 80)
            )
            distractionView.string = ""
            let distractionWindow = NSWindow(
                contentRect: NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: 320,
                    height: 80
                ),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            distractionWindow.alphaValue = 0.01
            distractionWindow.contentView = distractionView
            self.focusStealingWindow = distractionWindow
            distractionWindow.makeKeyAndOrderFront(nil)
            distractionWindow.makeFirstResponder(distractionView)

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.1
            ) { [weak self, weak textView, weak distractionView] in
                guard
                    let self,
                    !self.isFinished,
                    let textView,
                    let distractionView
                else {
                    return
                }
                self.pasteInjector.paste(marker, into: target) { [weak self] result in
                    guard let self, !self.isFinished else { return }
                    if case let .failure(error) = result {
                        self.finish(
                            success: false,
                            message: "Targeted paste injection failed: \(error.localizedDescription)"
                        )
                        return
                    }

                    // Allow the verified paste transaction to restore the
                    // original clipboard before checking the final state.
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + 0.75
                    ) { [weak self, weak textView, weak distractionView] in
                        guard
                            let self,
                            !self.isFinished,
                            let textView,
                            let distractionView
                        else {
                            return
                        }
                        guard
                            textView.string == marker,
                            distractionView.string.isEmpty
                        else {
                            self.finish(
                                success: false,
                                message: "The paste did not return to the originally focused field."
                            )
                            return
                        }
                        self.finish(
                            success: true,
                            message: "model=ready shortcut=press+release "
                                + "microphone_packets=\(self.telemetry.packets) "
                                + "paste_target=restored"
                        )
                    }
                }
            }
        }
    }

    private func postShortcut(isDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let transitions: [(CGKeyCode, Bool, CGEventFlags)]
        if isDown {
            transitions = [
                (55, true, [.maskCommand]),
                (58, true, [.maskCommand, .maskAlternate]),
            ]
        } else {
            transitions = [
                (58, false, [.maskCommand]),
                (55, false, []),
            ]
        }

        for (keyCode, keyDown, flags) in transitions {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: keyDown
            ) else {
                finish(success: false, message: "Could not construct a diagnostic keyboard event.")
                return
            }
            event.type = .flagsChanged
            event.flags = flags
            event.setIntegerValueField(
                .eventSourceUserData,
                value: ModifierHoldMonitor.diagnosticEventTag
            )
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func finish(success: Bool, message: String) {
        guard !isFinished else { return }
        isFinished = true
        overallTimeout?.cancel()
        shortcutTimeout?.cancel()
        completionCheck?.cancel()
        overallTimeout = nil
        shortcutTimeout = nil
        completionCheck = nil

        // Never leave synthetic modifier state or an active capture behind.
        postShortcut(isDown: false)
        pasteInjector.cancel()
        pasteWindow?.orderOut(nil)
        focusStealingWindow?.orderOut(nil)
        service?.disable()
        service = nil
        log("RESULT \(success ? "PASS" : "FAIL") \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // This is a command-line-only diagnostic mode. _exit avoids
            // AppKit tearing down the temporary paste window a second time.
            _exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    private func log(_ message: String) {
        let line = "DICTATION_SELF_TEST \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

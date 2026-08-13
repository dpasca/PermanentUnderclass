import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct QuickDictationPasteVerification {
    let expectedValue: String
    let expectedSelectedRange: CFRange

    init?(
        originalValue: String,
        selectedRange: CFRange,
        insertedText: String
    ) {
        let original = originalValue as NSString
        guard
            selectedRange.location >= 0,
            selectedRange.length >= 0,
            selectedRange.location + selectedRange.length <= original.length
        else {
            return nil
        }
        expectedValue = original.replacingCharacters(
            in: NSRange(
                location: selectedRange.location,
                length: selectedRange.length
            ),
            with: insertedText
        )
        expectedSelectedRange = CFRange(
            location: selectedRange.location + (insertedText as NSString).length,
            length: 0
        )
    }

    func matches(
        currentValue: String,
        selectedRange: CFRange
    ) -> Bool {
        currentValue == expectedValue
            && selectedRange.location == expectedSelectedRange.location
            && selectedRange.length == expectedSelectedRange.length
    }
}

/// Evidence that a paste landed in a target that has no editable value/range
/// model. A terminal's `AXValue` is the visible screen rather than a field's
/// contents, so exact comparison never matches — but the screen is stable when
/// idle, which makes both "the text appeared" and "nothing happened at all"
/// reliable signals.
struct QuickDictationContentEvidence: Equatable {
    enum Outcome: Equatable {
        /// The pasted text is visible on screen.
        case inserted
        /// The screen changed but the text is not literally visible, which is
        /// what a TUI that renders a pasted-text placeholder looks like.
        case changed
        /// Nothing happened; the paste did not reach the target.
        case unchanged
    }

    /// Enough trailing characters to be unambiguous, few enough to survive the
    /// text scrolling partly out of view.
    private static let probeLength = 32
    private static let minimumProbeLength = 6

    private let probe: String
    private let originalContent: String

    init(originalValue: String, insertedText: String) {
        let originalContent = Self.normalize(originalValue)
        self.originalContent = originalContent
        // The tail is checked rather than the head: a long paste scrolls its
        // beginning off the top, but the end sits at the cursor.
        let normalizedInsert = Self.normalize(insertedText)
        let probe = String(normalizedInsert.suffix(Self.probeLength))
        // A probe already on screen — dictating the same thing twice, or
        // reading back text that is already there — would report `.inserted`
        // against an untouched screen. That is worse than having no probe at
        // all, because `.inserted` is the one outcome trusted enough to hand
        // the clipboard back immediately.
        self.probe = probe.count >= Self.minimumProbeLength
            && !originalContent.contains(probe)
            ? probe
            : ""
    }

    func evaluate(currentValue: String) -> Outcome {
        let current = Self.normalize(currentValue)
        if !probe.isEmpty, current.contains(probe) {
            return .inserted
        }
        return current == originalContent ? .unchanged : .changed
    }

    /// Terminals wrap lines mid-token, so whitespace cannot be compared.
    private static func normalize(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}

enum QuickDictationPasteVerificationPolicy {
    static let iTermBundleIdentifier = "com.googlecode.iterm2"

    static func shouldVerify(bundleIdentifier: String?) -> Bool {
        // iTerm exposes terminal contents through Accessibility, but not as
        // the editable value/range model used by ordinary text fields. The
        // paste succeeds while exact value comparison consistently fails, so
        // those targets are checked with content evidence instead.
        bundleIdentifier != iTermBundleIdentifier
    }

    static func unverifiedDeliveryDelaySeconds(
        bundleIdentifier: String?
    ) -> TimeInterval {
        bundleIdentifier == iTermBundleIdentifier ? 0.25 : 2
    }
}

enum QuickDictationClipboardRestorationPolicy {
    /// How long the dictation has to stay on the clipboard after the paste
    /// keystroke before the previous contents may be put back.
    ///
    /// macOS never reports "the target read the pasteboard", and the keystroke
    /// is delivered asynchronously, so evidence that *something* happened in
    /// the target is not evidence that it has read the clipboard yet. Restoring
    /// inside that window makes the target paste the user's previous clipboard
    /// instead of their dictation.
    ///
    /// There is no signal to wait on, so this is a heuristic bound on how long
    /// a target can take to service a posted Cmd+V. It is set well past what a
    /// busy app plausibly needs; the only cost of overshooting is that the
    /// user's clipboard comes back a beat later. It may safely exceed
    /// `PasteInjector`'s serialization delay, because a paste that starts
    /// during the dwell inherits the pending restore rather than racing it.
    static let minimumDwellSeconds: TimeInterval = 1.5

    static func shouldRestore(
        insertedChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        insertedChangeCount == currentChangeCount
    }

    /// Delay before restoring, measured from the paste keystroke. Seeing the
    /// text itself land in the target proves the clipboard was already read,
    /// which is the one case that needs no dwell.
    static func restoreDelaySeconds(
        elapsedSincePaste: TimeInterval,
        isDeliveryProven: Bool
    ) -> TimeInterval {
        guard !isDeliveryProven else { return 0 }
        return max(0, minimumDwellSeconds - elapsedSincePaste)
    }
}

/// The application, window, and keyboard-focused control that were active when
/// a Quick Dictation recording began.
final class QuickDictationPasteTarget {
    private let runningApplication: NSRunningApplication
    private let accessibilityApplication: AXUIElement
    private let window: AXUIElement?
    private let focusedElement: AXUIElement?

    var applicationName: String {
        runningApplication.localizedName
            ?? runningApplication.bundleIdentifier
            ?? "the original application"
    }

    var applicationBundleIdentifier: String? {
        runningApplication.bundleIdentifier
    }

    var isAvailable: Bool {
        !runningApplication.isTerminated
    }

    /// Whether this target is still the app the user is working in. A long
    /// transcription gives the user time to switch away, and pasting into
    /// whatever they moved to — or yanking focus back — is worse than not
    /// pasting at all.
    var isStillFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == runningApplication.processIdentifier
    }

    private init(
        runningApplication: NSRunningApplication,
        accessibilityApplication: AXUIElement,
        window: AXUIElement?,
        focusedElement: AXUIElement?
    ) {
        self.runningApplication = runningApplication
        self.accessibilityApplication = accessibilityApplication
        self.window = window
        self.focusedElement = focusedElement
    }

    static func capture(
        initialApplication: NSRunningApplication? = nil
    ) -> QuickDictationPasteTarget? {
        let systemWideElement = AXUIElementCreateSystemWide()
        let accessibilityApplication: AXUIElement
        let runningApplication: NSRunningApplication

        if let initialApplication {
            runningApplication = initialApplication
            accessibilityApplication = AXUIElementCreateApplication(
                initialApplication.processIdentifier
            )
        } else if let focusedApplication = copyElement(
            attribute: kAXFocusedApplicationAttribute as CFString,
            from: systemWideElement
        ) {
            var processIdentifier: pid_t = 0
            guard
                AXUIElementGetPid(focusedApplication, &processIdentifier) == .success,
                let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                )
            else {
                return nil
            }
            accessibilityApplication = focusedApplication
            runningApplication = application
        } else {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            runningApplication = application
            accessibilityApplication = AXUIElementCreateApplication(
                application.processIdentifier
            )
        }

        return QuickDictationPasteTarget(
            runningApplication: runningApplication,
            accessibilityApplication: accessibilityApplication,
            window: copyElement(
                attribute: kAXFocusedWindowAttribute as CFString,
                from: accessibilityApplication
            ),
            focusedElement: copyElement(
                attribute: kAXFocusedUIElementAttribute as CFString,
                from: accessibilityApplication
            )
        )
    }

    func makePasteVerification(
        inserting text: String
    ) -> QuickDictationPasteVerification? {
        guard
            QuickDictationPasteVerificationPolicy.shouldVerify(
                bundleIdentifier: applicationBundleIdentifier
            ),
            let focusedElement,
            let originalValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            ),
            let selectedRange = Self.copyRange(
                attribute: kAXSelectedTextRangeAttribute as CFString,
                from: focusedElement
            )
        else {
            return nil
        }
        return QuickDictationPasteVerification(
            originalValue: originalValue,
            selectedRange: selectedRange,
            insertedText: text
        )
    }

    /// Snapshots the visible content of a target that cannot be verified
    /// through the editable value/range model.
    func makeContentEvidence(
        inserting text: String
    ) -> QuickDictationContentEvidence? {
        guard
            let focusedElement,
            let originalValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            )
        else {
            return nil
        }
        return QuickDictationContentEvidence(
            originalValue: originalValue,
            insertedText: text
        )
    }

    func evaluateContentEvidence(
        _ evidence: QuickDictationContentEvidence
    ) -> QuickDictationContentEvidence.Outcome? {
        guard
            let focusedElement,
            let currentValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            )
        else {
            return nil
        }
        return evidence.evaluate(currentValue: currentValue)
    }

    func verifyPaste(_ verification: QuickDictationPasteVerification) -> Bool {
        guard
            let focusedElement,
            let currentValue = Self.copyString(
                attribute: kAXValueAttribute as CFString,
                from: focusedElement
            ),
            let selectedRange = Self.copyRange(
                attribute: kAXSelectedTextRangeAttribute as CFString,
                from: focusedElement
            )
        else {
            return false
        }
        return verification.matches(
            currentValue: currentValue,
            selectedRange: selectedRange
        )
    }

    /// Requests activation and reasserts the exact window and control. The
    /// activation itself can complete on a later run-loop turn, so callers may
    /// need to retry this method briefly before posting keyboard events.
    @discardableResult
    func restoreFocus() -> Bool {
        guard isAvailable else { return false }

        _ = runningApplication.activate(options: [])
        _ = AXUIElementSetAttributeValue(
            accessibilityApplication,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        if let window {
            _ = AXUIElementSetAttributeValue(
                accessibilityApplication,
                kAXMainWindowAttribute as CFString,
                window
            )
            _ = AXUIElementSetAttributeValue(
                accessibilityApplication,
                kAXFocusedWindowAttribute as CFString,
                window
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if let focusedElement {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        return hasFocus
    }

    private var hasFocus: Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        guard
            let currentApplication = Self.copyElement(
                attribute: kAXFocusedApplicationAttribute as CFString,
                from: systemWideElement
            )
        else {
            return false
        }
        var currentProcessIdentifier: pid_t = 0
        guard
            AXUIElementGetPid(
                currentApplication,
                &currentProcessIdentifier
            ) == .success,
            currentProcessIdentifier == runningApplication.processIdentifier
        else {
            return false
        }

        if let window {
            guard
                let currentWindow = Self.copyElement(
                    attribute: kAXFocusedWindowAttribute as CFString,
                    from: accessibilityApplication
                ),
                CFEqual(currentWindow, window)
            else {
                return false
            }
        }
        if let focusedElement {
            guard
                let currentElement = Self.copyElement(
                    attribute: kAXFocusedUIElementAttribute as CFString,
                    from: accessibilityApplication
                ),
                CFEqual(currentElement, focusedElement)
            else {
                return false
            }
        }
        return true
    }

    private static func copyElement(
        attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func copyString(
        attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value
        else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        return (value as? NSAttributedString)?.string
    }

    private static func copyRange(
        attribute: CFString,
        from element: AXUIElement
    ) -> CFRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let accessibilityValue = value as! AXValue
        guard AXValueGetType(accessibilityValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(accessibilityValue, .cfRange, &range) else {
            return nil
        }
        return range
    }
}

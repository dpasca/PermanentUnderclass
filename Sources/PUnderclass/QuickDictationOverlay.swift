import AppKit
import SwiftUI

struct QuickDictationResultPresentation: Equatable {
    let text: String
    var delivery: QuickDictationDeliveryOutcome
}

enum QuickDictationPreviewContent: Equatable {
    case hidden
    case listening
    case transcribing
    case result(QuickDictationResultPresentation)
    case failure(String)

    /// True while the user still has to act on the result, which is what keeps
    /// the overlay on screen and clickable instead of auto-dismissing.
    var needsAcknowledgement: Bool {
        guard case let .result(presentation) = self else { return false }
        return !presentation.delivery.isResolved
            && presentation.delivery != .delivering
    }
}

enum QuickDictationBackgroundContent: Equatable {
    case transcribing
    case result(String)
}

struct QuickDictationPreviewState: Equatable {
    private(set) var content: QuickDictationPreviewContent = .hidden
    private(set) var backgroundContent: QuickDictationBackgroundContent?

    var isVisible: Bool {
        content != .hidden
    }

    mutating func handle(phase: DictationPhase) {
        let previousContent = content
        switch phase {
        case .recording:
            content = .listening
            if previousContent == .transcribing {
                backgroundContent = .transcribing
            }
        case .transcribing:
            content = .transcribing
            backgroundContent = nil
        case let .failed(message):
            if isVisible {
                content = .failure(message)
                backgroundContent = nil
            }
        case .ready:
            backgroundContent = nil
            if case .result = content {
                return
            }
            content = .hidden
        case .off, .needsPermission, .preparing:
            content = .hidden
            backgroundContent = nil
        }
    }

    mutating func show(result: String) {
        if content == .listening {
            backgroundContent = .result(result)
            return
        }
        content = .result(
            QuickDictationResultPresentation(
                text: result,
                delivery: .delivering
            )
        )
    }

    /// Applies the delivery outcome to a result that is already on screen. The
    /// transcript appears as soon as it exists; whether it landed is only known
    /// once the paste has been attempted.
    mutating func resolve(delivery: QuickDictationDeliveryOutcome) {
        guard case let .result(presentation) = content else { return }
        content = .result(
            QuickDictationResultPresentation(
                text: presentation.text,
                delivery: delivery
            )
        )
    }

    mutating func hideBackground() {
        backgroundContent = nil
    }

    mutating func hide() {
        content = .hidden
        backgroundContent = nil
    }
}

private final class QuickDictationOverlayModel: ObservableObject {
    @Published var content: QuickDictationPreviewContent = .hidden
    @Published var backgroundContent: QuickDictationBackgroundContent?
    @Published var waveform: [Float] = Array(repeating: 0, count: 180)
    @Published var partialTranscript = ""
    @Published var microphoneName = "System default microphone"
    @Published var engineName = ""
    @Published var engineRunsLocally = true
    @Published var progress: DictationTranscriptionProgress?
    var onCopy: () -> Void = {}
    var onDismiss: () -> Void = {}
}

private struct QuickDictationOverlayView: View {
    @ObservedObject var model: QuickDictationOverlayModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if let backgroundContent = model.backgroundContent {
                backgroundCard(backgroundContent)
            }
            primaryCard
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quick Dictation preview")
        .accessibilityValue(accessibilityValue)
    }

    private var primaryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 34, height: 34)
                .background(accentColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 12)
                    if model.content == .listening {
                        Text("Release ⌘ + ⌥ to transcribe")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                // Which microphone is heard and which model is doing the work
                // are both worth knowing at a glance, and stay visible through
                // transcription rather than only while recording.
                if model.content == .listening || model.content == .transcribing {
                    HStack(spacing: 9) {
                        if model.content == .listening {
                            Label {
                                Text(model.microphoneName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "mic.fill")
                            }
                        }
                        if !model.engineName.isEmpty {
                            Label {
                                Text(model.engineName)
                                    .lineLimit(1)
                            } icon: {
                                Image(
                                    systemName: model.engineRunsLocally
                                        ? "desktopcomputer"
                                        : "cloud"
                                )
                            }
                            .foregroundStyle(
                                model.engineRunsLocally ? Color.green : Color.blue
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Microphone and model")
                    .accessibilityValue(
                        "\(model.microphoneName), \(model.engineName)"
                    )
                }

                content
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .opacity(0.72)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    private func backgroundCard(
        _ content: QuickDictationBackgroundContent
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: backgroundSymbolName(content))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(backgroundAccentColor(content))
                .frame(width: 30, height: 30)
                .background(
                    backgroundAccentColor(content).opacity(0.14),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(backgroundTitle(content))
                    .font(.system(size: 12, weight: .semibold))
                backgroundBody(content)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(0.72)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }

    @ViewBuilder
    private func backgroundBody(
        _ content: QuickDictationBackgroundContent
    ) -> some View {
        switch content {
        case .transcribing:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Finishing in the background…")
                    .foregroundStyle(.secondary)
            }
        case let .result(text):
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func backgroundTitle(
        _ content: QuickDictationBackgroundContent
    ) -> String {
        switch content {
        case .transcribing:
            "Previous dictation · Transcribing…"
        case .result:
            "Previous dictation completed"
        }
    }

    private func backgroundSymbolName(
        _ content: QuickDictationBackgroundContent
    ) -> String {
        switch content {
        case .transcribing:
            "text.bubble.fill"
        case .result:
            "checkmark"
        }
    }

    private func backgroundAccentColor(
        _ content: QuickDictationBackgroundContent
    ) -> Color {
        switch content {
        case .transcribing:
            .orange
        case .result:
            .green
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .hidden:
            EmptyView()
        case .listening:
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    model.partialTranscript.isEmpty
                        ? "Speak to see a live text preview…"
                        : model.partialTranscript
                )
                .font(.system(size: 14, weight: model.partialTranscript.isEmpty ? .regular : .medium))
                .foregroundStyle(model.partialTranscript.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)

                WaveformView(
                    samples: model.waveform,
                    color: accentColor,
                    normalization: .adaptive
                )
                .frame(height: 19)
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let fraction = model.progress?.fraction {
                        ProgressView(value: fraction)
                            .controlSize(.small)
                            .frame(width: 90)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        model.partialTranscript.isEmpty
                            ? (model.progress?.label ?? "Finishing the transcription…")
                            : model.partialTranscript
                    )
                    .font(.system(size: 14, weight: model.partialTranscript.isEmpty ? .regular : .medium))
                    .foregroundStyle(model.partialTranscript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.head)
                }
                // With live text on screen the status line still has to say what
                // the app is waiting on, otherwise a long tail looks like a hang.
                if !model.partialTranscript.isEmpty, let progress = model.progress {
                    Text(progress.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        case let .result(presentation):
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.text)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.head)
                if let detail = presentation.delivery.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Button("Copy") { model.onCopy() }
                        Button("Dismiss") { model.onDismiss() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
        case let .failure(message):
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var title: String {
        switch model.content {
        case .hidden:
            "Quick Dictation"
        case .listening:
            "Listening…"
        case .transcribing:
            model.progress?.label ?? "Transcribing…"
        case let .result(presentation):
            presentation.delivery.title
        case .failure:
            "Dictation failed"
        }
    }

    private var symbolName: String {
        switch model.content {
        case .hidden, .listening:
            "mic.fill"
        case .transcribing:
            "text.bubble.fill"
        case let .result(presentation):
            presentation.delivery.isResolved
                || presentation.delivery == .delivering
                ? "checkmark"
                : "exclamationmark.triangle.fill"
        case .failure:
            "exclamationmark"
        }
    }

    private var accentColor: Color {
        switch model.content {
        case .hidden, .listening:
            .red
        case .transcribing:
            .orange
        case let .result(presentation):
            presentation.delivery.isResolved
                || presentation.delivery == .delivering
                ? .green
                : .orange
        case .failure:
            .orange
        }
    }

    private var accessibilityValue: String {
        switch model.content {
        case .hidden:
            return "Hidden"
        case .listening:
            let status = model.partialTranscript.isEmpty
                ? "Listening. Release Command and Option to transcribe."
                : "Listening. Live transcript: \(model.partialTranscript)"
            return "\(status) Microphone: \(model.microphoneName)."
        case .transcribing:
            let status = model.progress?.label ?? "Transcribing the recording."
            return model.partialTranscript.isEmpty
                ? status
                : "\(status) Live transcript: \(model.partialTranscript)"
        case let .result(presentation):
            guard let detail = presentation.delivery.detail else {
                return presentation.text
            }
            return "\(presentation.text). \(detail)"
        case let .failure(message):
            return message
        }
    }
}

private final class QuickDictationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Presents dictation feedback without activating PermanentUnderclass or taking focus
/// away from the application that will receive the pasted text.
final class QuickDictationOverlayController {
    private let model = QuickDictationOverlayModel()
    private var state = QuickDictationPreviewState()
    private var dismissWorkItem: DispatchWorkItem?
    private var backgroundDismissWorkItem: DispatchWorkItem?
    private var headlessModeObserver: NSObjectProtocol?
    private var isEnabled = true
    private var isSuppressed = false
    private var visibilityGeneration = UUID()

    init() {
        model.onCopy = { [weak self] in
            self?.copyResultToClipboard()
        }
        model.onDismiss = { [weak self] in
            self?.dismissImmediately()
        }
        headlessModeObserver = NotificationCenter.default.addObserver(
            forName: .headlessModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isHeadless = HeadlessModeNotification.isHeadless(
                notification
            ) else { return }
            self?.setSuppressed(isHeadless)
        }
    }

    private lazy var panel: NSPanel = {
        let panel = QuickDictationOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 210),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let hostingView = NSHostingView(
            rootView: QuickDictationOverlayView(model: model)
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }()

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled else { return }
        dismissImmediately()
    }

    private func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        guard suppressed else { return }
        dismissImmediately()
    }

    private func dismissImmediately() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        backgroundDismissWorkItem?.cancel()
        backgroundDismissWorkItem = nil
        state.hide()
        model.content = .hidden
        model.backgroundContent = nil
        model.progress = nil
        setInteractive(false)
        panel.orderOut(nil)
    }

    func handle(phase: DictationPhase) {
        guard isEnabled, !isSuppressed else { return }
        let previousContent = state.content
        state.handle(phase: phase)
        model.content = state.content
        model.backgroundContent = state.backgroundContent

        switch state.content {
        case .hidden:
            cancelBackgroundDismissal()
            setInteractive(false)
            hide()
        case .listening:
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            setInteractive(false)
            if state.backgroundContent == .transcribing {
                cancelBackgroundDismissal()
            }
            if previousContent != .listening {
                model.waveform = Array(repeating: 0, count: 180)
                model.partialTranscript = ""
                model.progress = nil
            }
            present()
        case .transcribing:
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            cancelBackgroundDismissal()
            present()
        case .result:
            present()
        case .failure:
            cancelBackgroundDismissal()
            present()
            dismiss(after: 4)
        }
    }

    func update(telemetry: TrackTelemetry) {
        guard
            isEnabled,
            !isSuppressed,
            state.content == .listening
        else { return }
        model.waveform = telemetry.waveform
    }

    func update(partialTranscript: String) {
        guard isEnabled, !isSuppressed else { return }
        switch state.content {
        case .listening, .transcribing:
            model.partialTranscript = partialTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .hidden, .result, .failure:
            break
        }
    }

    func update(progress: DictationTranscriptionProgress?) {
        guard isEnabled, !isSuppressed else { return }
        model.progress = progress
    }

    /// The model doing the work, so the overlay answers "what is listening"
    /// without opening settings.
    func update(engine: TranscriptRefinementEngine) {
        model.engineName = engine.shortLabel
        model.engineRunsLocally = !engine.isCloud
    }

    func update(microphoneName: String) {
        let trimmedName = microphoneName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        model.microphoneName = trimmedName.isEmpty
            ? "Unknown microphone"
            : trimmedName
    }

    func show(result: String) {
        guard isEnabled, !isSuppressed else { return }
        let isBackgroundResult = state.content == .listening
        state.show(result: result)
        model.content = state.content
        model.backgroundContent = state.backgroundContent
        model.progress = nil
        if isBackgroundResult {
            present()
            dismissBackground(after: 1.6)
            return
        }
        model.partialTranscript = result
        present()
        // Dismissal waits for the delivery outcome: a result that never
        // reached its destination must not disappear on a timer.
    }

    /// Reports whether the text actually landed. A confirmed paste dismisses
    /// the overlay; anything else keeps it on screen and clickable so the user
    /// can recover the text.
    func resolve(delivery: QuickDictationDeliveryOutcome) {
        guard isEnabled, !isSuppressed else { return }
        state.resolve(delivery: delivery)
        model.content = state.content
        guard case .result = state.content else { return }
        present()
        if state.content.needsAcknowledgement {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            setInteractive(true)
        } else if delivery != .delivering {
            dismiss(after: 1.6)
        }
    }

    private func copyResultToClipboard() {
        guard case let .result(presentation) = state.content else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(presentation.text, forType: .string)
    }

    /// The overlay is normally click-through so it never interrupts typing. It
    /// only accepts the mouse while it is offering recovery actions.
    private func setInteractive(_ interactive: Bool) {
        panel.ignoresMouseEvents = !interactive
    }

    private func present() {
        visibilityGeneration = UUID()
        positionPanel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard panel.isVisible else { return }
        let generation = UUID()
        visibilityGeneration = generation
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self else { return }
                guard self.visibilityGeneration == generation else {
                    if
                        self.isEnabled,
                        !self.isSuppressed,
                        self.state.isVisible
                    {
                        self.panel.alphaValue = 1
                        self.panel.orderFrontRegardless()
                    }
                    return
                }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        )
    }

    private func dismiss(after delay: TimeInterval) {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.hide()
            self.model.content = .hidden
            self.model.backgroundContent = nil
            self.hide()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func dismissBackground(after delay: TimeInterval) {
        backgroundDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backgroundDismissWorkItem = nil
            self.state.hideBackground()
            self.model.backgroundContent = nil
        }
        backgroundDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelBackgroundDismissal() {
        backgroundDismissWorkItem?.cancel()
        backgroundDismissWorkItem = nil
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let width = min(500, max(360, visibleFrame.width - 48))
        let size = NSSize(width: width, height: 210)
        let origin = NSPoint(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + 24
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    deinit {
        if let headlessModeObserver {
            NotificationCenter.default.removeObserver(headlessModeObserver)
        }
        dismissWorkItem?.cancel()
        backgroundDismissWorkItem?.cancel()
        panel.orderOut(nil)
    }
}

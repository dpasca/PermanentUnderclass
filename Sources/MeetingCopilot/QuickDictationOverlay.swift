import AppKit
import SwiftUI

enum QuickDictationPreviewContent: Equatable {
    case hidden
    case listening
    case transcribing
    case result(String)
    case failure(String)
}

struct QuickDictationPreviewState: Equatable {
    private(set) var content: QuickDictationPreviewContent = .hidden

    var isVisible: Bool {
        content != .hidden
    }

    mutating func handle(phase: DictationPhase) {
        switch phase {
        case .recording:
            content = .listening
        case .transcribing:
            content = .transcribing
        case let .failed(message):
            if isVisible {
                content = .failure(message)
            }
        case .ready:
            if case .result = content {
                return
            }
            content = .hidden
        case .off, .needsPermission, .preparing:
            content = .hidden
        }
    }

    mutating func show(result: String) {
        content = .result(result)
    }

    mutating func hide() {
        content = .hidden
    }
}

private final class QuickDictationOverlayModel: ObservableObject {
    @Published var content: QuickDictationPreviewContent = .hidden
    @Published var waveform: [Float] = Array(repeating: 0, count: 180)
    @Published var partialTranscript = ""
}

private struct QuickDictationOverlayView: View {
    @ObservedObject var model: QuickDictationOverlayModel

    var body: some View {
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
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quick Dictation preview")
        .accessibilityValue(accessibilityValue)
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
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    model.partialTranscript.isEmpty
                        ? "Finishing the transcription…"
                        : model.partialTranscript
                )
                .font(.system(size: 14, weight: model.partialTranscript.isEmpty ? .regular : .medium))
                .foregroundStyle(model.partialTranscript.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.head)
            }
        case let .result(text):
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)
                .truncationMode(.head)
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
            "Transcribing…"
        case .result:
            "Dictated text"
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
        case .result:
            "checkmark"
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
        case .result:
            .green
        case .failure:
            .orange
        }
    }

    private var accessibilityValue: String {
        switch model.content {
        case .hidden:
            "Hidden"
        case .listening:
            model.partialTranscript.isEmpty
                ? "Listening. Release Command and Option to transcribe."
                : "Listening. Live transcript: \(model.partialTranscript)"
        case .transcribing:
            model.partialTranscript.isEmpty
                ? "Transcribing the recording."
                : "Finishing transcription. Live transcript: \(model.partialTranscript)"
        case let .result(text):
            text
        case let .failure(message):
            message
        }
    }
}

private final class QuickDictationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Presents dictation feedback without activating PUnderclass or taking focus
/// away from the application that will receive the pasted text.
final class QuickDictationOverlayController {
    private let model = QuickDictationOverlayModel()
    private var state = QuickDictationPreviewState()
    private var dismissWorkItem: DispatchWorkItem?
    private var isEnabled = true
    private var visibilityGeneration = UUID()

    private lazy var panel: NSPanel = {
        let panel = QuickDictationOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
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
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        state.hide()
        model.content = .hidden
        panel.orderOut(nil)
    }

    func handle(phase: DictationPhase) {
        guard isEnabled else { return }
        let previousContent = state.content
        state.handle(phase: phase)
        model.content = state.content

        switch state.content {
        case .hidden:
            hide()
        case .listening:
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            if previousContent != .listening {
                model.waveform = Array(repeating: 0, count: 180)
                model.partialTranscript = ""
            }
            present()
        case .transcribing:
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            present()
        case .result:
            present()
        case .failure:
            present()
            dismiss(after: 4)
        }
    }

    func update(telemetry: TrackTelemetry) {
        guard isEnabled, state.content == .listening else { return }
        model.waveform = telemetry.waveform
    }

    func update(partialTranscript: String) {
        guard isEnabled else { return }
        switch state.content {
        case .listening, .transcribing:
            model.partialTranscript = partialTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .hidden, .result, .failure:
            break
        }
    }

    func show(result: String) {
        guard isEnabled else { return }
        state.show(result: result)
        model.content = state.content
        model.partialTranscript = result
        present()
        dismiss(after: 1.6)
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
                    if self.isEnabled, self.state.isVisible {
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
            self.hide()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let width = min(500, max(360, visibleFrame.width - 48))
        let size = NSSize(width: width, height: 120)
        let origin = NSPoint(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + 24
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    deinit {
        dismissWorkItem?.cancel()
        panel.orderOut(nil)
    }
}

import SwiftUI

struct QuickDictationControlPanel: View {
    @ObservedObject var controller: MeetingController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Global shortcut", systemImage: "command")
                    .font(.headline)
                Circle()
                    .fill(phaseColor)
                    .frame(width: 8, height: 8)
                Text(controller.dictationPhase.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if controller.isDictating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text("Hold ⌘ + ⌥")
                    .font(.callout.monospaced().weight(.semibold))
                Button(
                    controller.dictationPermissions.allGranted
                        ? "Check Access"
                        : "Grant Access",
                    action: controller.requestDictationPermissions
                )
                Button("Settings…") {
                    controller.requestSettings(.dictation)
                    openSettings()
                }
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { controller.dictationEnabled },
                        set: controller.setDictationEnabled
                    )
                )
                .toggleStyle(.switch)
                .fixedSize()
            }

            if controller.dictationEnabled {
                HStack(spacing: 12) {
                    Label(controller.microphoneName, systemImage: "mic.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)

                    WaveformView(
                        samples: controller.dictationTelemetry.waveform,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(height: 32)

                    LevelBar(
                        label: "RMS",
                        value: controller.dictationTelemetry.rms,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(width: 135)
                    LevelBar(
                        label: "PEAK",
                        value: controller.dictationTelemetry.peak,
                        color: controller.isDictating ? .red : .secondary
                    )
                    .frame(width: 135)
                    Text("\(controller.dictationTelemetry.packets) packets")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }

            guidance
        }
        .padding(12)
        .background(
            controller.isDictating
                ? Color.red.opacity(0.10)
                : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    controller.isDictating
                        ? Color.red.opacity(0.75)
                        : Color.secondary.opacity(0.25),
                    lineWidth: controller.isDictating ? 2 : 1
                )
        }
    }

    @ViewBuilder
    private var guidance: some View {
        if let detail = controller.dictationPhase.detail {
            Text(detail)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        } else if !controller.dictationPermissions.allGranted {
            Text(
                "\(controller.dictationPermissions.detail) Grant access in System Settings, then quit and reopen PUnderclass."
            )
            .foregroundStyle(.secondary)
        } else if !controller.lastDictation.isEmpty {
            Text("Last: \(controller.lastDictation)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        } else {
            Text(
                controller.refinementEngine.isCloud
                    ? "Hold both keys while you speak, then let go. The text is typed back into wherever you were working."
                    : "Hold both keys while you speak, then let go. Everything is transcribed on this Mac \u{2014} no account needed."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var phaseColor: Color {
        switch controller.dictationPhase {
        case .off:
            .secondary
        case .needsPermission, .preparing, .transcribing:
            .orange
        case .ready:
            .green
        case .recording:
            .red
        case .failed:
            .orange
        }
    }
}

struct QuickDictationHistoryView: View {
    @ObservedObject var controller: MeetingController
    @State private var copiedEntryID: UUID?
    @State private var isConfirmingEraseAll = false
    @State private var recoveryPendingDeletion: QuickDictationRecoveryEntry?

    var body: some View {
        VStack(spacing: 0) {
            header

            QuickDictationControlPanel(controller: controller)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            if !controller.recoverableDictations.isEmpty {
                recoveryPanel
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }

            if let error = controller.errorMessage {
                errorBanner(error)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }

            historyHeader
            Divider()

            if controller.quickDictationHistory.isEmpty {
                ContentUnavailableView(
                    "No quick dictations yet",
                    systemImage: "mic.badge.plus",
                    description: Text(
                        "Completed quick dictations will appear here so you can copy them again later."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.quickDictationHistory) { entry in
                    historyRow(entry)
                        .contextMenu {
                            Button {
                                copy(entry)
                            } label: {
                                Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                controller.deleteQuickDictation(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.inset)
            }

            Divider()
            Text(
                "Final text is saved locally until erased. Audio is retained only while a dictation is pending or recoverable, then removed after its text is safely saved or when you explicitly delete it."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .alert(
            "Erase all quick dictations?",
            isPresented: $isConfirmingEraseAll
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Erase All", role: .destructive) {
                controller.deleteAllQuickDictations()
            }
        } message: {
            Text("This permanently removes every saved quick dictation from this Mac.")
        }
        .confirmationDialog(
            "Delete retained recording?",
            isPresented: Binding(
                get: { recoveryPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        recoveryPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) {
                recoveryPendingDeletion = nil
            }
            Button("Delete Recording", role: .destructive) {
                if let recoveryPendingDeletion {
                    controller.deleteQuickDictation(recoveryPendingDeletion)
                }
                recoveryPendingDeletion = nil
            }
        } message: {
            Text(
                "This permanently removes the retained WAV. It cannot be retried after deletion."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Quick Dictation", systemImage: "mic.badge.plus")
                    .font(.system(size: 24, weight: .semibold))
                Text("Dictate into any app with the global shortcut, then revisit the text here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var historyHeader: some View {
        HStack(spacing: 10) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text(historyCountDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                isConfirmingEraseAll = true
            } label: {
                Label("Erase All", systemImage: "trash")
            }
            .disabled(controller.quickDictationHistory.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var recoveryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Recovery", systemImage: "waveform.badge.exclamationmark")
                    .font(.headline)
                Text("\(controller.recoverableDictations.count) retained")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Pick a transcription model in Settings, then retry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(controller.recoverableDictations) { recovery in
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            recovery.createdAt.formatted(
                                date: .abbreviated,
                                time: .standard
                            )
                        )
                        .font(.caption.monospacedDigit().weight(.medium))
                        Text(
                            "\(recoveryDuration(recovery)) recording · "
                                + "\(recovery.attemptCount) failed attempt"
                                + (recovery.attemptCount == 1 ? "" : "s")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(
                            recovery.lastError
                                ?? "Safely retained while transcription is pending."
                        )
                        .font(.callout)
                        .foregroundStyle(
                            recovery.lastError == nil ? Color.secondary : Color.orange
                        )
                        .lineLimit(3)
                        .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Retry") {
                        controller.retryQuickDictation(recovery)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isDictationBusy)

                    Button {
                        controller.revealQuickDictation(recovery)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal the retained WAV recording in Finder")
                    .accessibilityLabel("Reveal retained dictation recording")

                    Button(role: .destructive) {
                        recoveryPendingDeletion = recovery
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.isDictationBusy)
                    .help("Permanently delete this retained recording")
                    .accessibilityLabel("Delete retained dictation recording")
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private func recoveryDuration(
        _ recovery: QuickDictationRecoveryEntry
    ) -> String {
        let seconds = max(1, Int(recovery.audioDurationSeconds.rounded()))
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func historyRow(_ entry: QuickDictationHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(
                    entry.createdAt.formatted(
                        date: .abbreviated,
                        time: .standard
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copy(entry)
            } label: {
                Label(
                    copiedEntryID == entry.id ? "Copied" : "Copy",
                    systemImage: copiedEntryID == entry.id
                        ? "checkmark"
                        : "doc.on.doc"
                )
                .frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Copy quick dictation to clipboard")

            Button(role: .destructive) {
                controller.deleteQuickDictation(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this quick dictation")
            .accessibilityLabel("Delete quick dictation")
        }
        .padding(.vertical, 8)
    }

    private func copy(_ entry: QuickDictationHistoryEntry) {
        guard controller.copyQuickDictationToClipboard(entry) else { return }
        copiedEntryID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                controller.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var historyCountDescription: String {
        let count = controller.quickDictationHistory.count
        return count == 1 ? "1 saved dictation" : "\(count) saved dictations"
    }
}

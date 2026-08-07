import SwiftUI

struct TranscriptionStageCard: View {
    let stage: String
    let modelName: String
    let role: String
    let detail: String
    let badge: String
    let systemImage: String
    let color: Color
    var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(stage)
                    .font(.caption2.bold())
                    .foregroundStyle(color)
                Spacer(minLength: 6)
                Text(badge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isEnabled ? color : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        (isEnabled ? color : Color.secondary).opacity(0.10),
                        in: Capsule()
                    )
            }

            Label {
                Text(modelName)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(isEnabled ? color : Color.secondary)
            }

            Text(role)
                .font(.callout.weight(.medium))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .lineLimit(2)

            if !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isEnabled ? color : Color.secondary).opacity(0.055),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    (isEnabled ? color : Color.secondary).opacity(0.22),
                    lineWidth: 1
                )
        }
        .opacity(isEnabled ? 1 : 0.68)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage), \(modelName), \(role)")
    }
}

struct TranscriptionPipelineConnector: View {
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "arrow.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .frame(width: 48)
        .accessibilityHidden(true)
    }
}

struct QuickDictationPreviewControl: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Screen preview (optional stage)")
                    .font(.callout.weight(.semibold))
                Text(
                    "While held, periodically runs \(controller.refinementEngine.title) to update the floating waveform and text. Cloud preview uses its own connection so it cannot hold up the final pass."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("Enable preview stage", isOn: previewEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
        .help(
            "Controls only the while-held preview. The selected model still transcribes the full recording when the shortcut is released."
        )
    }

    private var previewEnabled: Binding<Bool> {
        Binding(
            get: { controller.dictationPreviewEnabled },
            set: controller.setDictationPreviewEnabled
        )
    }
}

struct QuickDictationCleanupControl: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.purple)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Clean final dictation")
                    .font(.callout.weight(.semibold))
                Text(
                    "Asks GPT-Transcribe to omit hesitation fillers, abandoned starts, and immediate repetitions without changing meaning. Local models keep their safest raw result if they cannot apply that style."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("Clean dictation", isOn: cleanupEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.purple.opacity(0.22), lineWidth: 1)
        }
    }

    private var cleanupEnabled: Binding<Bool> {
        Binding(
            get: { controller.dictationCleanupEnabled },
            set: controller.setDictationCleanupEnabled
        )
    }
}

/// The one switch that decides whether any audio leaves this Mac. Stated in
/// terms of what it costs, because two features have no on-device equivalent.
struct LocalOnlyModeControl: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { controller.localOnlyMode },
                set: controller.setLocalOnlyMode
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep everything on this Mac")
                        .font(.headline)
                    Text(
                        controller.localOnlyMode
                            ? "No audio or text is sent to OpenAI. Meeting capture and Answer Mirror are unavailable."
                            : "Quick Dictation stays local; Meeting capture and Answer Mirror still use OpenAI."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(10)
        .background(
            (controller.localOnlyMode ? Color.green : Color.secondary)
                .opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    (controller.localOnlyMode ? Color.green : Color.secondary)
                        .opacity(0.25),
                    lineWidth: 1
                )
        }
    }
}

/// One row per workflow: what it uses, and whether that is a choice.
struct ModelUsageSummary: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(
                workflow: "Quick Dictation",
                model: controller.refinementEngine.modelName,
                isCloud: controller.refinementEngine.isCloud,
                note: "your choice"
            )
            row(
                workflow: "Meeting · live",
                model: RealtimeTranscriptionClient.model,
                isCloud: true,
                note: controller.localOnlyMode ? "unavailable" : "fixed"
            )
            row(
                workflow: "Meeting · final",
                model: controller.refinementEngine.modelName,
                isCloud: controller.refinementEngine.isCloud,
                note: controller.localOnlyMode
                    ? "unavailable"
                    : "same as Quick Dictation"
            )
        }
    }

    private func row(
        workflow: String,
        model: String,
        isCloud: Bool,
        note: String
    ) -> some View {
        let isUnavailable = note == "unavailable"
        return HStack(spacing: 8) {
            Image(systemName: isCloud ? "cloud" : "desktopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(
                    isUnavailable
                        ? Color.secondary
                        : (isCloud ? Color.blue : Color.green)
                )
                .frame(width: 16)
            Text(workflow)
                .font(.callout.weight(.medium))
                .frame(width: 118, alignment: .leading)
            Text(model)
                .font(.callout.monospaced())
                .foregroundStyle(isUnavailable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isUnavailable ? 0.55 : 1)
    }
}

struct SelectableTranscriptionModelPicker: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcription model")
                .font(.headline)
            Text(
                "Used for Quick Dictation, and for Meeting’s second pass. Meeting’s live pass is a separate fixed cloud model."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                ForEach(TranscriptRefinementEngine.allCases) { engine in
                    ModelChoiceButton(
                        engine: engine,
                        isSelected: controller.refinementEngine == engine,
                        isDisabled: controller.isListening
                            || controller.isDictationBusy
                            || (controller.localOnlyMode && engine.isCloud),
                        action: { controller.selectRefinementEngine(engine) }
                    )
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                localPreparationHints(at: timeline.date)
            }
        }
    }

    @ViewBuilder
    private func localPreparationHints(at date: Date) -> some View {
        if let hint = controller.whisperPreparation.hint(at: date) {
            preparationHint(
                hint,
                downloadFraction: controller.whisperPreparation.downloadFraction,
                isInProgress: controller.whisperPreparation.isInProgress,
                isReady: controller.whisperPreparation.isReady,
                isFailed: controller.whisperPreparation.isFailed
            )
        }
        if let hint = controller.parakeetPreparation.hint(at: date) {
            preparationHint(
                hint,
                downloadFraction: controller.parakeetPreparation.downloadFraction,
                isInProgress: controller.parakeetPreparation.isInProgress,
                isReady: controller.parakeetPreparation.isReady,
                isFailed: controller.parakeetPreparation.isFailed
            )
        }
    }

    private func preparationHint(
        _ hint: String,
        downloadFraction: Double?,
        isInProgress: Bool,
        isReady: Bool,
        isFailed: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if let downloadFraction {
                ProgressView(value: downloadFraction)
                    .frame(width: 54)
            } else if isInProgress {
                ProgressView()
                    .controlSize(.small)
            } else if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(hint)
                .lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(isFailed ? Color.orange : Color.secondary)
        .help(hint)
    }
}

struct TranscriptionPipelinePopover: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Models", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.title3.weight(.semibold))
                    Text("What runs where, and which parts you can change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LocalOnlyModeControl(controller: controller)

                // The at-a-glance answer to "which model is used and how",
                // before any of the per-stage detail below.
                ModelUsageSummary(controller: controller)

                Divider()

                workflowTitle(
                    "Meeting",
                    detail: "A fast streaming pass is followed by a higher-accuracy pass for every completed turn."
                )
                HStack(alignment: .center, spacing: 8) {
                    TranscriptionStageCard(
                        stage: "STAGE 1 · LIVE",
                        modelName: RealtimeTranscriptionClient.model,
                        role: "Streaming partial and completed text",
                        detail: "Fixed OpenAI cloud model. Two parallel sessions cover microphone and the selected system-audio source while the meeting is active.",
                        badge: "FIXED · CLOUD",
                        systemImage: "bolt.horizontal.fill",
                        color: .blue
                    )
                    TranscriptionPipelineConnector(label: "TURN\nENDS")
                    TranscriptionStageCard(
                        stage: "STAGE 2 · FINAL",
                        modelName: controller.refinementEngine.modelName,
                        role: "\(controller.refinementEngine.title) · complete turn",
                        detail: "Receives the captured turn audio and replaces or refines the live wording using the selected local or cloud engine.",
                        badge: selectedLocationBadge,
                        systemImage: controller.refinementEngine.systemImage,
                        color: .green
                    )
                }

                Divider()

                workflowTitle(
                    "Quick Dictation",
                    detail: controller.refinementEngine.isCloud
                        ? "One session transcribes while you speak, so releasing the shortcut only sends the tail."
                        : "The selected model is reused; Meeting’s live model is not involved."
                )
                QuickDictationPreviewControl(controller: controller)
                QuickDictationCleanupControl(controller: controller)
                HStack(alignment: .center, spacing: 8) {
                    TranscriptionStageCard(
                        stage: controller.refinementEngine.isCloud
                            ? "WHILE HELD · STREAMING"
                            : "OPTIONAL STAGE · WHILE HELD",
                        modelName: controller.refinementEngine.modelName,
                        role: controller.refinementEngine.isCloud
                            ? "\(controller.refinementEngine.title) · continuous upload"
                            : "\(controller.refinementEngine.title) · bounded snapshots",
                        detail: controller.refinementEngine.isCloud
                            ? "Audio uploads as you speak and a segment closes on each pause, so live text comes back from the same session that produces the final transcript. This is not gpt-live-transcribe."
                            : "Optional periodic transcriptions update the on-screen preview while audio is still growing. This is not gpt-live-transcribe.",
                        badge: controller.refinementEngine.isCloud
                            ? "ONE SESSION"
                            : (controller.dictationPreviewEnabled ? "PREVIEW ON" : "PREVIEW OFF"),
                        systemImage: "text.bubble",
                        color: .orange,
                        isEnabled: controller.refinementEngine.isCloud
                            || controller.dictationPreviewEnabled
                    )
                    TranscriptionPipelineConnector(
                        label: controller.refinementEngine.isCloud
                            ? "SAME\nSTREAM"
                            : "SAME\nMODEL"
                    )
                    TranscriptionStageCard(
                        stage: "ON RELEASE · FINAL",
                        modelName: controller.refinementEngine.modelName,
                        role: "\(controller.refinementEngine.title) · full recording",
                        detail: controller.refinementEngine.isCloud
                            ? "Commits the last segment, then returns to the app and field focused when recording began, pastes there, and saves it in history."
                            : "Transcribes the complete clip once, then returns to the app and field focused when recording began, pastes there, and saves it in history.",
                        badge: selectedLocationBadge,
                        systemImage: controller.refinementEngine.systemImage,
                        color: .green
                    )
                }

                Divider()
                SelectableTranscriptionModelPicker(controller: controller)
            }
            .padding(16)
        }
        .frame(width: 720, height: 620)
    }

    private func workflowTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedLocationBadge: String {
        switch controller.refinementEngine {
        case .localWhisper, .localParakeet:
            "SELECTED · ON DEVICE"
        case .openAITranscribe:
            "SELECTED · CLOUD"
        }
    }
}

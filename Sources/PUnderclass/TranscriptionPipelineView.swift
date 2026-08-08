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
                Text("Show text while I speak")
                    .font(.callout.weight(.semibold))
                Text(
                    controller.refinementEngine.isCloud
                        ? "Words appear in the floating panel as you talk, from the same session that produces the final text."
                        : "While held, periodically runs \(controller.refinementEngine.title) to update the floating panel. Turning this off does not affect the final text."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("Show live text", isOn: previewEnabled)
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
                Text("Tidy up what I said")
                    .font(.callout.weight(.semibold))
                Text(
                    "Removes \u{201C}um\u{201D}, false starts, and repeated words without changing your meaning. Local models fall back to the raw text if they cannot apply it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("Tidy up", isOn: cleanupEnabled)
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
                workflow: "Live capture · live",
                model: RealtimeTranscriptionClient.model,
                isCloud: true,
                note: controller.capability.isCloudEnabled ? "fixed" : "needs a key"
            )
            row(
                workflow: "Live capture · final",
                model: controller.refinementEngine.modelName,
                isCloud: controller.refinementEngine.isCloud,
                note: controller.capability.isCloudEnabled
                    ? "same as Quick Dictation"
                    : "needs a key"
            )
            row(
                workflow: "Live assistants · cues",
                model: LiveAssistantClient.model,
                isCloud: true,
                note: controller.capability.isCloudEnabled
                    ? "meeting + interview"
                    : "needs a key"
            )
        }
    }

    private func row(
        workflow: String,
        model: String,
        isCloud: Bool,
        note: String
    ) -> some View {
        let isUnavailable = note == "needs a key"
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

struct TranscriptionPipelineDiagram: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                workflowTitle(
                    "Meetings and interviews",
                    detail: "Both use the same capture pipeline and evaluate other-speaker moments with a purpose-specific response assistant."
                )
                HStack(alignment: .center, spacing: 8) {
                    TranscriptionStageCard(
                        stage: "STAGE 1 · LIVE",
                        modelName: RealtimeTranscriptionClient.model,
                        role: "Streaming partial and completed text",
                        detail: "Fixed OpenAI cloud model. Two parallel sessions cover microphone and the selected system-audio source while live capture is active.",
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
                        : "The selected model is reused; the live-capture model is not involved."
                )
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

        }
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

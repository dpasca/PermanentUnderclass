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
                .font(.caption.weight(.medium))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .lineLimit(1)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
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

struct SelectableTranscriptionModelPicker: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selectable final-pass and Quick Dictation model")
                .font(.headline)
            Text(
                "This one selection drives Meeting’s second pass and both Quick Dictation stages. The Meeting live model is fixed separately."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                ForEach(TranscriptRefinementEngine.allCases) { engine in
                    ModelChoiceButton(
                        engine: engine,
                        isSelected: controller.refinementEngine == engine,
                        isDisabled: controller.isListening || controller.isDictationBusy,
                        action: { controller.selectRefinementEngine(engine) }
                    )
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                parakeetPreparationHint(at: timeline.date)
            }
        }
    }

    @ViewBuilder
    private func parakeetPreparationHint(at date: Date) -> some View {
        if let hint = controller.parakeetPreparation.hint(at: date) {
            HStack(spacing: 6) {
                if let fraction = controller.parakeetPreparation.downloadFraction {
                    ProgressView(value: fraction)
                        .frame(width: 54)
                } else if controller.parakeetPreparation.isInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else if controller.parakeetPreparation.isReady {
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
            .font(.caption)
            .foregroundStyle(
                controller.parakeetPreparation.isFailed ? Color.orange : Color.secondary
            )
            .help(hint)
        }
    }
}

struct TranscriptionPipelinePopover: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Active Transcription Pipeline", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.title3.weight(.semibold))
                    Text("Each workflow uses the models differently. Only the green model is selectable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                        detail: "Fixed OpenAI cloud model. Two parallel sessions cover microphone and meeting-app audio while the meeting is active.",
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
                    detail: "The selected model is reused; Meeting’s live model is not involved."
                )
                HStack(alignment: .center, spacing: 8) {
                    TranscriptionStageCard(
                        stage: "WHILE HELD · PREVIEW",
                        modelName: controller.refinementEngine.modelName,
                        role: "\(controller.refinementEngine.title) · bounded snapshots",
                        detail: "Optional periodic transcriptions update the on-screen preview while audio is still growing. This is not gpt-live-transcribe.",
                        badge: controller.dictationPreviewEnabled ? "OPTIONAL · ON" : "OPTIONAL · OFF",
                        systemImage: "text.bubble",
                        color: .orange,
                        isEnabled: controller.dictationPreviewEnabled
                    )
                    TranscriptionPipelineConnector(label: "SAME\nMODEL")
                    TranscriptionStageCard(
                        stage: "ON RELEASE · FINAL",
                        modelName: controller.refinementEngine.modelName,
                        role: "\(controller.refinementEngine.title) · full recording",
                        detail: "Transcribes the complete clip once, then pastes the result into the focused app and saves it in history.",
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedLocationBadge: String {
        switch controller.refinementEngine {
        case .localParakeet:
            "SELECTED · ON DEVICE"
        case .openAITranscribe:
            "SELECTED · CLOUD"
        }
    }
}

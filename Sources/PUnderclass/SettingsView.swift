import SwiftUI

enum SettingsSection: String, Hashable, CaseIterable, Identifiable {
    case general
    case dictation
    case openAI
    case privacy
    case howItWorks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .openAI: "OpenAI"
        case .privacy: "Privacy"
        case .howItWorks: "How It Works"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic.badge.plus"
        case .openAI: "key"
        case .privacy: "hand.raised"
        case .howItWorks: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Every setting has exactly one home here. Previously the same controls
/// appeared in two header popovers, so there was no single answer to "where do
/// I change this".
struct SettingsView: View {
    @ObservedObject var controller: MeetingController
    @State private var section: SettingsSection = .general

    var body: some View {
        TabView(selection: $section) {
            ForEach(SettingsSection.allCases) { item in
                ScrollView {
                    content(for: item)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tabItem { Label(item.title, systemImage: item.systemImage) }
                .tag(item)
            }
        }
        .frame(width: 620, height: 540)
        // Both paths are needed. The request is made before this view exists
        // the first time the window is opened, so `onChange` sees nothing and
        // only `onAppear` catches it; every later request arrives while the
        // view is alive, where only `onChange` fires.
        .onAppear(perform: applyRequestedSection)
        .onChange(of: controller.pendingSettingsSection) { _, _ in
            applyRequestedSection()
        }
    }

    /// Sends the user straight to the section that answers what they clicked.
    private func applyRequestedSection() {
        guard let requested = controller.pendingSettingsSection else { return }
        section = requested
        controller.pendingSettingsSection = nil
    }

    @ViewBuilder
    private func content(for section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralSettings(controller: controller)
        case .dictation: DictationSettings(controller: controller)
        case .openAI: OpenAISettings(controller: controller)
        case .privacy: PrivacySettings(controller: controller)
        case .howItWorks: HowItWorksSettings(controller: controller)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(
                "Microphone",
                detail: "Shared by dictation, meetings, and interviews."
            ) {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    AudioDeviceRow(
                        title: "MICROPHONE INPUT",
                        name: controller.microphoneName,
                        systemImage: "mic.fill",
                        health: controller.microphoneHealth(at: timeline.date),
                        devices: controller.inputDevices,
                        selectedDeviceID: controller.selectedInputDeviceID,
                        onSelect: controller.selectInputDevice
                    )
                }
            }

            SettingsGroup(
                "Languages you speak",
                detail: "List more than one and the model detects which you are using."
            ) {
                TextField("en, ja", text: $controller.languagesText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

private struct DictationSettings: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(
                "Shortcut",
                detail: "Hold ⌘ + ⌥ anywhere, speak, then let go. The text is pasted where you were typing."
            ) {
                Toggle(
                    "Enable Quick Dictation",
                    isOn: Binding(
                        get: { controller.dictationEnabled },
                        set: controller.setDictationEnabled
                    )
                )
            }

            SettingsGroup(
                "Accuracy",
                detail: "Dictation works offline. An OpenAI key adds a more accurate option."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(TranscriptRefinementEngine.allCases) { engine in
                        EngineChoiceRow(
                            engine: engine,
                            isSelected: controller.refinementEngine == engine,
                            isLocked: engine.isCloud
                                && !controller.capability.isCloudEnabled,
                            isBusy: controller.isListening
                                || controller.isDictationBusy,
                            action: { controller.selectRefinementEngine(engine) }
                        )
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        LocalModelPreparationHints(
                            controller: controller,
                            date: timeline.date
                        )
                    }
                }
            }

            SettingsGroup("While dictating", detail: nil) {
                VStack(alignment: .leading, spacing: 10) {
                    QuickDictationPreviewControl(controller: controller)
                    QuickDictationCleanupControl(controller: controller)
                }
            }
        }
    }
}

private struct OpenAISettings: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(
                "OpenAI API key",
                detail: "Optional. Dictation and two-speaker meeting/interview transcripts already work locally. A key adds live partial text, AI suggestions, hosted web search, generated replays, and the best-accuracy transcription option."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if !controller.capability.hasAPIKey {
                        Label(
                            "No OpenAI API key is currently configured",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    }
                    HStack {
                        SecureField("sk-…", text: $controller.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(controller.saveAPIKey)
                        Button("Save", action: controller.saveAPIKey)
                            .buttonStyle(.borderedProminent)
                    }
                    if !controller.keyStatus.isEmpty {
                        Text(controller.keyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Link(
                        "Create a key at platform.openai.com",
                        destination: URL(
                            string: "https://platform.openai.com/api-keys"
                        )!
                    )
                    .font(.caption)
                    Text(
                        "You pay OpenAI directly for what you use. Dictation costs roughly a few cents per hour of speech. Suggested answers may use OpenAI's built-in web search with this same key; no separate search account is needed. The key is stored in this Mac's Keychain and is never sent anywhere except OpenAI."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsGroup("What a key unlocks", detail: nil) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(CloudFeature.allCases) { feature in
                        FeatureStatusRow(
                            feature: feature,
                            access: controller.access(to: feature)
                        )
                    }
                }
            }

            if controller.capability.hasAPIKey {
                SettingsGroup(
                    "Spending estimate",
                    detail: controller.apiExpenses.accumulationDescription()
                ) {
                    HStack {
                        Text(controller.apiExpenses.displayCost)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Reset Counter", action: controller.resetAPIExpenses)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct PrivacySettings: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(
                "Keep everything on this Mac",
                detail: "Turns off every feature that would send audio or text to OpenAI or use its hosted web search, even if a key is saved."
            ) {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle(
                        "Never contact OpenAI",
                        isOn: Binding(
                            get: { controller.privacyLockEnabled },
                            set: controller.setPrivacyLock
                        )
                    )
                    .toggleStyle(.switch)
                    Text(
                        controller.privacyLockEnabled
                            ? "Dictation, meeting transcripts, and interview transcripts stay available on this Mac. Live partials, AI suggestions, web search, and generated replays are turned off."
                            : "Turning this on keeps local dictation and two-speaker transcripts available, while disabling every OpenAI enhancement."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsGroup("What stays local either way", detail: nil) {
                VStack(alignment: .leading, spacing: 5) {
                    bullet("Recordings are never written anywhere except this Mac, and are deleted once the text is saved.")
                    bullet("Dictation history lives in this Mac's Application Support folder.")
                    bullet("Meeting and interview audio can be split by speaker and transcribed with Whisper or Parakeet without leaving this Mac.")
                    bullet("Your reference documents are read locally; only excerpts are sent, and only when a key is in use.")
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct HowItWorksSettings: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModelUsageSummary(controller: controller)
            Divider()
            TranscriptionPipelineDiagram(controller: controller)
        }
    }
}

// MARK: - Shared pieces

struct SettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    init(
        _ title: String,
        detail: String?,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

/// A model choice presented by what it gives you, with the model identifier
/// available but not shouted.
struct EngineChoiceRow: View {
    let engine: TranscriptRefinementEngine
    let isSelected: Bool
    let isLocked: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected
                    ? "largecircle.fill.circle"
                    : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(engine.accuracyTitle)
                            .font(.callout.weight(.semibold))
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(engine.locationSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(engine.plainDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text(engine.modelName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor.opacity(0.4)
                            : Color.secondary.opacity(0.2),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isLocked)
        .opacity(isLocked ? 0.55 : 1)
        .help(isLocked
            ? "Add an OpenAI API key to use this option"
            : engine.plainDescription)
    }
}

struct FeatureStatusRow: View {
    let feature: CloudFeature
    let access: FeatureAccess

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 11))
                .foregroundStyle(access.isAvailable ? Color.green : Color.secondary)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                    .font(.callout)
                if
                    !access.isAvailable,
                    let localDescription = feature.availableWithoutKeyDescription
                {
                    Text(localDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var symbolName: String {
        if access.isAvailable { return "checkmark.circle.fill" }
        return feature.isOptionalUpgrade ? "circle.dashed" : "lock.fill"
    }

    private var statusText: String {
        switch access {
        case .available: "Available"
        case .needsAPIKey: "Needs a key"
        case .blockedByPrivacyLock: "Turned off"
        }
    }
}

struct LocalModelPreparationHints: View {
    @ObservedObject var controller: MeetingController
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = controller.whisperPreparation.hint(at: date) {
                hintRow(
                    hint,
                    fraction: controller.whisperPreparation.downloadFraction,
                    isInProgress: controller.whisperPreparation.isInProgress,
                    isReady: controller.whisperPreparation.isReady,
                    isFailed: controller.whisperPreparation.isFailed
                )
            }
            if let hint = controller.parakeetPreparation.hint(at: date) {
                hintRow(
                    hint,
                    fraction: controller.parakeetPreparation.downloadFraction,
                    isInProgress: controller.parakeetPreparation.isInProgress,
                    isReady: controller.parakeetPreparation.isReady,
                    isFailed: controller.parakeetPreparation.isFailed
                )
            }
        }
    }

    private func hintRow(
        _ hint: String,
        fraction: Double?,
        isInProgress: Bool,
        isReady: Bool,
        isFailed: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 54)
            } else if isInProgress {
                ProgressView().controlSize(.small)
            } else if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(hint).lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(isFailed ? Color.orange : Color.secondary)
    }
}

import AppKit
import SwiftUI

enum PUnderclassWindow {
    static let preparation = "capture-preparation"
}

struct ReferenceMaterialView: View {
    @ObservedObject var controller: MeetingController
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showsPlausibleRehearsalConfirmation = false
    @State private var showsSupportingSources = false
    @State private var showsAnswerSettings = false
    @State private var showsEvidenceDetails = false
    @State private var showsSourceHandling = false
    @State private var showsReadyRoleEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preparationSections
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 800, minHeight: 700)
        .alert(
            "Enable Plausible Rehearsal?",
            isPresented: $showsPlausibleRehearsalConfirmation
        ) {
            Button("Enable Until Turned Off", role: .destructive) {
                controller.setAssistantAnswerModePreference(
                    .plausibleRehearsal
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Answer Mirror may attach a draft to a plausible project or work setting and fill in likely actions and outcomes. The assistant display will mark every such cue as a rehearsal draft, but you must replace or verify the invented details before using them as facts. This choice stays enabled for future interviews until you switch back to Grounded."
            )
        }
        .onAppear {
            revealDetailsNeededForCurrentInterviewState(
                controller.interviewPreparationReadiness
            )
        }
        .onChange(of: controller.interviewPreparationReadiness) {
            _, readiness in
            withAnimation(.easeInOut(duration: 0.2)) {
                revealDetailsNeededForCurrentInterviewState(readiness)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("\(purpose.title) Preparation")
                    .font(.title.weight(.semibold))
                Text(
                    headerDetail
                )
                .font(.body)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text("PREPARE FOR")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Prepare for", selection: $controller.preparationPurpose) {
                    ForEach(CapturePurpose.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var liveFeature: CloudFeature {
        purpose == .meeting ? .meetingCapture : .answerMirror
    }

    private func showSettings(_ section: SettingsSection) {
        controller.requestSettings(section)
        openSettings()
    }

    private var headerDetail: String {
        if !controller.capability.isCloudEnabled {
            return "Set local transcription context before capture. OpenAI assistant features are currently unavailable."
        }
        return purpose == .meeting
            ? "Give transcription and Meeting Assistant the context they need before the conversation starts."
            : "Follow the highlighted step. Optional details stay out of the way until you need them."
    }

    @ViewBuilder
    private var preparationSections: some View {
        if purpose == .interview {
            interviewPreparationFlow
        } else {
            if !controller.capability.isCloudEnabled {
                LockedFeatureCard(
                    feature: liveFeature,
                    access: controller.access(to: liveFeature),
                    onResolve: showSettings
                )
            }
            sessionGuidanceSection
            folderSection
            recognitionHintsSection
            assistantUsesSection
            documentSection
            issueSection
            privacyNote
        }
    }

    private var interviewPreparationFlow: some View {
        VStack(alignment: .leading, spacing: 16) {
            interviewProgressSection
            interviewCurrentStepSection
            issueSection

            interviewDisclosure(
                title: "Optional supporting sources",
                detail: supportingSourcesSummary,
                systemImage: "books.vertical",
                isExpanded: $showsSupportingSources
            ) {
                Text(
                    "Add these only when they provide useful detail beyond the resume. The selected resume remains the primary career source."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                folderSection
                webSourcesSection
            }

            interviewDisclosure(
                title: "Answer style and speech settings",
                detail: "\(controller.assistantAnswerMode.title) answers · speech hints are optional",
                systemImage: "slider.horizontal.3",
                isExpanded: $showsAnswerSettings
            ) {
                answerModeSection
                    .disabled(!controller.capability.isCloudEnabled)
                    .opacity(
                        controller.capability.isCloudEnabled ? 1 : 0.45
                    )
                recognitionHintsSection
            }

            if controller.referencePreparationState.pack != nil {
                interviewDisclosure(
                    title: "Review prepared evidence",
                    detail: evidenceSummary,
                    systemImage: "rectangle.stack",
                    isExpanded: $showsEvidenceDetails
                ) {
                    preparedEvidenceSection
                }
            }

            interviewDisclosure(
                title: "How sources are handled",
                detail: "Indexed documents, source use, and privacy",
                systemImage: "lock.shield",
                isExpanded: $showsSourceHandling
            ) {
                assistantUsesSection
                documentSection
                privacyNote
            }
        }
    }

    private var interviewProgressSection: some View {
        HStack(spacing: 10) {
            interviewProgressStep(number: 1, title: "Resume")
            interviewProgressConnector(after: 1)
            interviewProgressStep(number: 2, title: "Prepare")
            interviewProgressConnector(after: 2)
            interviewProgressStep(number: 3, title: "Ready")
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Interview preparation, step \(interviewProgressPosition) of 3"
        )
    }

    private func interviewProgressStep(
        number: Int,
        title: String
    ) -> some View {
        let isComplete = interviewProgressPosition > number
        let isCurrent = interviewProgressPosition == number
        let color: Color = isComplete || isCurrent ? .accentColor : .secondary

        return HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(
                        isComplete
                            ? color
                            : color.opacity(isCurrent ? 0.18 : 0.1)
                    )
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                }
            }
            Text(title)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent || isComplete ? .primary : .secondary)
        }
    }

    private func interviewProgressConnector(after number: Int) -> some View {
        Capsule()
            .fill(
                interviewProgressPosition > number
                    ? Color.accentColor
                    : Color.secondary.opacity(0.2)
            )
            .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
    }

    private var interviewCurrentStepSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: interviewReadinessIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(interviewReadinessColor)
                    .frame(width: 42, height: 42)
                    .background(
                        interviewReadinessColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(interviewReadinessLabel.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(interviewReadinessColor)
                    Text(interviewReadinessTitle)
                        .font(.title2.weight(.semibold))
                    Text(interviewReadinessDetail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            interviewCurrentStepControls
        }
        .padding(20)
        .background(
            interviewReadinessColor.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(interviewReadinessColor.opacity(0.32), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var interviewCurrentStepControls: some View {
        switch controller.interviewPreparationReadiness {
        case .unavailable:
            HStack {
                Label(
                    "You can still record a local two-speaker transcript.",
                    systemImage: "waveform"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Set Up OpenAI…") {
                    showSettings(.openAI)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .activeSession:
            Label(
                "Return here after stopping the active capture or generated replay.",
                systemImage: "stop.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

        case .preparing:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.referencePreparationState.phase.title)
                        .font(.body.weight(.semibold))
                    Text(
                        "This window will advance automatically when preparation finishes."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

        case .needsResume:
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF, RTF, or plain text")
                        .font(.callout.weight(.semibold))
                    Text(
                        "You can add portfolio pages and project notes afterward."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: controller.chooseResumeFile) {
                    Label("Choose Resume…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .needsInterviewDescription, .needsEvidence:
            selectedResumeRow
            interviewContextEditor
            if case let .failed(message) =
                controller.referencePreparationState.phase
            {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button(action: controller.prepareInterviewEvidence) {
                    Label(
                        controller.referencePreparationState.pack == nil
                            ? "Prepare for Interview"
                            : "Update Preparation",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!controller.canPrepareInterviewEvidence)

                Button("Add Supporting Sources…") {
                    withAnimation {
                        showsSupportingSources = true
                    }
                }
                .controlSize(.large)
            }

        case .needsSourceReview:
            selectedResumeRow
            if let summary = controller.referencePreparationState.pack?
                .sourceManifest?.resolutionSummary
            {
                Label(summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Review Source Details") {
                    withAnimation {
                        showsEvidenceDetails = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Choose Another Resume…", action: controller.chooseResumeFile)
                    .controlSize(.large)
            }

        case .needsUsableEvidence:
            selectedResumeRow
            HStack(spacing: 10) {
                Button("Choose Another Resume…", action: controller.chooseResumeFile)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Add Supporting Sources…") {
                    withAnimation {
                        showsSupportingSources = true
                    }
                }
                .controlSize(.large)
            }

        case let .ready(cardCount):
            selectedResumeRow
            HStack(spacing: 10) {
                Label(
                    "\(cardCount) evidence \(cardCount == 1 ? "card" : "cards") · \(controller.assistantAnswerMode.title)",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                Spacer()
                Button("Edit Description…") {
                    withAnimation {
                        showsReadyRoleEditor.toggle()
                    }
                }
                .controlSize(.large)
                Button("Done — Return to Interview") {
                    dismissWindow(id: PUnderclassWindow.preparation)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if showsReadyRoleEditor {
                interviewContextEditor
            }
        }
    }

    private var selectedResumeRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.text.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    controller.referencePreparationState.resumeSource?
                        .displayName ?? "No resume selected"
                )
                .font(.body.weight(.semibold))
                Text("Primary career source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Change…", action: controller.chooseResumeFile)
            Menu {
                Button(
                    "Reveal in Finder",
                    action: controller.revealResumeFile
                )
                Divider()
                Button("Stop Using This Resume", role: .destructive) {
                    controller.clearResumeFile()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("More resume actions")
        }
        .padding(11)
        .background(
            Color.secondary.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var interviewContextEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interview description")
                .font(.body.weight(.semibold))
            Text(
                "This is exactly what Answer Mirror uses. It starts with a simple description; AI can suggest a more specific version from the selected resume. Review or edit anything that does not fit. Spoken language is controlled separately under speech settings."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: interviewContextBinding)
                .font(.body)
                .frame(minHeight: 90)
                .padding(7)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.separator.opacity(0.75), lineWidth: 1)
                }

            HStack(alignment: .center, spacing: 10) {
                interviewContextStatus
                Spacer()
                if controller.referencePreparationState.resumeSource != nil {
                    Button(
                        controller.referencePreparationState.interviewContext
                            .origin == .resumeSuggestion
                            ? "Suggest Again from Resume"
                            : "Suggest from Resume",
                        action: controller.suggestInterviewContextFromResume
                    )
                    .disabled(!controller.canSuggestInterviewContext)
                }
            }

            if controller.interviewContextPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                Label(
                    "Add an interview description before preparing evidence.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var interviewContextStatus: some View {
        switch controller.interviewContextSuggestionPhase {
        case .generating:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Drafting from the selected resume…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .insufficient:
            Label(
                "The resume did not support a useful specific draft; the visible basic description remains in use.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .idle:
            switch controller.referencePreparationState.interviewContext.origin {
            case .basic:
                Label(
                    "Basic visible description — no extra interview prompt is added behind the scenes.",
                    systemImage: "eye"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            case .resumeSuggestion:
                Label(
                    "Suggested from the selected resume. Review it before preparing.",
                    systemImage: "sparkles"
                )
                .font(.callout)
                .foregroundStyle(.green)
            case .userEdited:
                Label(
                    "Edited by you. This exact version is saved.",
                    systemImage: "pencil"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func interviewDisclosure<Content: View>(
        title: String,
        detail: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.top, 14)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .background(
            Color.secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
    }

    private var interviewProgressPosition: Int {
        guard controller.referencePreparationState.resumeSource != nil else {
            return 1
        }
        return controller.isInterviewPreparationReady ? 3 : 2
    }

    private var interviewReadinessTitle: String {
        switch controller.interviewPreparationReadiness {
        case .unavailable:
            "Turn on Answer Mirror"
        case .activeSession:
            "Finish the current session first"
        case .preparing:
            "Preparing your interview evidence"
        case .needsResume:
            "Choose the resume for this interview"
        case .needsInterviewDescription:
            "Describe the interview before preparing"
        case .needsEvidence:
            controller.referencePreparationState.pack == nil
                ? "Review the interview description, then prepare"
                : "Update the prepared evidence"
        case .needsSourceReview:
            "One source conflict still needs your choice"
        case .needsUsableEvidence:
            "No usable experience was found"
        case .ready:
            "Ready for the interview"
        }
    }

    private var interviewReadinessDetail: String {
        switch controller.interviewPreparationReadiness {
        case .unavailable:
            "An OpenAI key is needed for live answer suggestions and evidence preparation."
        case .activeSession:
            "Preparation cannot change while an interview or generated replay is active."
        case .preparing:
            "The app is reading your sources, separating factual career material from preparation notes, and building concise evidence cards."
        case .needsResume:
            "Choose the current resume you want to use. This keeps old drafts and interview notes from being treated as your work history."
        case .needsInterviewDescription:
            "The description field is empty. Add the exact interview context Answer Mirror should use; nothing else will be substituted for it."
        case .needsEvidence:
            controller.referencePreparationState.pack == nil
                ? "Review the editable description below, then let the app organize the resume into useful interview evidence."
                : "The resume, supporting sources, or interview description changed. Refresh the evidence before you start."
        case .needsSourceReview:
            "The app could not safely decide which source should establish a candidate fact."
        case .needsUsableEvidence:
            "Try a more complete resume or add a portfolio or project source with concrete work details."
        case let .ready(cardCount):
            "Everything Answer Mirror needs is prepared. It will select from \(cardCount) grounded evidence \(cardCount == 1 ? "card" : "cards") during the interview."
        }
    }

    private var interviewReadinessLabel: String {
        switch controller.interviewPreparationReadiness {
        case .ready:
            "Everything is ready"
        case .preparing:
            "Working"
        case .unavailable, .activeSession, .needsResume, .needsEvidence,
             .needsInterviewDescription, .needsSourceReview,
             .needsUsableEvidence:
            "Next step"
        }
    }

    private var interviewReadinessIcon: String {
        switch controller.interviewPreparationReadiness {
        case .unavailable:
            "lock.fill"
        case .activeSession:
            "waveform"
        case .preparing:
            "sparkles"
        case .needsResume:
            "doc.badge.plus"
        case .needsInterviewDescription, .needsEvidence:
            "wand.and.stars"
        case .needsSourceReview, .needsUsableEvidence:
            "exclamationmark.triangle.fill"
        case .ready:
            "checkmark.seal.fill"
        }
    }

    private var interviewReadinessColor: Color {
        switch controller.interviewPreparationReadiness {
        case .ready:
            .green
        case .needsSourceReview, .needsUsableEvidence:
            .orange
        case .unavailable, .activeSession:
            .secondary
        case .preparing, .needsResume, .needsInterviewDescription,
             .needsEvidence:
            .accentColor
        }
    }

    private var supportingSourcesSummary: String {
        let folderCount = controller.referenceLibraryState.snapshot?
            .documents.count ?? 0
        let webCount = controller.referencePreparationState.webSources.count
        if folderCount == 0, webCount == 0 {
            return "None added — the resume is enough to continue"
        }
        var parts: [String] = []
        if folderCount > 0 {
            parts.append("\(folderCount) folder \(folderCount == 1 ? "document" : "documents")")
        }
        if webCount > 0 {
            parts.append("\(webCount) web \(webCount == 1 ? "page" : "pages")")
        }
        return parts.joined(separator: " · ")
    }

    private var evidenceSummary: String {
        guard let pack = controller.referencePreparationState.pack else {
            return "Not prepared"
        }
        if pack.sourceManifest?.requiresReview == true {
            return "Source review needed"
        }
        if !controller.isInterviewEvidenceCurrent {
            return "Out of date"
        }
        return "\(pack.enabledCardCount) of \(pack.cards.count) cards enabled"
    }

    private func revealDetailsNeededForCurrentInterviewState(
        _ readiness: InterviewPreparationReadiness
    ) {
        switch readiness {
        case .needsSourceReview:
            showsEvidenceDetails = true
        case .needsUsableEvidence:
            showsSupportingSources = true
        case .unavailable, .activeSession, .preparing, .needsResume,
             .needsInterviewDescription, .needsEvidence, .ready:
            break
        }
    }

    private var sessionGuidanceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        purpose == .meeting
                            ? "What is this meeting about?"
                            : "What interview should the assistant expect?"
                    )
                    .font(.title3.weight(.semibold))
                    Text(
                        purpose == .meeting
                            ? "Include the participants, purpose, likely topics, and any important constraints. This guides both transcription and Meeting Assistant."
                            : "This exact editable description guides transcription and Answer Mirror. Spoken language is configured separately."
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)
                }

                TextEditor(text: contextPromptBinding)
                    .font(.body)
                    .frame(minHeight: 115)
                    .padding(7)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.separator.opacity(0.75), lineWidth: 1)
                    }

                HStack(spacing: 12) {
                    if controller.isListening,
                       controller.capturePurpose == purpose
                    {
                        Label(
                            "Changes need to be sent to the active \(purpose.title.lowercased()).",
                            systemImage: "waveform"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "Used automatically when the next \(purpose.title.lowercased()) starts.",
                            systemImage: "checkmark.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if controller.isListening,
                       controller.capturePurpose == purpose
                    {
                        Button {
                            controller.applyContext(for: purpose)
                        } label: {
                            Label(
                                "Update Live \(purpose.title)",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Session Guidance", systemImage: "text.alignleft")
                .font(.title3.weight(.semibold))
        }
    }

    private var answerModeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Answer mode", selection: answerModeBinding) {
                    Text("Grounded").tag(AssistantAnswerMode.grounded)
                    Text("Plausible rehearsal")
                        .tag(AssistantAnswerMode.plausibleRehearsal)
                }
                .pickerStyle(.segmented)
                .disabled(
                    controller.isListening
                        || controller.syntheticInterviewState.isActive
                )

                if controller.assistantAnswerMode == .plausibleRehearsal {
                    Label(
                        "Danger mode: useful as an answer template, not as a factual account.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)

                    Divider()

                    Toggle(
                        isOn: earlyBridgeBinding
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Early speaking bridge (experimental)")
                                .font(.body.weight(.semibold))
                            Text(
                                "Uses fast Priority requests while the interviewer is speaking and again at the first stable pause. It shows one short answer opening, then the complete Answer Mirror cue replaces it. In this danger mode the opening may sketch a restrained incident from the question before the evidence pack is available, and it may misread an unfinished question."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(
                        controller.isListening
                            || controller.syntheticInterviewState.isActive
                    )
                }

                Text(
                    controller.assistantAnswerMode == .plausibleRehearsal
                        ? "The assistant may choose a relevant project, infer a modest bottleneck, action, validation, and outcome, and disclose those assumptions to the display. Extreme financial, popularity, and performance claims remain forbidden. This stays enabled until you switch back to Grounded."
                        : "Past-experience claims must come from the transcript or indexed references. When evidence is missing, the assistant gives a concrete first-person approach without claiming that it already happened."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        } label: {
            Label("Answer Mode", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))
        }
    }

    private var recognitionHintsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Exact terminology")
                            .font(.body.weight(.semibold))
                        Text("One product name, acronym, or technical term per line.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $controller.keywordsText)
                            .font(.body)
                            .frame(minHeight: 95)
                            .padding(6)
                            .background(
                                Color(nsColor: .textBackgroundColor).opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.separator.opacity(0.75), lineWidth: 1)
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Expected languages")
                                .font(.body.weight(.semibold))
                            Text("Comma-separated language codes, such as en, ja.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            TextField("en, ja", text: $controller.languagesText)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                        }

                        Picker(
                            "Live accuracy / latency",
                            selection: $controller.delay
                        ) {
                            ForEach(TranscriptionDelay.allCases) { value in
                                Text(value.rawValue.capitalized).tag(value)
                            }
                        }
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(
                    "Terminology and language hints are shared with Quick Dictation, Meeting, and Interview. Session Guidance above remains separate for each mode.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Label("Speech Recognition Hints", systemImage: "waveform")
                .font(.title3.weight(.semibold))
        }
    }

    private var folderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(
                        "This document library is shared by Meeting Assistant, Answer Mirror, and both generated replays."
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if controller.referenceLibraryState.phase == .scanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(controller.referenceLibraryState.phaseLabel)
                        .font(.body.weight(.medium))
                        .foregroundStyle(phaseColor)
                }

                if let folderURL = controller.referenceLibraryState.folderURL {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(folderURL.lastPathComponent)
                                .font(.title3.weight(.semibold))
                            Text(
                                (folderURL.path as NSString)
                                    .abbreviatingWithTildeInPath
                            )
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        }

                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button("Change Folder…", action: controller.chooseReferenceFolder)
                            .buttonStyle(.borderedProminent)
                        Button("Reveal in Finder", action: controller.revealReferenceFolder)
                        Button("Rescan Now", action: controller.rescanReferenceFolder)
                        Spacer()
                        Button("Stop Using Folder", role: .destructive) {
                            controller.clearReferenceFolder()
                        }
                    }
                    .controlSize(.large)

                    if let snapshot = controller.referenceLibraryState.snapshot {
                        HStack(spacing: 12) {
                            metric(
                                value: "\(snapshot.documents.count)",
                                label: snapshot.documents.count == 1
                                    ? "document"
                                    : "documents"
                            )
                            metric(
                                value: compactCount(snapshot.totalCharacters),
                                label: "indexed characters"
                            )
                            metric(
                                value: "\(snapshot.ignoredFileCount)",
                                label: "unsupported files ignored"
                            )
                            metric(
                                value: String(snapshot.revision.prefix(8)),
                                label: "reference revision"
                            )
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Choose a folder of working documents")
                                .font(.title3.weight(.semibold))
                            Text(
                                "PermanentUnderclass indexes supported files locally and watches the folder for changes."
                            )
                            .font(.body)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(action: controller.chooseReferenceFolder) {
                            Label("Choose Reference Folder…", systemImage: "folder.badge.plus")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }

                if case let .failed(message) = controller.referenceLibraryState.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.body)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        } label: {
            Label("Reference Library", systemImage: "books.vertical.fill")
                .font(.title3.weight(.semibold))
        }
    }

    private var assistantUsesSection: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                assistantUse(
                    title: "Meeting Assistant",
                    icon: "person.2.wave.2",
                    color: .blue,
                    detail: "Finds project facts, constraints, decisions, and status details for concise meeting responses."
                )
                assistantUse(
                    title: "Answer Mirror",
                    icon: "person.crop.rectangle",
                    color: .purple,
                    detail: controller.assistantAnswerMode == .plausibleRehearsal
                        ? "Drafts visibly labeled, project-specific rehearsal answers and exposes assumptions to verify."
                        : "Uses supported experience and the visible interview description without inventing personal claims."
                )
                assistantUse(
                    title: "Generated Replays",
                    icon: "play.rectangle.fill",
                    color: .indigo,
                    detail: "Builds mock meetings and interviews whose questions and responses cite this library."
                )
            }
            .padding(8)
        } label: {
            Label("How the Library Is Used", systemImage: "sparkles")
                .font(.title3.weight(.semibold))
        }
    }

    private var webSourcesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Add public profile, portfolio, project, or credits pages that contain useful career detail. Pages are read only when you click Prepare Evidence."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    TextField(
                        "https://example.com/profile",
                        text: $controller.webReferenceURLDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(controller.addReferenceWebSource)

                    Button(action: controller.addReferenceWebSource) {
                        Label("Add URL", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        controller.webReferenceURLDraft.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            || controller.referencePreparationState.phase.isWorking
                    )
                }

                if controller.referencePreparationState.webSources.isEmpty {
                    Label(
                        "No web sources yet. The local reference folder can still be prepared by itself.",
                        systemImage: "globe"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.referencePreparationState.webSources) {
                            source in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: webSourceIcon(source.status))
                                    .foregroundStyle(webSourceColor(source.status))
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(
                                        source.title.flatMap {
                                            $0.isEmpty ? nil : $0
                                        } ?? source.requestedURL
                                    )
                                    .font(.body.weight(.medium))
                                    .lineLimit(2)
                                    Text(source.requestedURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    Text(
                                        source.detail.isEmpty
                                            ? source.status.title
                                            : "\(source.status.title) · \(source.detail)"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(webSourceColor(source.status))
                                    .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()

                                Button {
                                    controller.removeReferenceWebSource(
                                        id: source.id
                                    )
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(
                                    controller.referencePreparationState.phase
                                        .isWorking
                                )
                                .help("Remove web source")
                            }
                            .padding(.vertical, 9)

                            if source.id
                                != controller.referencePreparationState
                                    .webSources.last?.id
                            {
                                Divider()
                            }
                        }
                    }
                }

                Label(
                    "Jina Reader is tried first and needs no key. A direct fetch comes next; Exa is an optional fallback for difficult pages.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        } label: {
            Label("Public Web Sources", systemImage: "globe")
                .font(.title3.weight(.semibold))
        }
    }

    private var preparedEvidenceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if controller.referencePreparationState.phase.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.interviewEvidenceReadinessDetail())
                            .font(.body.weight(.medium))
                            .foregroundStyle(
                                controller.isInterviewEvidenceResolved
                                    ? Color.green
                                    : .secondary
                            )
                        Text(
                            "This is an offline preparation step for the live assistant: it extracts factual anchors once, then selects a small relevant subset locally for each question."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button(action: controller.prepareInterviewEvidence) {
                        Label(
                            controller.referencePreparationState.pack == nil
                                ? "Prepare Evidence"
                                : "Rebuild Evidence",
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        !controller.canPrepareInterviewEvidence
                            || controller.referencePreparationState.resumeSource
                                == nil
                    )
                }

                if case let .failed(message) =
                    controller.referencePreparationState.phase
                {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if let pack = controller.referencePreparationState.pack {
                    Divider()

                    HStack {
                        Text(
                            "\(pack.enabledCardCount) of \(pack.cards.count) cards enabled"
                        )
                        .font(.callout.weight(.semibold))
                        Spacer()
                        Text(
                            pack.sourceManifest?.requiresReview == true
                                ? "REVIEW REQUIRED"
                                : controller.isInterviewEvidenceResolved
                                    ? "CURRENT"
                                    : "STALE · REBUILD"
                        )
                        .font(.caption.weight(.bold))
                        .foregroundStyle(
                            controller.isInterviewEvidenceResolved
                                ? Color.green
                                : Color.orange
                        )
                    }

                    if let manifest = pack.sourceManifest {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                manifest.resolutionSummary,
                                systemImage: manifest.requiresReview
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.seal.fill"
                            )
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(
                                manifest.requiresReview ? Color.orange : .green
                            )
                            .fixedSize(horizontal: false, vertical: true)

                            ForEach(manifest.sources) { source in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 7) {
                                        Text(source.title)
                                            .font(.callout.weight(.medium))
                                        Text(source.kind.title.uppercased())
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(source.use.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(
                                                source.use.canSupportCandidateFacts
                                                    ? Color.primary
                                                    : Color.secondary
                                            )
                                    }
                                    Text(source.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    Text(source.rationale)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                    if !source.conflictSummary.isEmpty {
                                        Text(source.conflictSummary)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                            .fixedSize(
                                                horizontal: false,
                                                vertical: true
                                            )
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(10)
                        .background(
                            Color.secondary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }

                    LazyVStack(spacing: 0) {
                        ForEach(pack.cards) { card in
                            Toggle(
                                isOn: Binding(
                                    get: { card.isEnabled },
                                    set: {
                                        controller.setPreparedReferenceEnabled(
                                            id: card.id,
                                            enabled: $0
                                        )
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 7) {
                                        Text(card.projectAnchor)
                                            .font(.body.weight(.semibold))
                                        if !card.period.isEmpty {
                                            Text(card.period)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("ROLE \(card.roleRelevance)/5")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    if !card.role.isEmpty {
                                        Text(card.role)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(card.summary)
                                        .font(.callout)
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                    ForEach(
                                        Array(
                                            card.concreteDetails
                                                .prefix(3)
                                                .enumerated()
                                        ),
                                        id: \.offset
                                    ) { _, detail in
                                        Text("• \(detail)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(
                                                horizontal: false,
                                                vertical: true
                                            )
                                    }
                                    Text(card.sourcePaths.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }
                            .toggleStyle(.switch)
                            .disabled(
                                controller.referencePreparationState.phase
                                    .isWorking
                            )
                            .padding(.vertical, 10)

                            if card.id != pack.cards.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Prepared Interview Evidence", systemImage: "rectangle.stack")
                .font(.title3.weight(.semibold))
        }
    }

    @ViewBuilder
    private var documentSection: some View {
        GroupBox {
            if let snapshot = controller.referenceLibraryState.snapshot,
               !snapshot.documents.isEmpty
            {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.documents) { document in
                        HStack(spacing: 12) {
                            Image(systemName: document.kind.systemImage)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.relativePath)
                                    .font(.body.weight(.medium))
                                    .textSelection(.enabled)
                                Text(
                                    "\(document.kind.title) · \(compactCount(document.content.count)) characters"
                                        + (document.isTruncated ? " · truncated" : "")
                                )
                                .font(.callout)
                                .foregroundStyle(
                                    document.isTruncated ? Color.orange : .secondary
                                )
                            }

                            Spacer()
                        }
                        .padding(.vertical, 9)

                        if document.id != snapshot.documents.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                ContentUnavailableView(
                    "No indexed documents",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        "Choose a folder containing PDF, RTF, Markdown, text, or common structured-text files."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            }
        } label: {
            Label("Indexed Documents", systemImage: "doc.on.doc")
                .font(.title3.weight(.semibold))
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        if let snapshot = controller.referenceLibraryState.snapshot,
           !snapshot.issues.isEmpty
        {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(
                        Array(snapshot.issues.enumerated()),
                        id: \.offset
                    ) { _, issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.relativePath)
                                    .font(.body.weight(.medium))
                                Text(issue.message)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
            } label: {
                Label("Indexing Warnings", systemImage: "exclamationmark.triangle")
                    .font(.title3.weight(.semibold))
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "Local documents and fetched page text are stored on this Mac. When OpenAI features are available, selecting a resume sends its text to OpenAI once to draft the visible editable interview description; preparing evidence sends the configured source text. Reading a public URL sends that URL to Jina Reader, then optionally to Exa if the other paths fail. The browser companion receives citations, not the source files or setup text.",
            systemImage: "lock.shield.fill"
        )
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }

    private func assistantUse(
        title: String,
        icon: String,
        color: Color,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var phaseColor: Color {
        switch controller.referenceLibraryState.phase {
        case .notConfigured:
            .secondary
        case .scanning:
            .orange
        case .ready:
            .green
        case .failed:
            .red
        }
    }

    private func webSourceColor(_ status: ReferenceWebSourceStatus) -> Color {
        switch status {
        case .pending:
            .secondary
        case .fetching:
            .orange
        case .ready:
            .green
        case .keyRequired:
            .orange
        case .failed:
            .red
        }
    }

    private func webSourceIcon(_ status: ReferenceWebSourceStatus) -> String {
        switch status {
        case .pending:
            "clock"
        case .fetching:
            "arrow.triangle.2.circlepath"
        case .ready:
            "checkmark.circle.fill"
        case .keyRequired:
            "key.horizontal"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var purpose: CapturePurpose {
        controller.preparationPurpose
    }

    private var contextPromptBinding: Binding<String> {
        switch purpose {
        case .meeting:
            $controller.meetingContextPrompt
        case .interview:
            interviewContextBinding
        }
    }

    private var interviewContextBinding: Binding<String> {
        Binding(
            get: { controller.interviewContextPrompt },
            set: controller.updateInterviewContextPrompt
        )
    }

    private var answerModeBinding: Binding<AssistantAnswerMode> {
        Binding(
            get: { controller.assistantAnswerMode },
            set: { mode in
                if mode == .plausibleRehearsal {
                    showsPlausibleRehearsalConfirmation = true
                } else {
                    controller.setAssistantAnswerModePreference(.grounded)
                }
            }
        )
    }

    private var earlyBridgeBinding: Binding<Bool> {
        Binding(
            get: { controller.assistantEarlyBridgeEnabled },
            set: { controller.setAssistantEarlyBridgePreference($0) }
        )
    }

    private func compactCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return String(count)
    }
}

private extension ReferenceDocumentKind {
    var title: String {
        switch self {
        case .text:
            "Text"
        case .markdown:
            "Markdown"
        case .structuredText:
            "Structured text"
        case .richText:
            "Rich text"
        case .pdf:
            "PDF"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf:
            "doc.richtext.fill"
        case .markdown, .richText:
            "doc.text.fill"
        case .text, .structuredText:
            "doc.plaintext.fill"
        }
    }
}

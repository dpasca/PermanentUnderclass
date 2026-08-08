import AppKit
import SwiftUI

enum PUnderclassWindow {
    static let preparation = "capture-preparation"
}

struct ReferenceMaterialView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sessionGuidanceSection
                    folderSection
                    recognitionHintsSection
                    assistantUsesSection
                    documentSection
                    issueSection
                    privacyNote
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 800, minHeight: 700)
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
                    purpose == .meeting
                        ? "Give transcription and Meeting Assistant the context they need before the conversation starts."
                        : "Give transcription and Answer Mirror the role context they need before the interview starts."
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

    private var sessionGuidanceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        purpose == .meeting
                            ? "What is this meeting about?"
                            : "What role and interview should the assistant expect?"
                    )
                    .font(.title3.weight(.semibold))
                    Text(
                        purpose == .meeting
                            ? "Include the participants, purpose, likely topics, and any important constraints. This guides both transcription and Meeting Assistant."
                            : "Include the company, role, interview stage, and likely topics. This guides both transcription and Answer Mirror."
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
                                "PUnderclass indexes supported files locally and watches the folder for changes."
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
                    detail: "Uses supported experience and role context without inventing personal claims."
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
            "Session guidance and document contents stay owned by the Mac host and are sent only as model context when a cloud assistant or generated replay is used. The browser companion receives citations, not the source files or setup text.",
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

    private var purpose: CapturePurpose {
        controller.preparationPurpose
    }

    private var contextPromptBinding: Binding<String> {
        switch purpose {
        case .meeting:
            $controller.meetingContextPrompt
        case .interview:
            $controller.interviewContextPrompt
        }
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

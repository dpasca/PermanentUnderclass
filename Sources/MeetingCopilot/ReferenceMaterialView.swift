import AppKit
import SwiftUI

enum PUnderclassWindow {
    static let referenceMaterial = "reference-material"
}

struct ReferenceMaterialView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    folderSection
                    assistantUsesSection
                    documentSection
                    issueSection
                    privacyNote
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Reference Material")
                    .font(.title.weight(.semibold))
                Text(
                    "One shared document library for Meeting Assistant, Answer Mirror, and generated replays."
                )
                .font(.body)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if controller.referenceLibraryState.phase == .scanning {
                ProgressView()
                    .controlSize(.regular)
            }
            Text(controller.referenceLibraryState.phaseLabel)
                .font(.body.weight(.medium))
                .foregroundStyle(phaseColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var folderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
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
            Label("Source Folder", systemImage: "folder")
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
            "Document contents stay in the Mac host and are sent only as model context when a cloud assistant or generated replay is used. The browser companion receives citations, not the source files.",
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

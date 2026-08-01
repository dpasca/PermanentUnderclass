import SwiftUI

struct QuickDictationHistoryView: View {
    @ObservedObject var controller: MeetingController
    @State private var copiedEntryID: UUID?
    @State private var isConfirmingEraseAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let error = controller.errorMessage {
                errorBanner(error)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

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
            Text("Final dictation text is saved locally on this Mac until you erase it. Audio is not retained.")
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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Quick Dictation History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 24, weight: .semibold))
                Text(historyCountDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                isConfirmingEraseAll = true
            } label: {
                Label("Erase All", systemImage: "trash")
            }
            .disabled(controller.quickDictationHistory.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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

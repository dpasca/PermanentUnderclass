import AppKit
import Combine
import Foundation

enum AppTab: Hashable {
    case quickDictation
    case meeting
    case interview
}

enum SlashCommandCategory: String, CaseIterable, Identifiable {
    case navigation = "Navigation"
    case capture = "Capture"
    case transcript = "Transcripts"
    case dictation = "Quick Dictation"
    case replay = "Replays & Assistant"
    case preparation = "Preparation"
    case audio = "Audio & Models"
    case settings = "Settings"
    case troubleshooting = "Troubleshooting"

    var id: String { rawValue }
}

struct SlashCommandAvailability: Equatable {
    let unavailableReason: String?

    static let available = SlashCommandAvailability(unavailableReason: nil)

    static func unavailable(_ reason: String) -> SlashCommandAvailability {
        SlashCommandAvailability(unavailableReason: reason)
    }

    var isAvailable: Bool {
        unavailableReason == nil
    }
}

struct SlashCommandConfirmation: Equatable {
    let title: String
    let message: String
    let confirmButton: String
}

struct SlashCommandParameterPicker {
    let prompt: String
    let emptyTitle: String
    let emptyDescription: String
    let commands: @MainActor () -> [SlashCommand]
}

enum SlashCommandKind {
    case action
    case help
    case parameterized(SlashCommandParameterPicker)
}

struct SlashCommand: Identifiable {
    let id: String
    let name: String
    let argument: String?
    let title: String
    let description: String
    let category: SlashCommandCategory
    let systemImage: String
    let keywords: [String]
    let availability: SlashCommandAvailability
    let confirmation: SlashCommandConfirmation?
    let kind: SlashCommandKind
    let invocation: String
    fileprivate let searchableText: String
    let perform: @MainActor () -> Void

    init(
        id: String,
        name: String,
        argument: String? = nil,
        title: String,
        description: String,
        category: SlashCommandCategory,
        systemImage: String,
        keywords: [String] = [],
        availability: SlashCommandAvailability = .available,
        confirmation: SlashCommandConfirmation? = nil,
        kind: SlashCommandKind = .action,
        perform: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.name = name
        self.argument = argument
        self.title = title
        self.description = description
        self.category = category
        self.systemImage = systemImage
        self.keywords = keywords
        self.availability = availability
        self.confirmation = confirmation
        self.kind = kind
        if let argument, !argument.isEmpty {
            let escaped = argument.replacingOccurrences(
                of: "\"",
                with: "\\\""
            )
            invocation = "/\(name) \"\(escaped)\""
        } else {
            invocation = "/\(name)"
        }
        searchableText = (
            [name, invocation, title, description, category.rawValue]
                + keywords
        )
        .joined(separator: " ")
        .lowercased()
        self.perform = perform
    }

    var parameterPicker: SlashCommandParameterPicker? {
        guard case let .parameterized(picker) = kind else { return nil }
        return picker
    }

    var isHelp: Bool {
        guard case .help = kind else { return false }
        return true
    }
}

enum SlashCommandMatcher {
    static func matches(
        _ commands: [SlashCommand],
        query: String
    ) -> [SlashCommand] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return commands }

        return commands.enumerated().compactMap { index, command in
            score(command, query: normalizedQuery).map {
                (command: command, score: $0, index: index)
            }
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.command.availability.isAvailable
                != rhs.command.availability.isAvailable
            {
                return lhs.command.availability.isAvailable
            }
            return lhs.index < rhs.index
        }
        .map(\.command)
    }

    static func normalize(_ query: String) -> String {
        var value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "/" {
            value.removeFirst()
        }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func score(
        _ command: SlashCommand,
        query: String
    ) -> Int? {
        let name = command.name.lowercased()
        let title = command.title.lowercased()
        let invocation = normalize(command.invocation)

        if query == name || query == invocation { return 0 }
        if name.hasPrefix(query) { return 10 + name.count - query.count }
        if invocation.hasPrefix(query) {
            return 20 + invocation.count - query.count
        }
        if title.hasPrefix(query) { return 40 + title.count - query.count }

        if let range = command.searchableText.range(of: query) {
            return 80 + command.searchableText.distance(
                from: command.searchableText.startIndex,
                to: range.lowerBound
            )
        }

        let tokens = query.split(whereSeparator: \Character.isWhitespace)
        if !tokens.isEmpty {
            var tokenScore = 0
            for token in tokens {
                guard let range = command.searchableText.range(
                    of: String(token)
                ) else {
                    tokenScore = -1
                    break
                }
                tokenScore += command.searchableText.distance(
                    from: command.searchableText.startIndex,
                    to: range.lowerBound
                )
            }
            if tokenScore >= 0 { return 120 + tokenScore }
        }

        return fuzzySubsequenceScore(
            query,
            candidate: "\(name) \(title)"
        ).map { 240 + $0 }
    }

    private static func fuzzySubsequenceScore(
        _ query: String,
        candidate: String
    ) -> Int? {
        var candidateIndex = candidate.startIndex
        var previousMatch: String.Index?
        var gapScore = 0

        for character in query {
            guard let match = candidate[candidateIndex...].firstIndex(
                of: character
            ) else {
                return nil
            }
            if let previousMatch {
                gapScore += candidate.distance(from: previousMatch, to: match) - 1
            } else {
                gapScore += candidate.distance(
                    from: candidate.startIndex,
                    to: match
                )
            }
            previousMatch = match
            candidateIndex = candidate.index(after: match)
        }
        return gapScore
    }
}

struct SettingsNavigationRequest: Equatable {
    let id = UUID()
    let section: SettingsSection
}

struct PreparationNavigationRequest: Equatable {
    let id = UUID()
    let purpose: CapturePurpose
}

@MainActor
final class ApplicationNavigation: ObservableObject {
    @Published var selectedTab: AppTab
    @Published var expandedTranscriptPurpose: CapturePurpose?
    @Published private(set) var settingsRequest: SettingsNavigationRequest?
    @Published private(set) var preparationRequest:
        PreparationNavigationRequest?

    init(documentationDemoMode: DocumentationDemoMode? = nil) {
        switch documentationDemoMode {
        case .meeting:
            selectedTab = .meeting
        case .interview:
            selectedTab = .interview
        case .quickDictation, nil:
            selectedTab = .quickDictation
        }
    }

    func show(_ tab: AppTab) {
        selectedTab = tab
        focusMainWindow()
    }

    func openSettings(_ section: SettingsSection) {
        settingsRequest = SettingsNavigationRequest(section: section)
    }

    func openPreparation(for purpose: CapturePurpose) {
        preparationRequest = PreparationNavigationRequest(purpose: purpose)
    }

    func closePreparationAndShow(_ tab: AppTab) {
        for window in NSApplication.shared.windows
            where window.title == "Meeting & Interview Preparation"
        {
            window.close()
        }
        show(tab)
    }

    private func focusMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard let window = NSApplication.shared.windows.first(where: {
            $0.title == "PermanentUnderclass" && $0.canBecomeMain
        }) else {
            return
        }
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SlashCommandRegistry {
    private let controller: MeetingController
    private let navigation: ApplicationNavigation

    init(
        controller: MeetingController,
        navigation: ApplicationNavigation
    ) {
        self.controller = controller
        self.navigation = navigation
    }

    func commands() -> [SlashCommand] {
        var commands: [SlashCommand] = []

        func add(
            _ id: String,
            _ name: String,
            argument: String? = nil,
            title: String,
            description: String,
            category: SlashCommandCategory,
            systemImage: String,
            keywords: [String] = [],
            unavailableReason: String? = nil,
            confirmation: SlashCommandConfirmation? = nil,
            kind: SlashCommandKind = .action,
            perform: @escaping @MainActor () -> Void
        ) {
            commands.append(
                SlashCommand(
                    id: id,
                    name: name,
                    argument: argument,
                    title: title,
                    description: description,
                    category: category,
                    systemImage: systemImage,
                    keywords: keywords,
                    availability: unavailableReason.map {
                        .unavailable($0)
                    } ?? .available,
                    confirmation: confirmation,
                    kind: kind,
                    perform: perform
                )
            )
        }

        add(
            "help",
            "help",
            title: "Slash command help",
            description: "Show command syntax, keyboard controls, and availability guidance.",
            category: .navigation,
            systemImage: "questionmark.circle",
            keywords: ["instructions", "keyboard", "autocomplete"],
            kind: .help,
            perform: {}
        )

        addNavigationCommands(using: add)
        addCaptureCommands(using: add)
        addTranscriptCommands(using: add)
        addReplayCommands(using: add)
        addDictationCommands(using: add)
        addPreparationCommands(using: add)
        addAudioAndModelCommands(using: add)
        addSettingsCommands(using: add)
        addTroubleshootingCommands(using: add)
        return commands
    }

    private typealias AddCommand = (
        String,
        String,
        String?,
        String,
        String,
        SlashCommandCategory,
        String,
        [String],
        String?,
        SlashCommandConfirmation?,
        SlashCommandKind,
        @escaping @MainActor () -> Void
    ) -> Void

    private func addNavigationCommands(using add: AddCommand) {
        let destinations: [(String, String, String, AppTab, String)] = [
            (
                "view.quick-dictation",
                "view.quick-dictation",
                "Show Quick Dictation",
                .quickDictation,
                "mic.badge.plus"
            ),
            (
                "view.meeting",
                "view.meeting",
                "Show Meeting",
                .meeting,
                "person.2.fill"
            ),
            (
                "view.interview",
                "view.interview",
                "Show Interview",
                .interview,
                "person.crop.rectangle"
            )
        ]
        for (id, name, title, tab, image) in destinations {
            add(
                id,
                name,
                nil,
                title,
                "Bring the main window forward and select this workspace.",
                .navigation,
                image,
                ["tab", "open", "go"],
                nil,
                nil,
                .action
            ) { [navigation] in
                navigation.show(tab)
            }
        }

        for purpose in CapturePurpose.allCases {
            add(
                "prepare.\(purpose.rawValue)",
                "prepare.\(purpose.rawValue)",
                nil,
                "Prepare \(purpose.title)",
                "Open guidance, recognition hints, and reference material for \(purpose.title.lowercased()).",
                .navigation,
                "checklist",
                ["setup", "references", "context"],
                nil,
                nil,
                .action
            ) { [navigation] in
                navigation.openPreparation(for: purpose)
            }
        }

        for section in SettingsSection.allCases {
            let commandName = section == .openAI
                ? "settings.api-keys"
                : "settings.\(section.rawValue.lowercased())"
            add(
                commandName,
                commandName,
                nil,
                "Open \(section.title) Settings",
                "Open the \(section.title) section in Settings.",
                .navigation,
                section.systemImage,
                ["preferences", "configure"],
                nil,
                nil,
                .action
            ) { [navigation] in
                navigation.openSettings(section)
            }
        }
    }

    private func addCaptureCommands(using add: AddCommand) {
        for purpose in CapturePurpose.allCases {
            add(
                "capture.\(purpose.rawValue).start",
                "capture.\(purpose.rawValue).start",
                nil,
                "Start \(purpose.title) Capture",
                "Capture and transcribe both sides of a \(purpose.title.lowercased()).",
                .capture,
                "waveform",
                ["listen", "record", "begin"],
                captureStartUnavailableReason(for: purpose),
                nil,
                .action
            ) { [controller, navigation] in
                navigation.show(purpose == .meeting ? .meeting : .interview)
                controller.startCapture(for: purpose)
            }

            add(
                "capture.\(purpose.rawValue).context.apply",
                "capture.\(purpose.rawValue).context.apply",
                nil,
                "Apply \(purpose.title) Context",
                "Validate the current guidance and send it to the active capture when needed.",
                .capture,
                "text.alignleft",
                ["update", "prompt", "guidance"],
                contextUnavailableReason(for: purpose),
                nil,
                .action
            ) { [controller] in
                controller.applyContext(for: purpose)
            }

            let isExpanded = navigation.expandedTranscriptPurpose == purpose
            add(
                "transcript.\(purpose.rawValue).expand",
                "transcript.\(purpose.rawValue).expand",
                nil,
                "Expand \(purpose.title) Transcript",
                "Hide capture controls and give the transcript the full workspace.",
                .capture,
                "arrow.up.left.and.arrow.down.right",
                ["fullscreen", "focus"],
                isExpanded ? "The \(purpose.title.lowercased()) transcript is already expanded." : nil,
                nil,
                .action
            ) { [navigation] in
                navigation.expandedTranscriptPurpose = purpose
                navigation.show(purpose == .meeting ? .meeting : .interview)
            }
            add(
                "transcript.\(purpose.rawValue).collapse",
                "transcript.\(purpose.rawValue).collapse",
                nil,
                "Restore \(purpose.title) Controls",
                "Show capture controls above the transcript again.",
                .capture,
                "arrow.down.right.and.arrow.up.left",
                ["collapse", "controls"],
                isExpanded ? nil : "The \(purpose.title.lowercased()) controls are already visible.",
                nil,
                .action
            ) { [navigation] in
                navigation.expandedTranscriptPurpose = nil
                navigation.show(purpose == .meeting ? .meeting : .interview)
            }
        }

        add(
            "capture.stop",
            "capture.stop",
            nil,
            "Stop Live Capture",
            "Stop the active meeting or interview and finalize its transcript.",
            .capture,
            "stop.fill",
            ["finish", "end"],
            controller.isListening ? nil : "No live capture is running.",
            nil,
            .action
        ) { [controller] in
            controller.stopCapture()
        }

        add(
            "capture.finish-my-turn",
            "capture.finish-my-turn",
            nil,
            "Finish My Current Turn",
            "Commit your current local speech turn without waiting for silence.",
            .capture,
            "forward.end.fill",
            ["commit", "speaker", "local"],
            controller.isListening ? nil : "Start a live capture first.",
            nil,
            .action
        ) { [controller] in
            controller.finalizeLocalTurn()
        }
    }

    private func addTranscriptCommands(using add: AddCommand) {
        for purpose in CapturePurpose.allCases {
            let turns = controller.transcript(for: purpose)
            let emptyReason = turns.isEmpty
                ? "The \(purpose.title.lowercased()) transcript is empty."
                : nil
            add(
                "transcript.\(purpose.rawValue).copy",
                "transcript.\(purpose.rawValue).copy",
                nil,
                "Copy \(purpose.title) Transcript",
                "Copy the complete \(purpose.title.lowercased()) transcript to the clipboard.",
                .transcript,
                "doc.on.doc",
                ["clipboard", "text"],
                emptyReason,
                nil,
                .action
            ) { [controller] in
                controller.copyTranscript(for: purpose)
            }
            add(
                "transcript.\(purpose.rawValue).export",
                "transcript.\(purpose.rawValue).export",
                nil,
                "Export \(purpose.title) Transcript",
                "Choose a text file and save the complete transcript.",
                .transcript,
                "square.and.arrow.up",
                ["save", "file", "txt"],
                emptyReason,
                nil,
                .action
            ) { [controller] in
                controller.exportTranscript(for: purpose)
            }
            add(
                "transcript.\(purpose.rawValue).clear",
                "transcript.\(purpose.rawValue).clear",
                nil,
                "Clear \(purpose.title) Transcript",
                "Remove every visible \(purpose.title.lowercased()) transcript turn.",
                .transcript,
                "trash",
                ["delete", "erase"],
                emptyReason,
                SlashCommandConfirmation(
                    title: "Clear the \(purpose.title.lowercased()) transcript?",
                    message: "This removes every visible turn from the current \(purpose.title.lowercased()) transcript.",
                    confirmButton: "Clear Transcript"
                ),
                .action
            ) { [controller] in
                controller.clearTranscript(for: purpose)
            }
        }

        add(
            "transcript.interview.archive.reveal",
            "transcript.interview.archive.reveal",
            nil,
            "Reveal Latest Interview Archive",
            "Show the locally saved interview transcript and suggestion history in Finder.",
            .transcript,
            "folder",
            ["finder", "json", "history"],
            controller.latestInterviewArchiveURL == nil
                ? "No interview archive has been saved yet."
                : nil,
            nil,
            .action
        ) { [controller] in
            controller.revealLatestInterviewArchive()
        }
    }

    private func addReplayCommands(using add: AddCommand) {
        for purpose in CapturePurpose.allCases {
            let readiness = controller.canStartGeneratedReplay(for: purpose)
                ? nil
                : controller.generatedReplayReadinessDetail(for: purpose)
            add(
                "replay.\(purpose.rawValue).run",
                "replay.\(purpose.rawValue).run",
                nil,
                "Run Generated \(purpose.title) Replay",
                "Open the assistant display and run the cached grounded replay.",
                .replay,
                "play.fill",
                ["mock", "practice", "scenario"],
                readiness,
                nil,
                .action
            ) { [controller, navigation] in
                navigation.show(purpose == .meeting ? .meeting : .interview)
                controller.openCompanionDisplay()
                controller.startGeneratedReplay(for: purpose)
            }
            add(
                "replay.\(purpose.rawValue).regenerate",
                "replay.\(purpose.rawValue).regenerate",
                nil,
                purpose == .meeting ? "Generate New Meeting Scenario" : "Generate New Interview Questions",
                "Discard the cached scenario and generate a new grounded replay.",
                .replay,
                "arrow.triangle.2.circlepath",
                ["new", "mock", "practice"],
                readiness,
                nil,
                .action
            ) { [controller, navigation] in
                navigation.show(purpose == .meeting ? .meeting : .interview)
                controller.openCompanionDisplay()
                controller.regenerateGeneratedReplay(for: purpose)
            }
        }

        add(
            "replay.stop",
            "replay.stop",
            nil,
            "Stop Generated Replay",
            "Stop the active meeting, interview, or web-search replay.",
            .replay,
            "stop.fill",
            ["finish", "end", "mock"],
            controller.syntheticInterviewState.isActive
                ? nil
                : "No generated replay is running.",
            nil,
            .action
        ) { [controller] in
            controller.stopGeneratedReplay()
        }

        add(
            "assistant.web-search.test",
            "assistant.web-search.test",
            nil,
            "Test Answer Mirror Web Search",
            "Run one audible current-information question and require cited hosted search.",
            .replay,
            "globe",
            ["interview", "sources", "live"],
            controller.canStartWebSearchTest()
                ? nil
                : controller.webSearchTestReadinessDetail(),
            nil,
            .action
        ) { [controller, navigation] in
            navigation.show(.interview)
            controller.startWebSearchTest()
        }

        add(
            "assistant.display.open",
            "assistant.display.open",
            nil,
            "Open Assistant Display",
            "Open the local companion display in the default browser.",
            .replay,
            "rectangle.on.rectangle",
            ["companion", "browser", "transcript"],
            controller.companionGatewayEndpoint == nil
                ? controller.companionGatewayError
                    ?? "The companion display server is still starting."
                : nil,
            nil,
            .action
        ) { [controller] in
            controller.openCompanionDisplay()
        }

        add(
            "assistant.display.copy-lan-address",
            "assistant.display.copy-lan-address",
            nil,
            "Copy Assistant Display LAN Address",
            "Copy the network address for opening the companion display on another device.",
            .replay,
            "network",
            ["clipboard", "url", "wifi"],
            controller.companionGatewayEndpoint?.preferredLANURL == nil
                ? "No LAN address is available. Connect this Mac to Wi-Fi or Ethernet."
                : nil,
            nil,
            .action
        ) { [controller] in
            controller.copyCompanionLANAddress()
        }
    }

    private func addDictationCommands(using add: AddCommand) {
        addBooleanCommands(
            idPrefix: "dictation",
            title: "Quick Dictation",
            description: "the global hold-Command-and-Option dictation shortcut",
            category: .dictation,
            systemImage: "mic.badge.plus",
            isEnabled: controller.dictationEnabled,
            setter: controller.setDictationEnabled,
            using: add
        )
        addBooleanCommands(
            idPrefix: "dictation.preview",
            title: "Dictation Preview",
            description: "the live Quick Dictation preview overlay",
            category: .dictation,
            systemImage: "text.bubble",
            isEnabled: controller.dictationPreviewEnabled,
            setter: controller.setDictationPreviewEnabled,
            using: add
        )
        addBooleanCommands(
            idPrefix: "dictation.cleanup",
            title: "Dictation Cleanup",
            description: "automatic cleanup of completed Quick Dictation text",
            category: .dictation,
            systemImage: "wand.and.stars",
            isEnabled: controller.dictationCleanupEnabled,
            setter: controller.setDictationCleanupEnabled,
            using: add
        )

        add(
            "dictation.permissions.check",
            "dictation.permissions.check",
            nil,
            "Check Quick Dictation Access",
            "Request or refresh Accessibility and microphone permissions.",
            .dictation,
            "lock.open",
            ["grant", "privacy", "microphone"],
            nil,
            nil,
            .action
        ) { [controller] in
            controller.requestDictationPermissions()
        }

        add(
            "dictation.history.erase-all",
            "dictation.history.erase-all",
            nil,
            "Erase All Quick Dictations",
            "Permanently remove every saved Quick Dictation text entry.",
            .dictation,
            "trash",
            ["delete", "clear", "history"],
            controller.quickDictationHistory.isEmpty
                ? "Quick Dictation history is already empty."
                : nil,
            SlashCommandConfirmation(
                title: "Erase all quick dictations?",
                message: "This permanently removes every saved Quick Dictation from this Mac.",
                confirmButton: "Erase All"
            ),
            .action
        ) { [controller] in
            controller.deleteAllQuickDictations()
        }

        let historyUnavailableReason = controller.quickDictationHistory.isEmpty
            ? "No saved Quick Dictations are available."
            : nil
        add(
            "dictation.history.copy",
            "dictation.history.copy",
            nil,
            "Copy Saved Dictation",
            "Choose one saved Quick Dictation, then copy its text to the clipboard.",
            .dictation,
            "doc.on.doc",
            ["history", "clipboard", "saved", "recent"],
            historyUnavailableReason,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search saved dictations",
                    emptyTitle: "No saved dictations",
                    emptyDescription: "Quick Dictation history is empty."
                ) { [controller] in
                    controller.quickDictationHistory.map { entry in
                        let argument = self.historyArgument(
                            date: entry.createdAt,
                            text: entry.text
                        )
                        return SlashCommand(
                            id: "dictation.history.copy.\(entry.id.uuidString)",
                            name: "dictation.history.copy",
                            argument: argument,
                            title: "Copy Saved Dictation",
                            description: entry.text,
                            category: .dictation,
                            systemImage: "doc.on.doc",
                            keywords: ["history", "clipboard"]
                        ) { [controller] in
                            _ = controller.copyQuickDictationToClipboard(entry)
                        }
                    }
                }
            )
        ) {}

        add(
            "dictation.history.delete",
            "dictation.history.delete",
            nil,
            "Delete Saved Dictation",
            "Choose one saved Quick Dictation, then permanently remove it.",
            .dictation,
            "trash",
            ["history", "erase", "saved", "recent"],
            historyUnavailableReason,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search saved dictations",
                    emptyTitle: "No saved dictations",
                    emptyDescription: "Quick Dictation history is empty."
                ) { [controller] in
                    controller.quickDictationHistory.map { entry in
                        let argument = self.historyArgument(
                            date: entry.createdAt,
                            text: entry.text
                        )
                        return SlashCommand(
                            id: "dictation.history.delete.\(entry.id.uuidString)",
                            name: "dictation.history.delete",
                            argument: argument,
                            title: "Delete Saved Dictation",
                            description: entry.text,
                            category: .dictation,
                            systemImage: "trash",
                            keywords: ["history", "erase"],
                            confirmation: SlashCommandConfirmation(
                                title: "Delete this quick dictation?",
                                message: entry.text,
                                confirmButton: "Delete"
                            )
                        ) { [controller] in
                            controller.deleteQuickDictation(entry)
                        }
                    }
                }
            )
        ) {}

        let noRecoveriesReason = controller.recoverableDictations.isEmpty
            ? "No retained Quick Dictation recordings are available."
            : nil
        let recoveryBusyReason = controller.isDictationBusy
            ? "Finish the current Quick Dictation operation first."
            : nil
        add(
            "dictation.recovery.retry",
            "dictation.recovery.retry",
            nil,
            "Retry Retained Dictation",
            "Choose a retained recording to transcribe with the selected model.",
            .dictation,
            "arrow.clockwise",
            ["recording", "wav", "failed"],
            recoveryBusyReason ?? noRecoveriesReason,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search retained recordings",
                    emptyTitle: "No retained recordings",
                    emptyDescription: "There are no failed dictations waiting to be retried."
                ) { [controller] in
                    controller.recoverableDictations.map { recovery in
                        SlashCommand(
                            id: "dictation.recovery.retry.\(recovery.id.uuidString)",
                            name: "dictation.recovery.retry",
                            argument: self.recoveryArgument(recovery),
                            title: "Retry Retained Dictation",
                            description: recovery.lastError
                                ?? "Transcribe this safely retained WAV.",
                            category: .dictation,
                            systemImage: "arrow.clockwise",
                            keywords: ["recording", "wav", "failed"],
                            availability: controller.isDictationBusy
                                ? .unavailable(
                                    "Finish the current Quick Dictation operation first."
                                )
                                : .available
                        ) { [controller] in
                            controller.retryQuickDictation(recovery)
                        }
                    }
                }
            )
        ) {}

        add(
            "dictation.recovery.reveal",
            "dictation.recovery.reveal",
            nil,
            "Reveal Retained Dictation",
            "Choose a retained recording to show in Finder.",
            .dictation,
            "folder",
            ["recording", "wav", "finder"],
            noRecoveriesReason,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search retained recordings",
                    emptyTitle: "No retained recordings",
                    emptyDescription: "There are no retained WAV recordings."
                ) { [controller] in
                    controller.recoverableDictations.map { recovery in
                        SlashCommand(
                            id: "dictation.recovery.reveal.\(recovery.id.uuidString)",
                            name: "dictation.recovery.reveal",
                            argument: self.recoveryArgument(recovery),
                            title: "Reveal Retained Dictation",
                            description: "Show this retained WAV recording in Finder.",
                            category: .dictation,
                            systemImage: "folder",
                            keywords: ["recording", "wav", "finder"]
                        ) { [controller] in
                            controller.revealQuickDictation(recovery)
                        }
                    }
                }
            )
        ) {}

        add(
            "dictation.recovery.delete",
            "dictation.recovery.delete",
            nil,
            "Delete Retained Dictation",
            "Choose a retained recording to permanently remove.",
            .dictation,
            "trash",
            ["recording", "wav", "erase"],
            recoveryBusyReason ?? noRecoveriesReason,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search retained recordings",
                    emptyTitle: "No retained recordings",
                    emptyDescription: "There are no retained WAV recordings."
                ) { [controller] in
                    controller.recoverableDictations.map { recovery in
                        SlashCommand(
                            id: "dictation.recovery.delete.\(recovery.id.uuidString)",
                            name: "dictation.recovery.delete",
                            argument: self.recoveryArgument(recovery),
                            title: "Delete Retained Dictation",
                            description: "Permanently remove this retained WAV recording.",
                            category: .dictation,
                            systemImage: "trash",
                            keywords: ["recording", "wav", "erase"],
                            availability: controller.isDictationBusy
                                ? .unavailable(
                                    "Finish the current Quick Dictation operation first."
                                )
                                : .available,
                            confirmation: SlashCommandConfirmation(
                                title: "Delete retained recording?",
                                message: "The recording cannot be retried after deletion.",
                                confirmButton: "Delete Recording"
                            )
                        ) { [controller] in
                            controller.deleteQuickDictation(recovery)
                        }
                    }
                }
            )
        ) {}
    }

    private func addPreparationCommands(using add: AddCommand) {
        let hasFolder = controller.referenceLibraryState.folderURL != nil
        add(
            "references.folder.choose",
            "references.folder.choose",
            nil,
            hasFolder ? "Change Reference Folder" : "Choose Reference Folder",
            "Choose the local document library shared by assistants and generated replays.",
            .preparation,
            "folder.badge.plus",
            ["documents", "library", "files"],
            nil,
            nil,
            .action
        ) { [controller] in
            controller.chooseReferenceFolder()
        }
        add(
            "references.folder.reveal",
            "references.folder.reveal",
            nil,
            "Reveal Reference Folder",
            "Show the configured reference library in Finder.",
            .preparation,
            "folder",
            ["documents", "library", "finder"],
            hasFolder ? nil : "No reference folder is configured.",
            nil,
            .action
        ) { [controller] in
            controller.revealReferenceFolder()
        }
        add(
            "references.folder.rescan",
            "references.folder.rescan",
            nil,
            "Rescan Reference Folder",
            "Re-index supported files in the configured reference library.",
            .preparation,
            "arrow.clockwise",
            ["documents", "refresh", "index"],
            hasFolder ? nil : "No reference folder is configured.",
            nil,
            .action
        ) { [controller] in
            controller.rescanReferenceFolder()
        }
        add(
            "references.folder.clear",
            "references.folder.clear",
            nil,
            "Stop Using Reference Folder",
            "Disconnect the current local reference library without deleting its files.",
            .preparation,
            "folder.badge.minus",
            ["remove", "disconnect", "library"],
            hasFolder ? nil : "No reference folder is configured.",
            SlashCommandConfirmation(
                title: "Stop using the reference folder?",
                message: "The files stay on disk, but assistants and replays will no longer use this folder.",
                confirmButton: "Stop Using Folder"
            ),
            .action
        ) { [controller] in
            controller.clearReferenceFolder()
        }

        let hasResume = controller.referencePreparationState.resumeSource != nil
        let preparationWorking = controller.referencePreparationState.phase.isWorking
        add(
            "references.resume.choose",
            "references.resume.choose",
            nil,
            hasResume ? "Change Interview Resume" : "Choose Interview Resume",
            "Choose the authoritative resume used to prepare Answer Mirror evidence.",
            .preparation,
            "doc.badge.plus",
            ["cv", "interview", "career"],
            preparationWorking ? "Wait for evidence preparation to finish." : nil,
            nil,
            .action
        ) { [controller] in
            controller.chooseResumeFile()
        }
        add(
            "references.resume.reveal",
            "references.resume.reveal",
            nil,
            "Reveal Interview Resume",
            "Show the selected resume in Finder.",
            .preparation,
            "doc.text.magnifyingglass",
            ["cv", "finder", "career"],
            hasResume ? nil : "No interview resume is selected.",
            nil,
            .action
        ) { [controller] in
            controller.revealResumeFile()
        }
        add(
            "references.resume.clear",
            "references.resume.clear",
            nil,
            "Stop Using Interview Resume",
            "Remove the selected resume from interview preparation without deleting the file.",
            .preparation,
            "doc.badge.minus",
            ["cv", "remove", "career"],
            !hasResume
                ? "No interview resume is selected."
                : preparationWorking
                    ? "Wait for evidence preparation to finish."
                    : nil,
            SlashCommandConfirmation(
                title: "Stop using this resume?",
                message: "The file stays on disk, but prepared interview context will be reset.",
                confirmButton: "Stop Using Resume"
            ),
            .action
        ) { [controller] in
            controller.clearResumeFile()
        }

        add(
            "references.resume.suggest-context",
            "references.resume.suggest-context",
            nil,
            "Suggest Interview Description from Resume",
            "Draft editable interview context from the selected resume.",
            .preparation,
            "wand.and.stars",
            ["role", "job", "context", "ai"],
            suggestContextUnavailableReason(),
            nil,
            .action
        ) { [controller] in
            controller.suggestInterviewContextFromResume()
        }
        add(
            "references.evidence.prepare",
            "references.evidence.prepare",
            nil,
            controller.referencePreparationState.pack == nil
                ? "Prepare Interview Evidence"
                : "Rebuild Interview Evidence",
            "Build the compact, source-grounded evidence pack used by Answer Mirror.",
            .preparation,
            "sparkles",
            ["resume", "sources", "cards", "interview"],
            controller.canPrepareInterviewEvidence
                ? nil
                : controller.interviewEvidenceReadinessDetail(),
            nil,
            .action
        ) { [controller] in
            controller.prepareInterviewEvidence()
        }

        let webDraft = controller.webReferenceURLDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        add(
            "references.web.add",
            "references.web.add",
            webDraft.isEmpty ? nil : webDraft,
            "Add Entered Web Reference",
            "Add the URL currently entered in Interview Preparation as a supporting source.",
            .preparation,
            "plus",
            ["url", "portfolio", "profile", "source"],
            webDraft.isEmpty
                ? "Enter a URL in Interview Preparation first."
                : preparationWorking
                    ? "Wait for evidence preparation to finish."
                    : nil,
            nil,
            .action
        ) { [controller] in
            controller.addReferenceWebSource()
        }

        let noWebSourcesReason = controller.referencePreparationState.webSources
            .isEmpty
            ? "No web references have been added."
            : nil
        add(
            "references.web.remove",
            "references.web.remove",
            nil,
            "Remove Web Reference",
            "Choose a supporting public web source to remove from interview preparation.",
            .preparation,
            "trash",
            ["url", "source", "portfolio", "profile"],
            preparationWorking
                ? "Wait for evidence preparation to finish."
                : noWebSourcesReason,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search web references",
                    emptyTitle: "No web references",
                    emptyDescription: "Add a web reference before trying to remove one."
                ) { [controller] in
                    controller.referencePreparationState.webSources.map {
                        source in
                        let title = source.title.flatMap {
                            $0.isEmpty ? nil : $0
                        } ?? source.requestedURL
                        return SlashCommand(
                            id: "references.web.remove.\(source.id)",
                            name: "references.web.remove",
                            argument: title,
                            title: "Remove Web Reference",
                            description: source.requestedURL,
                            category: .preparation,
                            systemImage: "trash",
                            keywords: [source.requestedURL, "url", "source"],
                            availability: controller.referencePreparationState
                                .phase.isWorking
                                ? .unavailable(
                                    "Wait for evidence preparation to finish."
                                )
                                : .available,
                            confirmation: SlashCommandConfirmation(
                                title: "Remove this web reference?",
                                message: source.requestedURL,
                                confirmButton: "Remove Source"
                            )
                        ) { [controller] in
                            controller.removeReferenceWebSource(id: source.id)
                        }
                    }
                }
            )
        ) {}

        let evidenceCards = controller.referencePreparationState.pack?.cards
            ?? []
        for desiredEnabledState in [true, false] {
            let action = desiredEnabledState ? "enable" : "disable"
            let matchingCards = evidenceCards.filter {
                $0.isEnabled != desiredEnabledState
            }
            let unavailableReason: String?
            if preparationWorking {
                unavailableReason = "Wait for evidence preparation to finish."
            } else if evidenceCards.isEmpty {
                unavailableReason = "No prepared evidence cards are available."
            } else if matchingCards.isEmpty {
                unavailableReason = desiredEnabledState
                    ? "All evidence cards are already enabled."
                    : "All evidence cards are already disabled."
            } else {
                unavailableReason = nil
            }
            add(
                "references.evidence.\(action)",
                "references.evidence.\(action)",
                nil,
                "\(desiredEnabledState ? "Enable" : "Disable") Evidence Card",
                "Choose prepared project evidence to \(desiredEnabledState ? "include in" : "exclude from") Answer Mirror grounding.",
                .preparation,
                desiredEnabledState ? "rectangle" : "checkmark.rectangle",
                ["card", "project", "grounding", "sources"],
                unavailableReason,
                nil,
                .parameterized(
                    SlashCommandParameterPicker(
                        prompt: "Search evidence cards",
                        emptyTitle: "No matching evidence cards",
                        emptyDescription: desiredEnabledState
                            ? "All prepared evidence is already enabled."
                            : "All prepared evidence is already disabled."
                    ) { [controller] in
                        let cards = controller.referencePreparationState.pack?
                            .cards ?? []
                        return cards.compactMap { card in
                            guard card.isEnabled != desiredEnabledState else {
                                return nil
                            }
                            return SlashCommand(
                                id: "references.evidence.\(action).\(card.id)",
                                name: "references.evidence.\(action)",
                                argument: card.projectAnchor,
                                title: "\(desiredEnabledState ? "Enable" : "Disable") Evidence Card",
                                description: card.summary,
                                category: .preparation,
                                systemImage: desiredEnabledState
                                    ? "rectangle"
                                    : "checkmark.rectangle",
                                keywords: [card.role, card.summary],
                                availability: controller
                                    .referencePreparationState.phase.isWorking
                                    ? .unavailable(
                                        "Wait for evidence preparation to finish."
                                    )
                                    : .available
                            ) { [controller] in
                                controller.setPreparedReferenceEnabled(
                                    id: card.id,
                                    enabled: desiredEnabledState
                                )
                            }
                        }
                    }
                )
            ) {}
        }

        addAnswerPreferenceCommands(using: add)
    }

    private func addAnswerPreferenceCommands(using add: AddCommand) {
        let configurationReason = assistantConfigurationUnavailableReason()
        for mode in AssistantAnswerMode.allCases {
            let isCurrent = controller.assistantAnswerMode == mode
            add(
                "assistant.answer-mode.\(mode.rawValue)",
                "assistant.answer-mode.\(mode.rawValue)",
                nil,
                "Use \(mode.title) Answers",
                mode == .grounded
                    ? "Require past-experience claims to be supported by the transcript or references."
                    : "Allow clearly labeled rehearsal drafts with plausible details that must be verified.",
                .preparation,
                mode == .grounded ? "checkmark.shield" : "wand.and.stars",
                ["interview", "answer mirror", "rehearsal"],
                isCurrent
                    ? "\(mode.title) answers are already selected."
                    : configurationReason,
                mode == .plausibleRehearsal
                    ? SlashCommandConfirmation(
                        title: "Enable Plausible Rehearsal?",
                        message: "Answer Mirror may invent modest project details for a visibly labeled rehearsal draft. Replace or verify them before using them as facts.",
                        confirmButton: "Enable Until Turned Off"
                    )
                    : nil,
                .action
            ) { [controller] in
                controller.setAssistantAnswerModePreference(mode)
            }
        }

        let earlyBridgeBaseReason = controller.assistantAnswerMode
            != .plausibleRehearsal
            ? "Early speaking bridge is available only in Plausible Rehearsal mode."
            : !controller.capability.isCloudEnabled
                ? controller.capability.lockMessage(for: .answerMirror)
                : configurationReason
        addBooleanCommands(
            idPrefix: "assistant.early-bridge",
            title: "Early Speaking Bridge",
            description: "the experimental thinking-phrase bridge for plausible interview answers",
            category: .preparation,
            systemImage: "bolt",
            isEnabled: controller.assistantEarlyBridgeEnabled,
            sharedUnavailableReason: earlyBridgeBaseReason,
            setter: controller.setAssistantEarlyBridgePreference,
            using: add
        )

        let instantTextBaseReason = controller.assistantAnswerMode
            != .grounded
            ? "Instant text is available only in Grounded answer mode."
            : controller.liveAssistantProvider != .openAI
                ? "Instant text requires OpenAI as the suggestion provider."
                : configurationReason
        for mode in LiveAssistantDeliveryMode.allCases {
            let isCurrent = controller.assistantDeliveryMode == mode
            add(
                "assistant.delivery.\(mode.rawValue)",
                "assistant.delivery.\(mode.rawValue)",
                nil,
                "Use \(mode.title) Answer Delivery",
                mode == .verified
                    ? "Show only the normal structured, verified Answer Mirror result."
                    : "Race a plain-text stream after finalization when the verified cue is still pending.",
                .preparation,
                mode == .verified ? "checkmark.seal" : "text.line.first.and.arrowtriangle.forward",
                ["interview", "instant", "stream", "verified"],
                isCurrent
                    ? "\(mode.title) delivery is already selected."
                    : mode == .instantText
                        ? instantTextBaseReason
                        : configurationReason,
                nil,
                .action
            ) { [controller] in
                controller.setAssistantDeliveryModePreference(mode)
            }
        }

        for delay in TranscriptionDelay.allCases {
            add(
                "transcription.delay.\(delay.rawValue)",
                "transcription.delay.\(delay.rawValue)",
                nil,
                "Use \(delay.rawValue.capitalized) Live Delay",
                "Set the shared live transcription accuracy and latency preference.",
                .preparation,
                "timer",
                ["speech", "latency", "accuracy"],
                controller.delay == delay
                    ? "\(delay.rawValue.capitalized) delay is already selected."
                    : nil,
                nil,
                .action
            ) { [controller] in
                controller.delay = delay
            }
        }
    }

    private func addAudioAndModelCommands(using add: AddCommand) {
        for engine in TranscriptRefinementEngine.allCases {
            add(
                "transcription.engine.\(engine.rawValue)",
                "transcription.engine.\(engine.rawValue)",
                nil,
                "Use \(engine.accuracyTitle) · \(engine.shortLabel)",
                "Select \(engine.title) for final turns and Quick Dictation.",
                .audio,
                engine.systemImage,
                [engine.title, engine.modelName, engine.locationSummary],
                engineUnavailableReason(engine),
                nil,
                .action
            ) { [controller] in
                controller.selectRefinementEngine(engine)
            }
        }

        for provider in LiveAssistantProvider.allCases {
            add(
                "assistant.provider.\(provider.rawValue)",
                "assistant.provider.\(provider.rawValue)",
                nil,
                "Use \(provider.title) for Suggestions",
                "Select \(provider.model) for Meeting Assistant and Answer Mirror cues.",
                .audio,
                "sparkles",
                [provider.keyName, provider.model],
                providerUnavailableReason(provider),
                nil,
                .action
            ) { [controller] in
                controller.setLiveAssistantProvider(provider)
            }
        }

        add(
            "audio.input.select",
            "audio.input.select",
            nil,
            "Select Microphone",
            "Choose the shared input for dictation, meetings, and interviews.",
            .audio,
            "mic.fill",
            ["device", "default", "microphone"],
            controller.inputDevices.isEmpty
                ? "No microphone devices are available."
                : nil,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search microphones",
                    emptyTitle: "No microphones",
                    emptyDescription: "Refresh audio devices and try again."
                ) { [controller] in
                    controller.inputDevices.map { device in
                        SlashCommand(
                            id: "audio.input.select.\(device.id)",
                            name: "audio.input.select",
                            argument: device.name,
                            title: "Use Microphone: \(device.name)",
                            description: "Use this input for dictation, meetings, and interviews.",
                            category: .audio,
                            systemImage: "mic.fill",
                            keywords: ["device", "default", "microphone"],
                            availability: device.id
                                == controller.selectedInputDeviceID
                                ? .unavailable(
                                    "This microphone is already selected."
                                )
                                : .available
                        ) { [controller] in
                            controller.selectInputDevice(device.id)
                        }
                    }
                }
            )
        ) {}

        add(
            "audio.output.select",
            "audio.output.select",
            nil,
            "Select System Output",
            "Choose the monitored output for meeting and interview audio.",
            .audio,
            "speaker.wave.2.fill",
            ["device", "default", "speaker"],
            controller.outputDevices.isEmpty
                ? "No output devices are available."
                : nil,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search output devices",
                    emptyTitle: "No output devices",
                    emptyDescription: "Refresh audio devices and try again."
                ) { [controller] in
                    controller.outputDevices.map { device in
                        SlashCommand(
                            id: "audio.output.select.\(device.id)",
                            name: "audio.output.select",
                            argument: device.name,
                            title: "Use System Output: \(device.name)",
                            description: "Monitor this output for meeting and interview audio.",
                            category: .audio,
                            systemImage: "speaker.wave.2.fill",
                            keywords: ["device", "default", "speaker"],
                            availability: device.id
                                == controller.selectedOutputDeviceID
                                ? .unavailable(
                                    "This output device is already selected."
                                )
                                : .available
                        ) { [controller] in
                            controller.selectOutputDevice(device.id)
                        }
                    }
                }
            )
        ) {}

        let processBusyReason = controller.isListening
            ? "Stop live capture before changing the system-audio source."
            : nil
        add(
            "audio.process.select",
            "audio.process.select",
            nil,
            "Select System-audio Source",
            "Choose all system output or one running app for transcription.",
            .audio,
            "macwindow.on.rectangle",
            ["application", "source", "process", "all system audio"],
            processBusyReason,
            nil,
            .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search running apps",
                    emptyTitle: "No audio sources",
                    emptyDescription: "Refresh running apps and try again."
                ) { [controller] in
                    let allAudio = SlashCommand(
                        id: "audio.process.select.all",
                        name: "audio.process.select",
                        argument: "All system audio",
                        title: "Transcribe All System Audio",
                        description: "Capture all system output instead of one app.",
                        category: .audio,
                        systemImage: "speaker.wave.2.fill",
                        keywords: ["application", "source", "process"],
                        availability: controller.isListening
                            ? .unavailable(
                                "Stop live capture before changing the system-audio source."
                            )
                            : controller.selectedProcessID == nil
                                ? .unavailable(
                                    "All system audio is already selected."
                                )
                                : .available
                    ) { [controller] in
                        controller.selectedProcessID = nil
                    }
                    let apps = controller.processes.map { process in
                        SlashCommand(
                            id: "audio.process.select.\(process.id)",
                            name: "audio.process.select",
                            argument: process.displayName,
                            title: "Transcribe App: \(process.name)",
                            description: "Limit system-audio transcription to this app.",
                            category: .audio,
                            systemImage: "macwindow.on.rectangle",
                            keywords: [
                                process.bundleIdentifier ?? "",
                                "application",
                                "source"
                            ],
                            availability: controller.isListening
                                ? .unavailable(
                                    "Stop live capture before changing the system-audio source."
                                )
                                : controller.selectedProcessID == process.id
                                    ? .unavailable(
                                        "This app is already selected."
                                    )
                                    : .available
                        ) { [controller] in
                            controller.selectedProcessID = process.id
                        }
                    }
                    return [allAudio] + apps
                }
            )
        ) {}
    }

    private func addSettingsCommands(using add: AddCommand) {
        addBooleanCommands(
            idPrefix: "privacy.local-only",
            title: "Local-only Mode",
            description: "the hard privacy lock that prevents all cloud requests",
            category: .settings,
            systemImage: "lock.laptopcomputer",
            isEnabled: controller.privacyLockEnabled,
            confirmationWhenEnabling: SlashCommandConfirmation(
                title: "Keep everything on this Mac?",
                message: "This stops active cloud capture and disables live partials, AI suggestions, web search, and generated replays.",
                confirmButton: "Enable Local-only Mode"
            ),
            setter: controller.setPrivacyLock,
            using: add
        )

        let openAIKey = controller.apiKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let geminiKey = controller.geminiAPIKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let exaKey = controller.exaAPIKeyDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let keyCommands: [(
            id: String,
            title: String,
            description: String,
            draft: String,
            perform: @MainActor () -> Void
        )] = [
            (
                "settings.api-key.openai.save",
                "Save OpenAI API Key",
                "Save the entered OpenAI key in this Mac's Keychain.",
                openAIKey,
                controller.saveAPIKey
            ),
            (
                "settings.api-key.gemini.save",
                "Save Gemini API Key",
                "Save the entered Gemini key in this Mac's Keychain.",
                geminiKey,
                controller.saveGeminiAPIKey
            ),
            (
                "settings.api-key.exa.save",
                "Save Exa API Key",
                "Save the entered optional Exa key in this Mac's Keychain.",
                exaKey,
                controller.saveExaAPIKey
            )
        ]
        for item in keyCommands {
            add(
                item.id,
                item.id,
                nil,
                item.title,
                item.description,
                .settings,
                "key.fill",
                ["keychain", "credentials"],
                item.draft.isEmpty
                    ? "Enter the key in API Keys Settings first."
                    : nil,
                nil,
                .action,
                item.perform
            )
        }

        add(
            "settings.api-cost.reset",
            "settings.api-cost.reset",
            nil,
            "Reset API Cost Estimate",
            "Start the local OpenAI spending estimate over from zero.",
            .settings,
            "dollarsign.circle",
            ["expenses", "counter", "usage"],
            nil,
            SlashCommandConfirmation(
                title: "Reset the API cost estimate?",
                message: "The current local estimate and its accumulation date will be replaced.",
                confirmButton: "Reset Counter"
            ),
            .action
        ) { [controller] in
            controller.resetAPIExpenses()
        }

        let externalLinks: [(String, String, String)] = [
            (
                "settings.api-key.openai.create",
                "Create an OpenAI API Key",
                "https://platform.openai.com/api-keys"
            ),
            (
                "settings.api-key.gemini.create",
                "Create a Gemini API Key",
                "https://aistudio.google.com/apikey"
            ),
            (
                "settings.api-key.exa.create",
                "Create an Exa API Key",
                "https://dashboard.exa.ai/api-keys"
            )
        ]
        for (id, title, urlString) in externalLinks {
            add(
                id,
                id,
                nil,
                title,
                "Open the provider's key-management page in the default browser.",
                .settings,
                "safari",
                ["website", "credentials", "account"],
                nil,
                nil,
                .action
            ) {
                guard let url = URL(string: urlString) else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func addTroubleshootingCommands(using add: AddCommand) {
        add(
            "audio.devices.refresh",
            "audio.devices.refresh",
            nil,
            "Refresh Audio Devices",
            "Reload available microphones and system output devices.",
            .troubleshooting,
            "arrow.clockwise",
            ["microphone", "speaker", "hardware"],
            nil,
            nil,
            .action
        ) { [controller] in
            controller.refreshAudioDevices()
        }
        add(
            "audio.processes.refresh",
            "audio.processes.refresh",
            nil,
            "Refresh App Audio Sources",
            "Reload apps that can be selected for system-audio transcription.",
            .troubleshooting,
            "arrow.clockwise",
            ["process", "application", "capture"],
            controller.isListening
                ? "Stop live capture before refreshing app audio sources."
                : nil,
            nil,
            .action
        ) { [controller] in
            controller.refreshProcesses()
        }
        add(
            "assistant.display.restart",
            "assistant.display.restart",
            nil,
            "Restart Assistant Display Server",
            "Restart the local companion gateway and select an available port.",
            .troubleshooting,
            "arrow.clockwise.circle",
            ["companion", "gateway", "network", "port"],
            nil,
            nil,
            .action
        ) { [controller] in
            controller.restartCompanionGateway()
        }
        add(
            "error.dismiss",
            "error.dismiss",
            nil,
            "Dismiss Current Error",
            "Clear the error banner currently shown in the main window.",
            .troubleshooting,
            "xmark.circle",
            ["close", "banner", "warning"],
            controller.errorMessage == nil ? "No error banner is visible." : nil,
            nil,
            .action
        ) { [controller] in
            controller.errorMessage = nil
        }
    }

    private func addBooleanCommands(
        idPrefix: String,
        title: String,
        description: String,
        category: SlashCommandCategory,
        systemImage: String,
        isEnabled: Bool,
        sharedUnavailableReason: String? = nil,
        confirmationWhenEnabling: SlashCommandConfirmation? = nil,
        setter: @escaping @MainActor (Bool) -> Void,
        using add: AddCommand
    ) {
        for enabled in [true, false] {
            let verb = enabled ? "Enable" : "Disable"
            add(
                "\(idPrefix).\(enabled ? "enable" : "disable")",
                "\(idPrefix).\(enabled ? "enable" : "disable")",
                nil,
                "\(verb) \(title)",
                "\(verb) \(description).",
                category,
                systemImage,
                [enabled ? "on" : "off", "toggle"],
                isEnabled == enabled
                    ? "\(title) is already \(enabled ? "enabled" : "disabled")."
                    : sharedUnavailableReason,
                enabled ? confirmationWhenEnabling : nil,
                .action
            ) {
                setter(enabled)
            }
        }
    }

    private func captureStartUnavailableReason(
        for purpose: CapturePurpose
    ) -> String? {
        if controller.syntheticInterviewState.isActive {
            return "Stop the generated \(controller.syntheticInterviewState.purpose.title.lowercased()) replay first."
        }
        if controller.isListening {
            if controller.capturePurpose == purpose {
                return "\(purpose.title) capture is already running."
            }
            return "Stop the active \(controller.capturePurpose?.title.lowercased() ?? "live") capture first."
        }
        if controller.isDictating {
            return "Release the Quick Dictation shortcut first."
        }
        return nil
    }

    private func contextUnavailableReason(for purpose: CapturePurpose) -> String? {
        guard controller.isListening,
              controller.capturePurpose != purpose
        else {
            return nil
        }
        return "Stop the active \(controller.capturePurpose?.title.lowercased() ?? "live") capture before applying \(purpose.title.lowercased()) context."
    }

    private func assistantConfigurationUnavailableReason() -> String? {
        if controller.isListening {
            return "Stop live capture before changing assistant behavior."
        }
        if controller.syntheticInterviewState.isActive {
            return "Stop the generated replay before changing assistant behavior."
        }
        if !controller.isLiveAssistantAvailable {
            return controller.liveAssistantLockMessage(for: .interview)
        }
        return nil
    }

    private func suggestContextUnavailableReason() -> String? {
        if controller.referencePreparationState.resumeSource == nil {
            return "Choose the current interview resume first."
        }
        if let message = controller.capability.lockMessage(for: .answerMirror) {
            return message
        }
        if controller.isListening {
            return "Stop live capture before drafting interview context."
        }
        if controller.syntheticInterviewState.isActive {
            return "Stop the generated replay before drafting interview context."
        }
        if controller.referencePreparationState.phase.isWorking {
            return "Wait for evidence preparation to finish."
        }
        if controller.interviewContextSuggestionPhase.isWorking {
            return "An interview description is already being drafted."
        }
        return nil
    }

    private func engineUnavailableReason(
        _ engine: TranscriptRefinementEngine
    ) -> String? {
        if controller.resolvedDictationEngine == engine {
            return "\(engine.title) is already selected."
        }
        if engine.isCloud,
           let message = controller.capability.lockMessage(
               for: .bestAccuracyDictation
           )
        {
            return message
        }
        if controller.isListening {
            return "Stop live capture before changing the transcription model."
        }
        if controller.isDictationBusy {
            return "Finish Quick Dictation before changing the transcription model."
        }
        return nil
    }

    private func providerUnavailableReason(
        _ provider: LiveAssistantProvider
    ) -> String? {
        if controller.liveAssistantProvider == provider {
            return "\(provider.title) is already selected."
        }
        if controller.isListening {
            return "Stop live capture before changing the suggestion provider."
        }
        if controller.syntheticInterviewState.isActive {
            return "Stop the generated replay before changing the suggestion provider."
        }
        return nil
    }

    private func historyArgument(date: Date, text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let preview = collapsed.count > 56
            ? "\(collapsed.prefix(55))…"
            : collapsed
        return "\(date.formatted(date: .abbreviated, time: .shortened)) — \(preview)"
    }

    private func recoveryArgument(
        _ recovery: QuickDictationRecoveryEntry
    ) -> String {
        recovery.createdAt.formatted(
            date: .abbreviated,
            time: .standard
        )
    }
}

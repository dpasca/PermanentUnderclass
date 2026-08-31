import AppKit
import Combine
import SwiftUI

struct SlashCommandScrollRequest: Equatable {
    let id = UUID()
    let commandID: String
}

enum SlashCommandPaletteKeyAction: Equatable {
    case autocomplete
    case moveDown
    case moveUp
    case execute
    case escape
}

enum SlashCommandPaletteKeyRouter {
    static func action(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> SlashCommandPaletteKeyAction? {
        let disallowedModifiers = modifierFlags.intersection([
            .command,
            .control,
            .option
        ])
        guard disallowedModifiers.isEmpty else { return nil }

        switch keyCode {
        case 48:
            return .autocomplete
        case 125:
            return .moveDown
        case 126:
            return .moveUp
        case 36, 76:
            return .execute
        case 53:
            return .escape
        default:
            return nil
        }
    }
}

@MainActor
final class SlashCommandPaletteModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            isShowingHelp = false
            updateFilteredCommands()
        }
    }
    @Published private(set) var commands: [SlashCommand] = []
    @Published private(set) var filteredCommands: [SlashCommand] = []
    @Published private(set) var selectedCommandID: String?
    @Published private(set) var isShowingHelp = false
    @Published private(set) var parameterCommand: SlashCommand?
    @Published private(set) var scrollRequest: SlashCommandScrollRequest?

    private let commandsProvider: () -> [SlashCommand]
    private let executeHandler: (SlashCommand) -> Void
    private let dismissHandler: () -> Void
    private var parameterCommands: [SlashCommand] = []
    private var commandQueryBeforeParameters = ""

    init(
        commandsProvider: @escaping () -> [SlashCommand],
        executeHandler: @escaping (SlashCommand) -> Void,
        dismissHandler: @escaping () -> Void
    ) {
        self.commandsProvider = commandsProvider
        self.executeHandler = executeHandler
        self.dismissHandler = dismissHandler
        commands = commandsProvider()
        filteredCommands = commands
        selectedCommandID = filteredCommands.first?.id
    }

    var selectedCommand: SlashCommand? {
        guard !filteredCommands.isEmpty else { return nil }
        return filteredCommands.first(where: { $0.id == selectedCommandID })
            ?? filteredCommands.first
    }

    var isChoosingParameter: Bool {
        parameterCommand != nil
    }

    var searchPlaceholder: String {
        parameterCommand?.parameterPicker?.prompt
            ?? "Type a command or describe an action"
    }

    var emptyResultTitle: String {
        if query.isEmpty, let picker = parameterCommand?.parameterPicker {
            return picker.emptyTitle
        }
        return isChoosingParameter
            ? "No matching argument"
            : "No matching command"
    }

    var emptyResultDescription: String {
        if query.isEmpty, let picker = parameterCommand?.parameterPicker {
            return picker.emptyDescription
        }
        return isChoosingParameter
            ? "Try another word from the item you want to select."
            : "Try a command name such as “capture”, or an action such as “copy transcript”."
    }

    func reset() {
        isShowingHelp = false
        parameterCommand = nil
        parameterCommands = []
        commandQueryBeforeParameters = ""
        query = ""
        refresh()
    }

    func refresh() {
        let previousSelection = selectedCommandID
        commands = commandsProvider()

        if let parameterCommand,
           let refreshedCommand = commands.first(where: {
               $0.id == parameterCommand.id
           }),
           let picker = refreshedCommand.parameterPicker
        {
            self.parameterCommand = refreshedCommand
            parameterCommands = picker.commands()
        } else if parameterCommand != nil {
            self.parameterCommand = nil
            parameterCommands = []
        }

        updateFilteredCommands(preferredSelection: previousSelection)
    }

    func select(_ command: SlashCommand) {
        selectedCommandID = command.id
    }

    func moveSelection(by offset: Int) {
        let matches = filteredCommands
        guard !matches.isEmpty else {
            selectedCommandID = nil
            return
        }
        guard let selectedCommandID,
              let index = matches.firstIndex(where: {
                  $0.id == selectedCommandID
              })
        else {
            self.selectedCommandID = matches.first?.id
            return
        }
        let nextIndex = min(max(index + offset, 0), matches.count - 1)
        self.selectedCommandID = matches[nextIndex].id
        scrollRequest = SlashCommandScrollRequest(
            commandID: matches[nextIndex].id
        )
    }

    func autocompleteSelected() {
        guard let selectedCommand else { return }
        if isChoosingParameter {
            query = selectedCommand.argument ?? selectedCommand.title
        } else {
            query = String(selectedCommand.invocation.dropFirst())
        }
        selectedCommandID = selectedCommand.id
    }

    func executeSelected() {
        guard let selectedCommand else { return }
        execute(selectedCommand)
    }

    func execute(_ command: SlashCommand) {
        selectedCommandID = command.id
        guard command.availability.isAvailable else { return }
        if command.isHelp {
            isShowingHelp = true
            return
        }
        if command.parameterPicker != nil {
            enterParameters(for: command)
            return
        }
        executeHandler(command)
    }

    func toggleHelp() {
        isShowingHelp.toggle()
    }

    func escape() {
        if isShowingHelp {
            isShowingHelp = false
        } else if isChoosingParameter {
            leaveParameters()
        } else {
            dismissHandler()
        }
    }

    func leaveParameters() {
        guard let parameterCommand else { return }
        let parentID = parameterCommand.id
        self.parameterCommand = nil
        parameterCommands = []
        query = commandQueryBeforeParameters
        updateFilteredCommands(preferredSelection: parentID)
    }

    private func enterParameters(for command: SlashCommand) {
        guard let picker = command.parameterPicker else { return }
        commandQueryBeforeParameters = query
        parameterCommand = command
        parameterCommands = picker.commands()
        query = ""
        updateFilteredCommands()
    }

    private func updateFilteredCommands(
        preferredSelection: String? = nil
    ) {
        let source = isChoosingParameter ? parameterCommands : commands
        let matches = SlashCommandMatcher.matches(source, query: query)
        filteredCommands = matches
        if let preferredSelection,
           matches.contains(where: { $0.id == preferredSelection })
        {
            selectedCommandID = preferredSelection
        } else {
            selectedCommandID = matches.first?.id
        }
    }
}

@MainActor
final class SlashCommandCenter: NSObject, NSWindowDelegate {
    private let registry: SlashCommandRegistry
    private var model: SlashCommandPaletteModel!
    private var panel: SlashCommandPanel?
    private var eventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(
        controller: MeetingController,
        navigation: ApplicationNavigation
    ) {
        registry = SlashCommandRegistry(
            controller: controller,
            navigation: navigation
        )
        super.init()

        model = SlashCommandPaletteModel(
            commandsProvider: { [weak registry] in
                registry?.commands() ?? []
            },
            executeHandler: { [weak self] command in
                self?.execute(command)
            },
            dismissHandler: { [weak self] in
                self?.dismiss()
            }
        )

        controller.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard self?.panel?.isVisible == true else { return }
                    self?.model.refresh()
                }
            }
            .store(in: &cancellables)
        navigation.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard self?.panel?.isVisible == true else { return }
                    self?.model.refresh()
                }
            }
            .store(in: &cancellables)

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyEvent(event)
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func present() {
        model.reset()
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func makePanel() -> SlashCommandPanel {
        let size = NSSize(width: 720, height: 570)
        let panel = SlashCommandPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Slash Commands"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: SlashCommandPaletteView(model: model)
        )
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = NSApplication.shared.keyWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let anchorFrame = NSApplication.shared.keyWindow?.frame ?? visibleFrame
        let panelFrame = panel.frame
        let proposedX = anchorFrame.midX - panelFrame.width / 2
        let proposedY = anchorFrame.midY - panelFrame.height / 2 + 60
        let x = min(
            max(proposedX, visibleFrame.minX + 16),
            visibleFrame.maxX - panelFrame.width - 16
        )
        let y = min(
            max(proposedY, visibleFrame.minY + 16),
            visibleFrame.maxY - panelFrame.height - 16
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func handleLocalKeyEvent(_ event: NSEvent) -> NSEvent? {
        if panel?.isVisible == true {
            return handlePaletteKeyEvent(event)
        }
        guard !event.isARepeat, event.characters == "/" else { return event }

        let disallowedModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .function
        ])
        guard disallowedModifiers.isEmpty else { return event }
        guard !isEditingText else { return event }

        present()
        return nil
    }

    private func handlePaletteKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let action = SlashCommandPaletteKeyRouter.action(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            return event
        }

        switch action {
        case .autocomplete:
            model.autocompleteSelected()
        case .moveDown:
            model.moveSelection(by: 1)
        case .moveUp:
            model.moveSelection(by: -1)
        case .execute:
            model.executeSelected()
        case .escape:
            model.escape()
        }
        return nil
    }

    private var isEditingText: Bool {
        guard let responder = NSApplication.shared.keyWindow?.firstResponder
        else {
            return false
        }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        if let textField = responder as? NSTextField {
            return textField.isEditable
        }
        return false
    }

    private func execute(_ command: SlashCommand) {
        dismiss()
        guard let confirmation = command.confirmation else {
            DispatchQueue.main.async {
                command.perform()
            }
            return
        }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = confirmation.title
            alert.informativeText = confirmation.message
            alert.addButton(withTitle: confirmation.confirmButton)
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            command.perform()
        }
    }
}

private final class SlashCommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct SlashCommandPaletteView: View {
    @ObservedObject var model: SlashCommandPaletteModel
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            content
            Divider()
            commandDetail
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
        .onChange(of: model.isChoosingParameter) { _, _ in
            refocusSearch()
        }
        .onChange(of: model.isShowingHelp) { _, isShowingHelp in
            if !isShowingHelp {
                refocusSearch()
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            if let parameterCommand = model.parameterCommand {
                Button {
                    model.leaveParameters()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to commands")

                Text("/\(parameterCommand.name)")
                    .font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                TextField(
                    model.searchPlaceholder,
                    text: $model.query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .focused($searchIsFocused)
                .accessibilityLabel("Command argument search")
            } else {
                ZStack(alignment: .leading) {
                    Text("/")
                        .font(
                            .system(
                                size: 23,
                                weight: .semibold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    TextField(
                        model.searchPlaceholder,
                        text: $model.query
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .medium))
                        .padding(.leading, 30)
                        .focused($searchIsFocused)
                        .accessibilityLabel("Slash command search")
                }
                .layoutPriority(1)
            }
            Button {
                model.toggleHelp()
            } label: {
                Image(systemName: model.isShowingHelp
                    ? "xmark.circle.fill"
                    : "questionmark.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.isShowingHelp ? "Return to commands" : "Slash command help")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    @ViewBuilder
    private var content: some View {
        if model.isShowingHelp {
            helpContent
        } else if model.filteredCommands.isEmpty {
            ContentUnavailableView(
                model.emptyResultTitle,
                systemImage: "command",
                description: Text(model.emptyResultDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            commandList
        }
    }

    private var commandList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.filteredCommands) { command in
                        commandRow(command)
                            .id(command.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.commandID, anchor: .center)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func commandRow(_ command: SlashCommand) -> some View {
        let isSelected = command.id == model.selectedCommandID
        let isAvailable = command.availability.isAvailable

        return Button {
            if isSelected {
                model.execute(command)
            } else {
                model.select(command)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isAvailable ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        (isAvailable ? Color.accentColor : Color.secondary)
                            .opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(
                            model.isChoosingParameter
                                ? command.argument ?? command.title
                                : command.invocation
                        )
                            .font(.callout.monospaced().weight(.semibold))
                            .lineLimit(1)
                        if !isAvailable {
                            Image(systemName: "slash.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Unavailable")
                        }
                    }
                    Text(
                        model.isChoosingParameter
                            ? command.description
                            : command.title
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if model.isChoosingParameter {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(command.category.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : 0.72)
        .onHover { hovering in
            if hovering {
                model.select(command)
            }
        }
        .accessibilityHint(
            command.availability.unavailableReason ?? command.description
        )
    }

    private var commandDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let command = model.selectedCommand, !model.isShowingHelp {
                Text(command.description)
                    .font(.callout)
                    .lineLimit(2)
                if let reason = command.availability.unavailableReason {
                    Label(reason, systemImage: "info.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            } else {
                Text("Every command uses the same application actions as the GUI.")
                    .font(.callout)
            }

            HStack(spacing: 12) {
                keyboardHint("↑↓", "select")
                keyboardHint("⇥", "autocomplete")
                keyboardHint("↩", "run")
                keyboardHint(
                    "esc",
                    model.isChoosingParameter ? "back" : "close"
                )
                Spacer()
                Text(
                    model.isChoosingParameter
                        ? "Arguments load only after choosing a command"
                        : "Unavailable commands stay visible and explain why"
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 90)
    }

    private var helpContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Slash commands are the app's action layer", systemImage: "command")
                    .font(.title2.weight(.semibold))

                Text(
                    "Press / whenever PermanentUnderclass has focus and you are not editing text. Type a canonical command, a GUI label, or a few descriptive words; matching commands update immediately."
                )
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

                helpStep(
                    "Find",
                    detail: "Try /capture, “meeting replay”, “API key”, or “copy transcript”."
                )
                helpStep(
                    "Complete",
                    detail: "Use the arrow keys to select a result and Tab to fill its full invocation."
                )
                helpStep(
                    "Choose arguments",
                    detail: "Commands that act on histories, devices, or other collections open a focused second list instead of filling the main palette with every possible item."
                )
                helpStep(
                    "Understand",
                    detail: "Every command includes a short description. Commands that cannot run remain listed with the exact state change needed."
                )
                helpStep(
                    "Run",
                    detail: "Press Return. Commands that remove data or enable a risky mode ask for confirmation."
                )

                Divider()

                Text(
                    "Text fields keep ordinary slash typing. Use the visible Commands button or ⇧⌘P when the insertion point is inside a text editor."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helpStep(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyboardHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.monospaced().weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(action)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func refocusSearch() {
        searchIsFocused = false
        DispatchQueue.main.async {
            searchIsFocused = true
        }
    }
}

import AppKit
import XCTest
@testable import PUnderclass

@MainActor
final class SlashCommandTests: XCTestCase {
    func testArrowKeyRouterAcceptsAppKitFunctionFlag() {
        XCTAssertEqual(
            SlashCommandPaletteKeyRouter.action(
                keyCode: 125,
                modifierFlags: [.function, .numericPad]
            ),
            .moveDown
        )
        XCTAssertEqual(
            SlashCommandPaletteKeyRouter.action(
                keyCode: 126,
                modifierFlags: [.function]
            ),
            .moveUp
        )
        XCTAssertNil(
            SlashCommandPaletteKeyRouter.action(
                keyCode: 125,
                modifierFlags: [.function, .option]
            )
        )
    }

    func testMatcherAcceptsSlashPrefixAndRanksCanonicalPrefixFirst() {
        let commands = [
            makeCommand(
                id: "copy",
                name: "transcript.meeting.copy",
                title: "Copy Meeting Transcript"
            ),
            makeCommand(
                id: "clear",
                name: "transcript.meeting.clear",
                title: "Clear Meeting Transcript"
            ),
            makeCommand(
                id: "capture",
                name: "capture.meeting.start",
                title: "Start Meeting Capture"
            )
        ]

        let matches = SlashCommandMatcher.matches(
            commands,
            query: "/transcript.meeting.cop"
        )

        XCTAssertEqual(matches.first?.id, "copy")
    }

    func testMatcherFindsNaturalMultiwordQueriesAndFuzzyNames() {
        let commands = [
            makeCommand(
                id: "copy",
                name: "transcript.meeting.copy",
                title: "Copy Meeting Transcript",
                description: "Copy the complete meeting transcript."
            ),
            makeCommand(
                id: "settings",
                name: "settings.api-keys",
                title: "Open API Keys Settings"
            )
        ]

        XCTAssertEqual(
            SlashCommandMatcher.matches(
                commands,
                query: "copy meeting"
            ).first?.id,
            "copy"
        )
        XCTAssertEqual(
            SlashCommandMatcher.matches(
                commands,
                query: "stngapikey"
            ).first?.id,
            "settings"
        )
    }

    func testUnavailableCommandsRemainDiscoverable() {
        let command = makeCommand(
            id: "stop",
            name: "capture.stop",
            title: "Stop Live Capture",
            availability: .unavailable("No live capture is running.")
        )

        let matches = SlashCommandMatcher.matches(
            [command],
            query: "stop capture"
        )

        XCTAssertEqual(matches.map(\.id), ["stop"])
        XCTAssertEqual(
            matches.first?.availability.unavailableReason,
            "No live capture is running."
        )
    }

    func testPaletteAutocompletesAndDoesNotExecuteUnavailableCommand() {
        var executedIDs: [String] = []
        let available = makeCommand(
            id: "copy",
            name: "transcript.meeting.copy",
            title: "Copy Meeting Transcript"
        )
        let unavailable = makeCommand(
            id: "stop",
            name: "capture.stop",
            title: "Stop Live Capture",
            availability: .unavailable("No live capture is running.")
        )
        let model = SlashCommandPaletteModel(
            commandsProvider: { [available, unavailable] },
            executeHandler: { executedIDs.append($0.id) },
            dismissHandler: {}
        )

        model.query = "copy meet"
        model.autocompleteSelected()
        XCTAssertEqual(model.query, "transcript.meeting.copy")
        model.executeSelected()
        XCTAssertEqual(executedIDs, ["copy"])

        model.query = "capture stop"
        model.executeSelected()
        XCTAssertEqual(executedIDs, ["copy"])
    }

    func testHelpCommandKeepsPaletteInHelpMode() {
        let help = makeCommand(
            id: "help",
            name: "help",
            title: "Slash Command Help",
            kind: .help
        )
        let model = SlashCommandPaletteModel(
            commandsProvider: { [help] },
            executeHandler: { _ in
                XCTFail("Help must not be dispatched as an app action")
            },
            dismissHandler: {}
        )

        model.executeSelected()

        XCTAssertTrue(model.isShowingHelp)
    }

    func testParameterizedCommandLoadsLargeArgumentListOnlyOnEntry() {
        var loadCount = 0
        var executedIDs: [String] = []
        let parent = SlashCommand(
            id: "history.copy",
            name: "dictation.history.copy",
            title: "Copy Saved Dictation",
            description: "Choose a saved dictation to copy.",
            category: .dictation,
            systemImage: "doc.on.doc",
            kind: .parameterized(
                SlashCommandParameterPicker(
                    prompt: "Search saved dictations",
                    emptyTitle: "No saved dictations",
                    emptyDescription: "Dictation history is empty."
                ) {
                    loadCount += 1
                    return (0..<500).map { index in
                        SlashCommand(
                            id: "history.copy.\(index)",
                            name: "dictation.history.copy",
                            argument: "Entry \(index)",
                            title: "Copy Saved Dictation",
                            description: "Saved dictation \(index)",
                            category: .dictation,
                            systemImage: "doc.on.doc",
                            perform: {}
                        )
                    }
                }
            ),
            perform: {}
        )
        let model = SlashCommandPaletteModel(
            commandsProvider: { [parent] },
            executeHandler: { executedIDs.append($0.id) },
            dismissHandler: {}
        )

        model.query = "copy saved"
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(model.filteredCommands.count, 1)

        model.executeSelected()
        XCTAssertTrue(model.isChoosingParameter)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(model.filteredCommands.count, 500)

        model.query = "Entry 499"
        XCTAssertEqual(model.filteredCommands.first?.id, "history.copy.499")
        model.executeSelected()
        XCTAssertEqual(executedIDs, ["history.copy.499"])

        model.leaveParameters()
        XCTAssertFalse(model.isChoosingParameter)
        XCTAssertEqual(model.query, "copy saved")
        XCTAssertEqual(model.selectedCommandID, parent.id)
    }

    func testTypingDoesNotIssueSelectionScrollRequests() {
        let commands = [
            makeCommand(id: "one", name: "one", title: "One"),
            makeCommand(id: "two", name: "two", title: "Two"),
            makeCommand(id: "three", name: "three", title: "Three")
        ]
        let model = SlashCommandPaletteModel(
            commandsProvider: { commands },
            executeHandler: { _ in },
            dismissHandler: {}
        )

        model.query = "three"
        model.query = ""
        XCTAssertNil(model.scrollRequest)

        model.moveSelection(by: 1)
        XCTAssertEqual(model.scrollRequest?.commandID, "two")
    }

    func testApplicationRegistryHasUniqueDocumentedCoreCommands() {
        let controller = MeetingController.documentationDemo(.meeting)
        let navigation = ApplicationNavigation(documentationDemoMode: .meeting)
        let commands = SlashCommandRegistry(
            controller: controller,
            navigation: navigation
        ).commands()
        let ids = commands.map(\.id)
        let names = Set(commands.map(\.name))

        XCTAssertGreaterThan(commands.count, 60)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(commands.allSatisfy { !$0.description.isEmpty })
        XCTAssertTrue(commands.allSatisfy { $0.invocation.first == "/" })

        let expectedNames: Set<String> = [
            "help",
            "view.quick-dictation",
            "view.meeting",
            "view.interview",
            "capture.meeting.start",
            "capture.interview.start",
            "capture.stop",
            "transcript.meeting.copy",
            "transcript.interview.export",
            "replay.meeting.run",
            "replay.interview.regenerate",
            "dictation.enable",
            "dictation.history.copy",
            "dictation.history.delete",
            "dictation.recovery.retry",
            "prepare.interview",
            "references.folder.choose",
            "references.resume.choose",
            "references.evidence.prepare",
            "references.evidence.enable",
            "references.evidence.disable",
            "references.web.remove",
            "audio.input.select",
            "audio.output.select",
            "audio.process.select",
            "settings.api-keys",
            "privacy.local-only.enable",
            "assistant.display.restart"
        ]
        XCTAssertTrue(
            expectedNames.isSubset(of: names),
            "Missing commands: \(expectedNames.subtracting(names))"
        )

        let parameterizedNames = [
            "dictation.history.copy",
            "dictation.history.delete",
            "dictation.recovery.retry",
            "dictation.recovery.reveal",
            "dictation.recovery.delete",
            "references.web.remove",
            "references.evidence.enable",
            "references.evidence.disable",
            "audio.input.select",
            "audio.output.select",
            "audio.process.select"
        ]
        for name in parameterizedNames {
            let matchingCommands = commands.filter { $0.name == name }
            XCTAssertEqual(
                matchingCommands.count,
                1,
                "\(name) must occupy one root palette row"
            )
            XCTAssertNotNil(
                matchingCommands.first?.parameterPicker,
                "\(name) must load its arguments lazily"
            )
        }

        let historyCopyCommand = commands.first {
            $0.name == "dictation.history.copy"
        }
        XCTAssertEqual(
            historyCopyCommand?.parameterPicker?.commands().count,
            controller.quickDictationHistory.count
        )

        let stop = commands.first(where: { $0.name == "capture.stop" })
        XCTAssertEqual(
            stop?.availability.unavailableReason,
            "No live capture is running."
        )
    }

    private func makeCommand(
        id: String,
        name: String,
        title: String,
        description: String = "A documented command.",
        availability: SlashCommandAvailability = .available,
        kind: SlashCommandKind = .action
    ) -> SlashCommand {
        SlashCommand(
            id: id,
            name: name,
            title: title,
            description: description,
            category: .navigation,
            systemImage: "command",
            availability: availability,
            kind: kind,
            perform: {}
        )
    }
}

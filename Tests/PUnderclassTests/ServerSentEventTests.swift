import Foundation
import XCTest
@testable import PUnderclass

final class ServerSentEventTests: XCTestCase {
    func testTransportMilestonesOffsetRetryEventsFromOriginalStart() {
        let response = LiveAssistantTransportResponse(
            data: Data(),
            responseHeadersMilliseconds: 40,
            firstEventMilliseconds: 55,
            firstTextDeltaMilliseconds: 90
        )

        XCTAssertEqual(
            response.latencyMilestones(
                validatedCueMilliseconds: 730,
                requestStartOffsetMilliseconds: 500
            ),
            LiveAssistantLatencyMilestones(
                responseHeadersMilliseconds: 540,
                firstEventMilliseconds: 555,
                firstTextDeltaMilliseconds: 590,
                firstRenderableTextMilliseconds: nil,
                validatedCueMilliseconds: 730
            )
        )
    }

    func testParserHandlesNamedMultilineEventsCommentsAndPersistentIDs() {
        var parser = ServerSentEventParser()

        XCTAssertNil(parser.consume(line: ": keepalive"))
        XCTAssertNil(parser.consume(line: "id: event-17"))
        XCTAssertNil(parser.consume(line: "event: step.delta"))
        XCTAssertNil(parser.consume(line: "data: {\"part\":1,"))
        XCTAssertNil(parser.consume(line: "data: \"done\":false}"))
        XCTAssertEqual(
            parser.consume(line: ""),
            ServerSentEvent(
                name: "step.delta",
                data: "{\"part\":1,\n\"done\":false}",
                id: "event-17"
            )
        )

        XCTAssertNil(parser.consume(line: "data: [DONE]"))
        XCTAssertEqual(
            parser.finish(),
            ServerSentEvent(name: nil, data: "[DONE]", id: "event-17")
        )
    }

    func testOpenAIAssemblerMeasuresTextAndReturnsCompletedResponse() throws {
        var assembler = OpenAIResponsesStreamAssembler()

        XCTAssertNil(
            try assembler.consume(
                event(
                    name: "response.created",
                    object: ["type": "response.created"]
                )
            )
        )
        XCTAssertEqual(
            try assembler.consume(
                event(
                    name: "response.output_text.delta",
                    object: [
                        "type": "response.output_text.delta",
                        "delta": "{\"shouldShow\":"
                    ]
                )
            ),
            "{\"shouldShow\":"
        )
        XCTAssertNil(
            try assembler.consume(
                event(
                    name: "response.completed",
                    object: [
                        "type": "response.completed",
                        "response": [
                            "status": "completed",
                            "output": [],
                            "usage": [:]
                        ]
                    ]
                )
            )
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: assembler.completedResponseData()
            ) as? [String: Any]
        )
        XCTAssertEqual(root["status"] as? String, "completed")
    }

    func testInstantTextAccumulatorWaitsForShowControlLine() async throws {
        let accumulator = LiveAssistantInstantTextAccumulator()

        let firstFragment = await accumulator.consume(
            delta: "SH",
            elapsedMilliseconds: 410
        )
        XCTAssertNil(firstFragment)
        let controlLine = await accumulator.consume(
            delta: "OW\n",
            elapsedMilliseconds: 430
        )
        XCTAssertNil(controlLine)
        let firstUpdate = await accumulator.consume(
            delta: "I would start with the trace",
            elapsedMilliseconds: 455
        )
        XCTAssertEqual(
            firstUpdate,
            LiveAssistantInstantTextUpdate(
                text: "I would start with the trace",
                elapsedMilliseconds: 455,
                firstRenderableTextMilliseconds: 455
            )
        )
        let secondUpdate = await accumulator.consume(
            delta: " and isolate one variable.",
            elapsedMilliseconds: 490
        )
        XCTAssertEqual(
            secondUpdate,
            LiveAssistantInstantTextUpdate(
                text: "I would start with the trace and isolate one variable.",
                elapsedMilliseconds: 490,
                firstRenderableTextMilliseconds: 455
            )
        )
        let decision = try await accumulator.completedDecision(
            finalOutput: "SHOW\nI would start with the trace and isolate one variable."
        )
        XCTAssertEqual(
            decision,
            .show(
                "I would start with the trace and isolate one variable."
            )
        )
        let firstRenderable = await accumulator.firstRenderableTextMilliseconds
        XCTAssertEqual(firstRenderable, 455)
    }

    func testInstantTextAccumulatorAcceptsOnlyExactSkip() async throws {
        let accumulator = LiveAssistantInstantTextAccumulator()

        let decision = try await accumulator.completedDecision(
            finalOutput: " SKIP\n"
        )
        XCTAssertEqual(decision, .skip)
    }

    func testInstantTextAccumulatorRejectsUnframedText() async {
        let accumulator = LiveAssistantInstantTextAccumulator()

        do {
            _ = try await accumulator.completedDecision(
                finalOutput: "I would answer immediately."
            )
            XCTFail("Expected unframed output to be rejected")
        } catch {
            XCTAssertEqual(error as? LiveAssistantError, .invalidResponse)
        }
    }

    func testParserDispatchesBackToBackNamedEventsWithoutBlankLines() {
        var parser = ServerSentEventParser()

        XCTAssertNil(parser.consume(line: "event: interaction.created"))
        XCTAssertNil(
            parser.consume(
                line: "data: {\"event_type\":\"interaction.created\"}"
            )
        )
        XCTAssertEqual(
            parser.consume(line: "event: step.start"),
            ServerSentEvent(
                name: "interaction.created",
                data: "{\"event_type\":\"interaction.created\"}",
                id: nil
            )
        )
        XCTAssertNil(
            parser.consume(
                line: "data: {\"event_type\":\"step.start\",\"index\":0}"
            )
        )
        XCTAssertEqual(
            parser.finish(),
            ServerSentEvent(
                name: "step.start",
                data: "{\"event_type\":\"step.start\",\"index\":0}",
                id: nil
            )
        )
    }

    func testGeminiAssemblerIgnoresThoughtsAndReassemblesModelOutput() throws {
        var assembler = GeminiInteractionStreamAssembler()

        XCTAssertFalse(
            try assembler.consume(
                event(
                    name: "step.start",
                    object: [
                        "event_type": "step.start",
                        "index": 0,
                        "step": ["type": "thought"]
                    ]
                )
            )
        )
        XCTAssertFalse(
            try assembler.consume(
                event(
                    name: "step.delta",
                    object: [
                        "event_type": "step.delta",
                        "index": 0,
                        "delta": [
                            "type": "thought_summary",
                            "content": ["type": "text", "text": "Planning"]
                        ]
                    ]
                )
            )
        )
        XCTAssertFalse(
            try assembler.consume(
                event(
                    name: "step.start",
                    object: [
                        "event_type": "step.start",
                        "index": 1,
                        "step": ["type": "model_output"]
                    ]
                )
            )
        )
        XCTAssertTrue(
            try assembler.consume(
                event(
                    name: "step.delta",
                    object: [
                        "event_type": "step.delta",
                        "index": 1,
                        "delta": ["type": "text", "text": "{\"answer\":"]
                    ]
                )
            )
        )
        XCTAssertTrue(
            try assembler.consume(
                event(
                    name: "step.delta",
                    object: [
                        "event_type": "step.delta",
                        "index": 1,
                        "delta": ["type": "text", "text": "true}"]
                    ]
                )
            )
        )
        XCTAssertFalse(
            try assembler.consume(
                event(
                    name: "interaction.completed",
                    object: [
                        "event_type": "interaction.completed",
                        "interaction": [
                            "status": "completed",
                            "usage": [
                                "total_input_tokens": 10,
                                "total_output_tokens": 4,
                                "total_thought_tokens": 3
                            ]
                        ]
                    ]
                )
            )
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: assembler.completedInteractionData()
            ) as? [String: Any]
        )
        let steps = try XCTUnwrap(root["steps"] as? [[String: Any]])
        let modelOutput = try XCTUnwrap(
            steps.first { $0["type"] as? String == "model_output" }
        )
        let content = try XCTUnwrap(
            modelOutput["content"] as? [[String: Any]]
        )
        XCTAssertEqual(
            content.compactMap { $0["text"] as? String }.joined(),
            "{\"answer\":true}"
        )
    }

    func testGeminiAssemblerReassemblesFunctionArguments() throws {
        var assembler = GeminiInteractionStreamAssembler()
        XCTAssertFalse(
            try assembler.consume(
                event(
                    name: "step.start",
                    object: [
                        "event_type": "step.start",
                        "index": 0,
                        "step": [
                            "type": "function_call",
                            "id": "call-1",
                            "name": "lookup"
                        ]
                    ]
                )
            )
        )
        for fragment in ["{\"project\":", "\"Renderer\"}"] {
            XCTAssertFalse(
                try assembler.consume(
                    event(
                        name: "step.delta",
                        object: [
                            "event_type": "step.delta",
                            "index": 0,
                            "delta": [
                                "type": "arguments_delta",
                                "arguments": fragment
                            ]
                        ]
                    )
                )
            )
        }
        XCTAssertFalse(
            try assembler.consume(
                event(
                    name: "step.stop",
                    object: ["event_type": "step.stop", "index": 0]
                )
            )
        )
        XCTAssertFalse(
            try assembler.consume(
                event(
                    name: "interaction.completed",
                    object: [
                        "event_type": "interaction.completed",
                        "interaction": [
                            "status": "requires_action",
                            "usage": [:]
                        ]
                    ]
                )
            )
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: assembler.completedInteractionData()
            ) as? [String: Any]
        )
        let steps = try XCTUnwrap(root["steps"] as? [[String: Any]])
        let arguments = try XCTUnwrap(
            steps[0]["arguments"] as? [String: Any]
        )
        XCTAssertEqual(arguments["project"] as? String, "Renderer")
    }

    private func event(
        name: String,
        object: [String: Any]
    ) throws -> ServerSentEvent {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return ServerSentEvent(
            name: name,
            data: String(decoding: data, as: UTF8.self),
            id: nil
        )
    }
}

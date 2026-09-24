import Foundation
import XCTest

@testable import TurboAgentCore

final class ConversationProjectionTests: XCTestCase, @unchecked Sendable {
  private func call(_ name: String, id: String, path: String? = nil, command: String? = nil) -> ParsedToolCall {
    var dict: [String: JSONValue] = [:]
    if let path { dict["path"] = .string(path) }
    if let command { dict["command"] = .string(command) }
    return ParsedToolCall(id: id, name: name, arguments: .object(dict), argumentsJSON: "{}")
  }

  func testLargeCurrentTurnReadIsReplacedByReceiptOnLaterRounds() {
    let oldReadResult = """
    [file path="Sources/Example.swift" digest="sha256:1111" lines="1-200/500" bytes="5000" complete="false"]
    \(String(repeating: "func foo() {}\n", count: 200))
    [end file; request start_line=201 to continue]
    """
    let newReadResult = """
    [file path="Sources/Example.swift" digest="sha256:1111" lines="201-250/500" bytes="1000" complete="false"]
    \(String(repeating: "func bar() {}\n", count: 50))
    [end file; request start_line=251 to continue]
    """

    let c1 = call("read_file", id: "c1", path: "Sources/Example.swift")
    let c2 = call("read_file", id: "c2", path: "Sources/Example.swift")

    var state = TurnWorkingState()
    state.objective = "inspect Example.swift"

    let obs1 = ToolObservation.make(call: c1, result: oldReadResult, workingState: state)
    state.recordToolResult(call: c1, result: oldReadResult)
    let obs2 = ToolObservation.make(call: c2, result: newReadResult, workingState: state)
    state.recordToolResult(call: c2, result: newReadResult)

    let observations = ["c1": obs1, "c2": obs2]

    let messages: [AgentMessage] = [
      AgentMessage(role: .system, content: "You are Turbo Agent."),
      AgentMessage(role: .user, content: "inspect Example.swift"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c1", name: "read_file", arguments: c1.arguments)]),
      AgentMessage(role: .tool, content: oldReadResult, toolCalls: [], toolCallID: "c1", name: "read_file"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c2", name: "read_file", arguments: c2.arguments)]),
      AgentMessage(role: .tool, content: newReadResult, toolCalls: [], toolCallID: "c2", name: "read_file"),
    ]

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    XCTAssertEqual(projected.compactedCount, 1)
    let toolResults = projected.messages.filter { $0.role == .tool }
    XCTAssertEqual(toolResults.count, 2)
    // The older read result was compacted to a receipt
    XCTAssertTrue(toolResults[0].content?.contains("[receipt") == true)
    XCTAssertTrue(toolResults[0].content?.contains("lines=\"1-200/500\"") == true || toolResults[0].content?.contains("read") == true)
    // The latest read result remains full
    XCTAssertEqual(toolResults[1].content, newReadResult)
  }

  func testLatestRelevantRangeRemainsFull() {
    let readResult = "[file path=\"A.swift\" digest=\"sha256:aaaa\" lines=\"1-10/10\" complete=\"true\"]\nsome content"
    let c1 = call("read_file", id: "c1", path: "A.swift")
    let state = TurnWorkingState()
    let obs1 = ToolObservation.make(call: c1, result: readResult, workingState: state)
    let observations = ["c1": obs1]

    let messages: [AgentMessage] = [
      AgentMessage(role: .user, content: "read A.swift"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c1", name: "read_file", arguments: c1.arguments)]),
      AgentMessage(role: .tool, content: readResult, toolCalls: [], toolCallID: "c1", name: "read_file"),
    ]

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    XCTAssertEqual(projected.compactedCount, 0)
    let toolMsg = projected.messages.first { $0.role == .tool }
    XCTAssertEqual(toolMsg?.content, readResult)
  }

  func testFailedCommandRemainsUntilResolved() {
    let errorResult = "Error: command failed with exit status: 1\nUndefined symbol: _missing_symbol"
    let c1 = call("execute_bash", id: "c1", command: "swift build")
    var state = TurnWorkingState()
    state.recordToolResult(call: c1, result: errorResult)
    let obs1 = ToolObservation.make(call: c1, result: errorResult, workingState: state)
    let observations = ["c1": obs1]

    let messages: [AgentMessage] = [
      AgentMessage(role: .user, content: "run build"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c1", name: "execute_bash", arguments: c1.arguments)]),
      AgentMessage(role: .tool, content: errorResult, toolCalls: [], toolCallID: "c1", name: "execute_bash"),
    ]

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    // The most recent error result must not be compacted
    XCTAssertEqual(projected.compactedCount, 0)
    let toolMsg = projected.messages.first { $0.role == .tool }
    XCTAssertEqual(toolMsg?.content, errorResult)
  }

  func testAssistantToolCallsAndToolResultsStayStructurallyValid() {
    let c1 = call("edit_file", id: "call_edit", path: "file.c")
    let editResult = "Successfully updated file.c\nNew revision: sha256:2222\nPrevious revision: sha256:1111 (now stale)"
    var state = TurnWorkingState()
    state.recordToolResult(call: c1, result: editResult)
    let obs1 = ToolObservation.make(call: c1, result: editResult, workingState: state)
    let observations = ["call_edit": obs1]

    let messages: [AgentMessage] = [
      AgentMessage(role: .user, content: "edit"),
      AgentMessage(
        role: .assistant, content: "Editing file",
        toolCalls: [AgentHistoricalToolCall(id: "call_edit", name: "edit_file", arguments: c1.arguments)]),
      AgentMessage(role: .tool, content: editResult, toolCalls: [], toolCallID: "call_edit", name: "edit_file"),
    ]

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    let assistant = projected.messages.first { $0.role == .assistant }
    let tool = projected.messages.first { $0.role == .tool }
    XCTAssertEqual(assistant?.toolCalls.first?.id, "call_edit")
    XCTAssertEqual(tool?.toolCallID, "call_edit")
    XCTAssertEqual(tool?.name, "edit_file")
  }

  func testMultipleCallsInOneAssistantMessageCompactWithoutBreakingPairing() {
    let c1 = call("execute_bash", id: "c1", command: "echo 1")
    let c2 = call("execute_bash", id: "c2", command: "echo 2")
    let r1 = "exit status: 0\n1"
    let r2 = "exit status: 0\n2"

    let c3 = call("execute_bash", id: "c3", command: "echo 3")
    let r3 = "exit status: 0\n3"

    let state = TurnWorkingState()
    let obs1 = ToolObservation.make(call: c1, result: r1, workingState: state)
    let obs2 = ToolObservation.make(call: c2, result: r2, workingState: state)
    let obs3 = ToolObservation.make(call: c3, result: r3, workingState: state)
    let observations = ["c1": obs1, "c2": obs2, "c3": obs3]

    let messages: [AgentMessage] = [
      AgentMessage(role: .user, content: "run commands"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [
          AgentHistoricalToolCall(id: "c1", name: "execute_bash", arguments: c1.arguments),
          AgentHistoricalToolCall(id: "c2", name: "execute_bash", arguments: c2.arguments),
        ]),
      AgentMessage(role: .tool, content: r1, toolCalls: [], toolCallID: "c1", name: "execute_bash"),
      AgentMessage(role: .tool, content: r2, toolCalls: [], toolCallID: "c2", name: "execute_bash"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c3", name: "execute_bash", arguments: c3.arguments)]),
      AgentMessage(role: .tool, content: r3, toolCalls: [], toolCallID: "c3", name: "execute_bash"),
    ]

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    XCTAssertEqual(projected.compactedCount, 2)
    let toolResults = projected.messages.filter { $0.role == .tool }
    XCTAssertEqual(toolResults.count, 3)
    XCTAssertEqual(toolResults[0].toolCallID, "c1")
    XCTAssertTrue(toolResults[0].content?.contains("[receipt") == true)
    XCTAssertEqual(toolResults[1].toolCallID, "c2")
    XCTAssertTrue(toolResults[1].content?.contains("[receipt") == true)
    XCTAssertEqual(toolResults[2].toolCallID, "c3")
    XCTAssertEqual(toolResults[2].content, r3)
  }

  func testCompletedGroupsAreEvictedAtomicallyWhenBudgetExceeded() {
    // Generate enough completed groups to exceed maxRetainedGroups (6)
    var messages: [AgentMessage] = [
      AgentMessage(role: .system, content: "standing system instructions"),
      AgentMessage(role: .user, content: "long running turn"),
    ]
    var observations: [String: ToolObservation] = [:]
    var state = TurnWorkingState()
    state.objective = "long running turn"

    for i in 1...10 {
      let callID = "call_\(i)"
      let c = call("execute_bash", id: callID, command: "echo \(i)")
      let res = "exit status: 0\nresult_\(i)"
      let obs = ToolObservation(
        callID: callID, name: "execute_bash", arguments: c.arguments,
        fullResult: res, receipt: ToolReceipt(summary: "ran echo \(i)", paths: [], revisions: [], outcome: "ok"),
        importance: .low)
      observations[callID] = obs
      messages.append(
        AgentMessage(
          role: .assistant, content: "round \(i)",
          toolCalls: [AgentHistoricalToolCall(id: callID, name: "execute_bash", arguments: c.arguments)]))
      messages.append(
        AgentMessage(role: .tool, content: res, toolCalls: [], toolCallID: callID, name: "execute_bash"))
    }

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    XCTAssertGreaterThan(projected.evictedGroupCount, 0)
    // System message is pinned
    XCTAssertEqual(projected.messages.first?.role, .system)
    // Newest user message is preserved
    XCTAssertTrue(projected.messages.contains { $0.role == .user && $0.content == "long running turn" })
    // Evicted groups were removed atomically: every assistant message has its tool result
    let assistantWithCalls = projected.messages.filter { $0.role == .assistant && !$0.toolCalls.isEmpty }
    let toolMessages = projected.messages.filter { $0.role == .tool }
    XCTAssertEqual(assistantWithCalls.count, toolMessages.count)
    for assistant in assistantWithCalls {
      let callID = assistant.toolCalls.first?.id
      XCTAssertTrue(toolMessages.contains { $0.toolCallID == callID })
    }
  }

  func testCanonicalSessionMessagesRetainFullResultsAfterProjection() {
    let fullContent = "A very long detailed full tool result that must be preserved in canonical messages"
    let c = call("read_file", id: "c1", path: "Test.swift")
    let state = TurnWorkingState()
    let obs = ToolObservation.make(call: c, result: fullContent, workingState: state)

    let c2 = call("execute_bash", id: "c2", command: "ls")
    let obs2 = ToolObservation.make(call: c2, result: "exit status: 0\nok", workingState: state)

    let messages: [AgentMessage] = [
      AgentMessage(role: .user, content: "inspect"),
      AgentMessage(role: .assistant, content: nil, toolCalls: [.init(id: "c1", name: "read_file", arguments: c.arguments)]),
      AgentMessage(role: .tool, content: fullContent, toolCalls: [], toolCallID: "c1", name: "read_file"),
      AgentMessage(role: .assistant, content: nil, toolCalls: [.init(id: "c2", name: "execute_bash", arguments: c2.arguments)]),
      AgentMessage(role: .tool, content: "exit status: 0\nok", toolCalls: [], toolCallID: "c2", name: "execute_bash"),
    ]

    let beforeCopy = messages
    _ = ConversationProjection.project(
      messages: messages, observations: ["c1": obs, "c2": obs2], workingState: state, contextLimit: 8_192)

    // The canonical messages array is strictly identical
    XCTAssertEqual(messages, beforeCopy)
    XCTAssertEqual(messages[2].content, fullContent)
  }

  func testTurnWorkingStateRendersDeterministicFacts() {
    var state = TurnWorkingState()
    state.objective = "repair cancel_prompt"
    state.recordRead(path: "Sources/AgentLineEditor/AgentLineEditor.c", digest: "sha256:abcd", startLine: 10, endLine: 50)
    state.recordEdit(path: "Sources/AgentLineEditor/AgentLineEditor.c", newDigest: "sha256:ef01", description: "updated cancel_prompt")
    state.recordCommand(command: "swift build", exitStatus: 0, succeeded: true)
    state.recordFailure("test failed: expected prompt-clear marker")

    let rendered = state.render()
    XCTAssertTrue(rendered.contains("## Current task state"))
    XCTAssertTrue(rendered.contains("repair cancel_prompt"))
    XCTAssertTrue(rendered.contains("AgentLineEditor.c"))
    XCTAssertTrue(rendered.contains("10-50"))
    XCTAssertTrue(rendered.contains("updated cancel_prompt"))
    XCTAssertTrue(rendered.contains("swift build"))
    XCTAssertTrue(rendered.contains("test failed: expected prompt-clear marker"))
  }

  func testEndToEndTurnCompletesWithinBudgetWithWorkingRoom() async throws {
    // Test that multiple rounds in ConversationTurn with projection
    // keep assembled context well within 8K limits with plenty of working room.
    var messages: [AgentMessage] = [
      AgentMessage(role: .system, content: "Standing system instructions."),
      AgentMessage(role: .user, content: "Fix bug in large file."),
    ]

    var round = 0
    let result = try await ConversationTurn.run(
      messages: &messages,
      maximumRounds: 4,
      contextLimit: 8_192,
      projectMessages: true,
      generate: { projected in
        round += 1
        // Verify every projected message list fits within 8K budget
        let prepared = try AgentContextAssembler.prepare(
          messages: projected,
          systemPrompt: "Standing system instructions.",
          tools: ToolRegistry.definitions,
          contextLimit: 8_192)
        XCTAssertTrue(prepared.budget.fits)
        XCTAssertGreaterThanOrEqual(
          prepared.budget.usablePromptTokens - prepared.budget.promptTokens, 1_000)

        if round == 1 {
          return ("", [self.call("read_file", id: "r1", path: "Fixture.c")])
        } else if round == 2 {
          return ("", [self.call("edit_file", id: "e1", path: "Fixture.c")])
        } else if round == 3 {
          return ("", [self.call("execute_bash", id: "b1", command: "swift test")])
        } else {
          return ("Finished fixing the bug.", [])
        }
      },
      execute: { call in
        if call.name == "read_file" {
          return "[file path=\"Fixture.c\" digest=\"sha256:1111\" lines=\"1-100/400\" complete=\"false\"]\n\(String(repeating: "void foo();\n", count: 100))"
        } else if call.name == "edit_file" {
          return "Successfully updated Fixture.c\nNew revision: sha256:2222\nPrevious revision: sha256:1111 (now stale)"
        } else {
          return "exit status: 0\nAll 40 tests passed."
        }
      })

    XCTAssertEqual(result, "Finished fixing the bug.")
    // Canonical messages retained all 4 rounds in full
    XCTAssertEqual(messages.filter { $0.role == .tool }.count, 3)
  }

  func testMultipleHistoricalReadsAreEvictedWhenBudgetExceededWhilePreservingLatestRead() {
    var messages: [AgentMessage] = [
      AgentMessage(role: .system, content: "You are Turbo Agent."),
      AgentMessage(role: .user, content: "inspect file repeatedly"),
    ]
    var observations: [String: ToolObservation] = [:]
    var state = TurnWorkingState()
    state.objective = "inspect file repeatedly"

    // Simulate 8 rounds of read_file with distinct ranges
    for i in 1...8 {
      let callID = "read_\(i)"
      let c = call("read_file", id: callID, path: "Sources/AgentLineEditor.c")
      let content = "[file path=\"Sources/AgentLineEditor.c\" digest=\"sha256:1111\" lines=\"\(i * 10)-\(i * 10 + 20)/200\" complete=\"false\"]\n\(String(repeating: "line \(i)\n", count: 20))"
      let obs = ToolObservation.make(call: c, result: content, workingState: state)
      observations[callID] = obs
      state.recordToolResult(call: c, result: content)
      messages.append(
        AgentMessage(
          role: .assistant, content: "reading round \(i)",
          toolCalls: [AgentHistoricalToolCall(id: callID, name: "read_file", arguments: c.arguments)]))
      messages.append(
        AgentMessage(role: .tool, content: content, toolCalls: [], toolCallID: callID, name: "read_file"))
    }

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    // Older read groups were evicted because aggregate tokens / group count exceeded limits
    XCTAssertGreaterThan(projected.evictedGroupCount, 0)
    // The newest read_file (read_8) must remain intact and full
    let toolMessages = projected.messages.filter { $0.role == .tool }
    let latestTool = toolMessages.last
    XCTAssertEqual(latestTool?.toolCallID, "read_8")
    XCTAssertTrue(latestTool?.content?.contains("line 8") == true)
    // Structural integrity: each assistant call matches its tool result
    let assistantMessages = projected.messages.filter { $0.role == .assistant && !$0.toolCalls.isEmpty }
    XCTAssertEqual(assistantMessages.count, toolMessages.count)
    for assistant in assistantMessages {
      let callID = assistant.toolCalls.first?.id
      XCTAssertTrue(toolMessages.contains { $0.toolCallID == callID })
    }
  }

  func testHistoricalErrorsAreEvictedWhenBudgetExceededWhilePreservingLatestError() {
    var messages: [AgentMessage] = [
      AgentMessage(role: .system, content: "You are Turbo Agent."),
      AgentMessage(role: .user, content: "run failing commands"),
    ]
    var observations: [String: ToolObservation] = [:]
    var state = TurnWorkingState()
    state.objective = "run failing commands"

    for i in 1...8 {
      let callID = "cmd_\(i)"
      let c = call("execute_bash", id: callID, command: "failing_cmd_\(i)")
      let errorResult = "Error: command failed at step \(i)\nDetails about failure \(i)"
      let obs = ToolObservation.make(call: c, result: errorResult, workingState: state)
      observations[callID] = obs
      state.recordToolResult(call: c, result: errorResult)
      messages.append(
        AgentMessage(
          role: .assistant, content: "running cmd \(i)",
          toolCalls: [AgentHistoricalToolCall(id: callID, name: "execute_bash", arguments: c.arguments)]))
      messages.append(
        AgentMessage(role: .tool, content: errorResult, toolCalls: [], toolCallID: callID, name: "execute_bash"))
    }

    let projected = ConversationProjection.project(
      messages: messages, observations: observations, workingState: state, contextLimit: 8_192)

    XCTAssertGreaterThan(projected.evictedGroupCount, 0)
    // The latest error (cmd_8) remains intact and full
    let toolMessages = projected.messages.filter { $0.role == .tool }
    let latestTool = toolMessages.last
    XCTAssertEqual(latestTool?.toolCallID, "cmd_8")
    XCTAssertTrue(latestTool?.content?.contains("Error: command failed at step 8") == true)
  }
}


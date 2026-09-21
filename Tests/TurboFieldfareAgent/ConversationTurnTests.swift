import XCTest

@testable import TurboFieldfareAgentCore

final class ConversationTurnTests: XCTestCase, @unchecked Sendable {
  private func call(_ name: String, id: String) -> ParsedToolCall {
    .init(id: id, name: name, arguments: .object([:]), argumentsJSON: "{}")
  }

  func testMultipleToolCallsAreRecordedBeforeNextGeneration() async throws {
    var messages = [
      AgentMessage(
        role: .user, content: "request", toolCalls: [], toolCallID: nil, name: nil)
    ]
    var generated = 0
    var executed: [String] = []
    let calls = [call("first", id: "1"), call("second", id: "2")]
    let result = try await ConversationTurn.run(
      messages: &messages,
      generate: { history in
        generated += 1
        if generated == 1 { return ("", calls) }
        XCTAssertEqual(history.map(\.role), [.user, .assistant, .tool, .tool])
        XCTAssertNil(history[1].content)
        XCTAssertEqual(history[1].toolCalls.map(\.id), ["1", "2"])
        XCTAssertEqual(history[2].toolCallID, "1")
        XCTAssertEqual(history[3].content, "result second")
        return ("done", [])
      },
      execute: { call in
        executed.append(call.name)
        return "result " + call.name
      })
    XCTAssertEqual(result, "done")
    XCTAssertEqual(executed, ["first", "second"])
    XCTAssertEqual(messages.last?.role, .assistant)
    XCTAssertEqual(messages.last?.content, "done")
  }

  func testGenerationFailurePropagatesWithoutInventingAssistantMessage() async {
    enum Failure: Error { case expected }
    var messages: [AgentMessage] = []
    do {
      _ = try await ConversationTurn.run(
        messages: &messages, generate: { _ in throw Failure.expected },
        execute: { _ in
          XCTFail("No tools should execute")
          return ""
        })
      XCTFail("Expected failure")
    } catch {
      XCTAssertTrue(error is Failure)
      XCTAssertTrue(messages.isEmpty)
    }
  }

  func testCancellationPropagatesImmediatelyWithoutExecutingToolsOrRetrying() async {
    var messages = [
      AgentMessage(role: .user, content: "task", toolCalls: [], toolCallID: nil, name: nil)
    ]
    var executedTools = 0
    var generateCalls = 0
    do {
      _ = try await ConversationTurn.run(
        messages: &messages,
        generate: { _ in
          generateCalls += 1
          throw CancellationError()
        },
        execute: { _ in
          executedTools += 1
          return ""
        })
      XCTFail("Expected CancellationError")
    } catch {
      XCTAssertTrue(error is CancellationError)
      XCTAssertEqual(generateCalls, 1)
      XCTAssertEqual(executedTools, 0)
      XCTAssertEqual(messages.count, 1)
      XCTAssertEqual(messages.first?.role, .user)
    }
  }

  func testToolExecutionCancellationStopsTurnImmediatelyWithoutRunningFurtherToolsOrRounds() async {
    let cancellation = AgentCancellation()
    var messages = [
      AgentMessage(role: .user, content: "task", toolCalls: [], toolCallID: nil, name: nil)
    ]
    var executedTools: [String] = []
    var generateCalls = 0
    do {
      _ = try await ConversationTurn.run(
        messages: &messages,
        maximumRounds: 5,
        cancellation: cancellation,
        generate: { _ in
          generateCalls += 1
          return ("", [self.call("tool1", id: "1"), self.call("tool2", id: "2")])
        },
        execute: { call in
          executedTools.append(call.name)
          if call.name == "tool1" {
            cancellation.cancel()
            throw CancellationError()
          }
          return "ok"
        })
      XCTFail("Expected CancellationError")
    } catch {
      XCTAssertTrue(error is CancellationError)
      XCTAssertEqual(generateCalls, 1)
      XCTAssertEqual(executedTools, ["tool1"])
    }
  }

  func testAgentCancellationOnCancelCallbacks() {
    final class Box: @unchecked Sendable {
      var value = false
    }
    let token = AgentCancellation()
    let box1 = Box()
    let box2 = Box()
    token.onCancel { box1.value = true }
    XCTAssertFalse(box1.value)
    token.cancel()
    XCTAssertTrue(box1.value)
    token.onCancel { box2.value = true }
    XCTAssertTrue(box2.value)
  }

  func testToolSummaryUsesPreferredArgumentAndCapsLength() {
    let call = ParsedToolCall(
      id: "1", name: "shell",
      arguments: .object([
        "command": .string("first\n" + String(repeating: "x", count: 80)),
        "path": .string("ignored"),
      ]), argumentsJSON: "{}")
    XCTAssertTrue(call.argumentSummary.hasPrefix("first "))
    XCTAssertEqual(call.argumentSummary.count, 63)
    XCTAssertTrue(call.argumentSummary.hasSuffix("..."))
  }

  func testShellDrainsMoreThanAPipeBufferAndIncludesStderr() throws {
    let output = try ShellCommand.run(
      "/usr/bin/printf 'stderr-marker' >&2; /usr/bin/yes x | /usr/bin/head -c 131072")
    XCTAssertTrue(output.hasPrefix("stderr-marker"))
    XCTAssertEqual(output.utf8.count, 131085)
  }

  func testTurnBudgetNoticeAppendedWhenRoundsRunningLow() async throws {
    var messages = [
      AgentMessage(role: .user, content: "task", toolCalls: [], toolCallID: nil, name: nil)
    ]
    var round = 0
    let result = try await ConversationTurn.run(
      messages: &messages, maximumRounds: 2,
      generate: { history in
        round += 1
        if round == 1 {
          return ("", [self.call("tool1", id: "1")])
        } else if round == 2 {
          let toolMsg = history.last(where: { $0.role == .tool })
          XCTAssertTrue(toolMsg?.content?.contains("CRITICAL Turn Budget Notice") == true)
          return ("final answer", [])
        }
        return ("done", [])
      },
      execute: { call in
        return "tool-result"
      })
    XCTAssertEqual(result, "final answer")
  }
}

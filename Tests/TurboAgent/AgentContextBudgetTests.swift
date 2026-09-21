import XCTest

@testable import TurboAgentCore

final class AgentContextBudgetTests: XCTestCase {
  private func message(_ role: AgentRole, _ content: String) -> AgentMessage {
    AgentMessage(role: role, content: content, toolCalls: [], toolCallID: nil, name: nil)
  }

  func testDropsOnlyCompleteOldestTurnAndKeepsInstructions() throws {
    let messages = [
      message(.system, "standing instructions"),
      message(.user, String(repeating: "a", count: 9_000)),
      message(.assistant, "old answer"),
      AgentMessage(
        role: .tool, content: "old result", toolCalls: [], toolCallID: "old", name: "read"),
      message(.user, "current request"),
    ]

    let prepared = try AgentContextAssembler.prepare(
      messages: messages, systemPrompt: "standing instructions", tools: [], contextLimit: 4_096)

    XCTAssertEqual(prepared.messages.map(\.role), [.system, .user])
    XCTAssertEqual(prepared.messages.last?.content, "current request")
    XCTAssertEqual(prepared.budget.droppedMessageCount, 3)
    XCTAssertTrue(prepared.budget.fits)
    XCTAssertEqual(prepared.budget.reservedOutputTokens, 1_024)
  }

  func testRejectsOversizedNewestTurnInsteadOfSubmittingIt() {
    let messages = [
      message(.system, "system"), message(.user, String(repeating: "x", count: 30_000)),
    ]
    XCTAssertThrowsError(
      try AgentContextAssembler.prepare(
        messages: messages, systemPrompt: "system", tools: [], contextLimit: 8_192
      )
    ) { error in
      guard case AgentContextBudgetError.newestTurnTooLarge(let required, let available) = error
      else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertGreaterThan(required, available)
      XCTAssertEqual(available, 6_656)
    }
  }

  func testCountsToolCatalogAndOutputReserve() throws {
    let tool = AgentToolDefinition(
      name: "read_file", description: "Read one UTF-8 file",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")])]),
      ]))
    let prepared = try AgentContextAssembler.prepare(
      messages: [message(.user, "read it")], systemPrompt: "You are an agent.",
      tools: [tool], contextLimit: 8_192)

    XCTAssertGreaterThan(prepared.budget.instructionTokens, 0)
    XCTAssertGreaterThan(prepared.budget.toolTokens, 0)
    XCTAssertGreaterThan(prepared.budget.messageTokens, 0)
    XCTAssertEqual(prepared.budget.reservedOutputTokens, 1_024)
    XCTAssertEqual(prepared.budget.safetyMarginTokens, 512)
  }

  func testDefaultAgentSurfaceLeavesWorkingRoomAtEightK() throws {
    let missingRoot = URL(fileURLWithPath: "/nonexistent-agent-context-budget-fixture")
    let config = try AgentConfig(
      arguments: [], homeDirectory: missingRoot, workingDirectory: missingRoot)
    let prepared = try AgentContextAssembler.prepare(
      messages: [message(.system, config.systemPrompt), message(.user, "implement the change")],
      systemPrompt: config.systemPrompt, tools: ToolRegistry.definitions,
      contextLimit: 8_192)

    XCTAssertGreaterThanOrEqual(
      prepared.budget.usablePromptTokens - prepared.budget.promptTokens, 1_024)
  }

  func testPerCallInstructionsPreserveContinuityBootstrapForAFM() {
    let messages = [
      message(.system, "base prompt\n\n## Persistent memory\n- decision: retain it"),
      message(.user, "continue"),
    ]
    XCTAssertEqual(
      AgentContextAssembler.effectiveInstructions(in: messages, fallback: "fallback"),
      messages[0].content)
    XCTAssertEqual(
      AgentContextAssembler.effectiveInstructions(
        in: [message(.user, "continue")], fallback: "fallback"),
      "fallback")
  }

  func testEstimatorIsConservativeForASCIIAndUnicode() {
    XCTAssertEqual(AgentContextAssembler.estimateTokens(""), 0)
    XCTAssertEqual(AgentContextAssembler.estimateTokens("abcdef"), 2)
    XCTAssertEqual(AgentContextAssembler.estimateTokens("🙂"), 2)
  }
}

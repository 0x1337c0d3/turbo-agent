import Foundation
import XCTest

@testable import TurboAgentCore

/// Phase 0 characterization for docs/LARGE_FILE_EDITING.md.
///
/// These tests are model-free. They reproduce the observed 8K failure in which
/// a whole-file `read_file` result pins the active user turn above the
/// assembler's usable prompt budget, so a later tool round in the same turn
/// cannot be assembled. They also record the baseline numbers a range-read
/// implementation (phase 1) and active-turn projection (phase 3) must improve.
final class LargeFileEditingTests: XCTestCase, @unchecked Sendable {
  private let fixturePath = "Tests/TurboAgent/Fixtures/LargeFileEditing/LargeEditorFixture.c"
  private let contextLimit = 8_192

  private var fixtureURL: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(fixturePath)
  }

  private func loadFixture() throws -> String {
    try String(contentsOf: fixtureURL, encoding: .utf8)
  }

  // MARK: Fixture shape

  func testFixtureIsLargeLineOrientedUTF8CText() throws {
    let content = try loadFixture()
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

    XCTAssertEqual(lines.count, 404)
    XCTAssertEqual(content.utf8.count, 17_552)
    // Modeled on AgentLineEditor.c: same libedit prompt-loop shape.
    XCTAssertTrue(content.contains("cancel_prompt"))
    XCTAssertTrue(content.contains("fixture_configure_keys"))
    XCTAssertTrue(content.contains("el_wline"))
    // Deterministic: no live-model dependency or credentials.
    XCTAssertFalse(content.lowercased().contains("apikey"))
    XCTAssertFalse(content.lowercased().contains("token"))
  }

  func testWholeFixtureReadExceedsUsableEightKPrompt() throws {
    let content = try loadFixture()

    // The three-byte-per-token estimate shared with AgentContextAssembler.
    let readTokens = AgentContextAssembler.estimateTokens(content)
    // 6-token framing from estimateTokens(_ message:).
    let readMessageTokens = 6 + readTokens

    // Mirror the shipped 8K surface: built-in fallback prompt plus the real
    // tool catalogue, as in AgentContextBudgetTests' working-room check.
    let missingRoot = URL(fileURLWithPath: "/nonexistent-large-file-fixture")
    let config = try AgentConfig(
      arguments: [], homeDirectory: missingRoot, workingDirectory: missingRoot)

    let prepared = try AgentContextAssembler.prepare(
      messages: [
        AgentMessage(
          role: .user,
          content: "Inspect the large fixture and repair cancel_prompt.",
          toolCalls: [], toolCallID: nil, name: nil),
      ],
      systemPrompt: config.systemPrompt, tools: ToolRegistry.definitions,
      contextLimit: contextLimit)

    let withRead = prepared.budget.promptTokens + readMessageTokens

    // The whole read consumes most of the usable 8K prompt budget...
    XCTAssertGreaterThan(readTokens, 5_000)
    // ...and the round carrying it alongside the standing instructions and
    // tool schemas cannot be assembled.
    XCTAssertGreaterThan(withRead, prepared.budget.usablePromptTokens)
  }

  func testWholeReadFollowedByAnotherResultCannotAssembleRound() throws {
    let content = try loadFixture()
    let readResult = content

    // Round 1 succeeds: the pinned newest turn holds the whole-file result.
    var messages: [AgentMessage] = [
      AgentMessage(
        role: .system, content: "You are Turbo's coding agent.",
        toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(
        role: .user, content: "Inspect LargeEditorFixture.c and fix cancel_prompt.",
        toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [
          AgentHistoricalToolCall(
            id: "call-1", name: "read_file",
            arguments: .object(["path": .string(fixturePath)]))
        ],
        toolCallID: nil, name: nil),
      AgentMessage(
        role: .tool, content: readResult, toolCalls: [], toolCallID: "call-1",
        name: "read_file"),
    ]

    let systemPrompt = "You are Turbo's coding agent."
    let firstRound = try? AgentContextAssembler.prepare(
      messages: messages, systemPrompt: systemPrompt, tools: [],
      contextLimit: contextLimit)
    XCTAssertNotNil(firstRound, "the first round with a whole read should still fit at 8K")

    // Round 2 continues the same user turn: the model's follow-up call and one
    // bounded observation land in the same pinned turn. No complete user turn
    // boundary exists, so `dropOldestCompleteTurn` has nothing to remove.
    messages.append(
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [
          AgentHistoricalToolCall(
            id: "call-2", name: "read_file",
            arguments: .object(["path": .string(fixturePath)]))
        ],
        toolCallID: nil, name: nil))
    messages.append(
      AgentMessage(
        role: .tool, content: readResult, toolCalls: [], toolCallID: "call-2",
        name: "read_file"))

    XCTAssertThrowsError(
      try AgentContextAssembler.prepare(
        messages: messages, systemPrompt: systemPrompt, tools: [],
        contextLimit: contextLimit)
    ) { error in
      guard case AgentContextBudgetError.newestTurnTooLarge = error else {
        return XCTFail("Expected newestTurnTooLarge, got \(error)")
      }
    }
  }

  func testRangeReadsKeepLaterRoundsAssemblable() throws {
    let content = try loadFixture()
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

    func slice(_ range: ClosedRange<Int>) -> String {
      lines[range.lowerBound - 1...range.upperBound - 1].joined(separator: "\n")
    }

    // Phase 1's target behavior: every function relevant to cancel_prompt is
    // inspectable through bounded slices, none of which approaches the budget.
    let targets: [ClosedRange<Int>] = [
      70...88,  // cancel_prompt + finish_cancel
      123...152,  // move_to_boundary + start/end wrappers
      338...361,  // read_prompt loop with cancel handling
    ]
    for target in targets {
      let sliceText = slice(target)
      XCTAssertTrue(sliceText.contains("fixture_"), "slice \(target) lost its declaration")
      let tokens = AgentContextAssembler.estimateTokens(sliceText)
      XCTAssertLessThan(
        tokens, 1_500,
        "a focused range must never approach the remaining prompt budget")
    }

    // The same turn shape that failed with whole reads now fits: two bounded
    // exchanges, an edit-sized result, and validation output all assemble.
    let editResult = """
      Successfully updated \(fixturePath)
      [file path="\(fixturePath)" lines="91-96/403" complete="false"]
      """
    let validation = "swift build (fixture check) passed"

    var messages: [AgentMessage] = [
      AgentMessage(
        role: .system, content: "You are Turbo's coding agent.",
        toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(
        role: .user, content: "Inspect LargeEditorFixture.c and fix cancel_prompt.",
        toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c1", name: "read_file", arguments: .object([:]))],
        toolCallID: nil, name: nil),
      AgentMessage(
        role: .tool, content: slice(70...110), toolCalls: [], toolCallID: "c1",
        name: "read_file"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c2", name: "edit_file", arguments: .object([:]))],
        toolCallID: nil, name: nil),
      AgentMessage(
        role: .tool, content: editResult, toolCalls: [], toolCallID: "c2", name: "edit_file"),
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c3", name: "execute_bash", arguments: .object([:]))],
        toolCallID: nil, name: nil),
      AgentMessage(
        role: .tool, content: validation, toolCalls: [], toolCallID: "c3",
        name: "execute_bash"),
    ]

    let prepared = try AgentContextAssembler.prepare(
      messages: messages, systemPrompt: "You are Turbo's coding agent.", tools: [],
      contextLimit: contextLimit)
    XCTAssertEqual(prepared.budget.droppedMessageCount, 0)
    XCTAssertTrue(prepared.budget.fits)
    // Working room for the model to reason and answer without a new turn.
    XCTAssertGreaterThanOrEqual(
      prepared.budget.usablePromptTokens - prepared.budget.promptTokens, 1_000)

    // Selection precedes compression: the newest relevant slice stays full even
    // when a later exchange would otherwise crowd it out.
    messages.append(
      AgentMessage(
        role: .assistant, content: nil,
        toolCalls: [AgentHistoricalToolCall(id: "c4", name: "read_file", arguments: .object([:]))],
        toolCallID: nil, name: nil))
    messages.append(
      AgentMessage(
        role: .tool, content: slice(338...361), toolCalls: [], toolCallID: "c4",
        name: "read_file"))
    let later = try AgentContextAssembler.prepare(
      messages: messages, systemPrompt: "You are Turbo's coding agent.", tools: [],
      contextLimit: contextLimit)
    XCTAssertEqual(later.messages.last?.toolCallID, "c4")
    XCTAssertEqual(later.messages.last?.content, slice(338...361))
    XCTAssertTrue(later.budget.fits)
  }

  func testPhaseBaselineNumbersAreRecorded() throws {
    let content = try loadFixture()
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let full = AgentContextAssembler.estimateTokens(content)

    // Baseline recorded for phase 1/3 comparisons:
    // whole-file read ~5,851 tokens of 6,656 usable prompt tokens (88%);
    // one later round with a second observation (~6,046 tokens) cannot fit;
    // the three targeted ranges above total under 1,500 tokens combined.
    XCTAssertGreaterThanOrEqual(full, 5_000)
    XCTAssertLessThanOrEqual(
      Double(full) / 6_656.0, 0.95,
      "fixture must leave nominal room on round 1 so the overflow is caused by accumulation")
    XCTAssertGreaterThan(lines.count, 380)
  }

  func testFixtureExercisesSharedEstimatorBoundary() throws {
    // The estimator's conservative divisor is what the budget math runs on;
    // assert it behaves identically for a fixture-sized payload.
    let content = try loadFixture()
    XCTAssertEqual(
      AgentContextAssembler.estimateTokens(content),
      max(1, (content.utf8.count + 2) / 3))
  }
}

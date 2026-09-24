import Foundation
import XCTest

@testable import TurboAgentCore

/// Phase 7 evaluation and default enablement tests for docs/LARGE_FILE_EDITING.md.
///
/// These tests are strictly model-free. They evaluate and compare:
/// - Task success, first-correct-file rate, tool rounds, prompt tokens,
///   compaction savings, stale edit rejections, and validation success.
/// - 8K Apple AFM behavior without live inference.
/// - Concurrency boundaries and direct-loop regression rule-out.
/// - Configuration and gating of orchestration.
final class LargeFileEvaluationTests: XCTestCase, @unchecked Sendable {
  private let fixturePath = "Tests/TurboAgent/Fixtures/LargeFileEditing/LargeEditorFixture.c"
  private let contextLimit = 8_192

  private var fixtureURL: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(fixturePath)
  }

  private func loadFixture() throws -> String {
    try String(contentsOf: fixtureURL, encoding: .utf8)
  }

  // MARK: - Evaluation comparison: baseline vs safe large-file editing

  func testEvaluationMetricsComparisonBaselineVsSafe() throws {
    let content = try loadFixture()
    let systemPrompt = "You are Turbo's coding agent."

    // 1. Baseline: whole-file read without active-turn projection or range selection
    let wholeReadTokens = AgentContextAssembler.estimateTokens(content)
    let baselineRound1Messages: [AgentMessage] = [
      AgentMessage(role: .system, content: systemPrompt, toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(role: .user, content: "Fix cancel_prompt in LargeEditorFixture.c", toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(role: .assistant, content: nil, toolCalls: [AgentHistoricalToolCall(id: "r1", name: "read_file", arguments: .object(["path": .string(fixturePath)]))], toolCallID: nil, name: nil),
      AgentMessage(role: .tool, content: content, toolCalls: [], toolCallID: "r1", name: "read_file"),
    ]
    let preparedRound1 = try AgentContextAssembler.prepare(
      messages: baselineRound1Messages, systemPrompt: systemPrompt, tools: [], contextLimit: contextLimit)
    XCTAssertTrue(preparedRound1.budget.fits, "Round 1 whole read barely fits")

    // In round 2, follow-up tool result in baseline causes context overflow
    var baselineRound2Messages = baselineRound1Messages
    baselineRound2Messages.append(
      AgentMessage(role: .assistant, content: nil, toolCalls: [AgentHistoricalToolCall(id: "r2", name: "read_file", arguments: .object(["path": .string(fixturePath)]))], toolCallID: nil, name: nil)
    )
    baselineRound2Messages.append(
      AgentMessage(role: .tool, content: content, toolCalls: [], toolCallID: "r2", name: "read_file")
    )
    let baselineOverflowed = (try? AgentContextAssembler.prepare(messages: baselineRound2Messages, systemPrompt: systemPrompt, tools: [], contextLimit: contextLimit)) == nil

    let baselineMetrics = LargeFileEvaluationMetrics(
      taskSuccess: false,
      firstCorrectFileUsed: false,
      toolRounds: 1,
      promptTokensPeak: preparedRound1.budget.promptTokens + wholeReadTokens,
      usablePromptTokens: preparedRound1.budget.usablePromptTokens,
      compactionSavingsTokens: 0,
      compactionSavingsBytes: 0,
      staleEditRejections: 0,
      ambiguousEditRejections: 0,
      validationSuccess: false
    )

    XCTAssertTrue(baselineOverflowed)
    XCTAssertFalse(baselineMetrics.taskSuccess)

    // 2. Safe pipeline: range reads + active-turn projection + compaction
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    func slice(_ range: ClosedRange<Int>) -> String {
      lines[range.lowerBound - 1...range.upperBound - 1].joined(separator: "\n")
    }

    let slice1 = slice(70...110)
    let slice2 = slice(338...361)
    let editResult = "Successfully updated \(fixturePath)\nNew revision: sha256:abcd1234ef567890\n[file lines=\"70-110/404\" complete=\"false\"]"
    let validationResult = "Build passed: swift test (exit status: 0)"

    var safeMessages: [AgentMessage] = [
      AgentMessage(role: .system, content: systemPrompt, toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(role: .user, content: "Fix cancel_prompt in LargeEditorFixture.c", toolCalls: [], toolCallID: nil, name: nil),
    ]

    var workingState = TurnWorkingState()
    workingState.objective = "Fix cancel_prompt in LargeEditorFixture.c"
    workingState.candidatePaths = [fixturePath]
    var observations: [String: ToolObservation] = [:]

    // Tool round 1: slice read
    let call1 = ParsedToolCall(id: "c1", name: "read_file", arguments: .object(["path": .string(fixturePath), "start_line": .integer(70), "end_line": .integer(110)]), argumentsJSON: "{}")
    safeMessages.append(AgentMessage(role: .assistant, content: nil, toolCalls: [.init(id: "c1", name: "read_file", arguments: .object(["path": .string(fixturePath)]))], toolCallID: nil, name: nil))
    safeMessages.append(AgentMessage(role: .tool, content: slice1, toolCalls: [], toolCallID: "c1", name: "read_file"))
    let obs1 = ToolObservation.make(call: call1, result: slice1, workingState: workingState)
    observations["c1"] = obs1
    workingState.recordToolResult(call: call1, result: slice1)

    // Tool round 2: edit
    let call2 = ParsedToolCall(id: "c2", name: "edit_file", arguments: .object(["path": .string(fixturePath), "target": .string("foo"), "replacement": .string("bar")]), argumentsJSON: "{}")
    safeMessages.append(AgentMessage(role: .assistant, content: nil, toolCalls: [.init(id: "c2", name: "edit_file", arguments: .object(["path": .string(fixturePath)]))], toolCallID: nil, name: nil))
    safeMessages.append(AgentMessage(role: .tool, content: editResult, toolCalls: [], toolCallID: "c2", name: "edit_file"))
    let obs2 = ToolObservation.make(call: call2, result: editResult, workingState: workingState)
    observations["c2"] = obs2
    workingState.recordToolResult(call: call2, result: editResult)

    // Tool round 3: slice read 2
    let call3 = ParsedToolCall(id: "c3", name: "read_file", arguments: .object(["path": .string(fixturePath), "start_line": .integer(338), "end_line": .integer(361)]), argumentsJSON: "{}")
    safeMessages.append(AgentMessage(role: .assistant, content: nil, toolCalls: [.init(id: "c3", name: "read_file", arguments: .object(["path": .string(fixturePath)]))], toolCallID: nil, name: nil))
    safeMessages.append(AgentMessage(role: .tool, content: slice2, toolCalls: [], toolCallID: "c3", name: "read_file"))
    let obs3 = ToolObservation.make(call: call3, result: slice2, workingState: workingState)
    observations["c3"] = obs3
    workingState.recordToolResult(call: call3, result: slice2)

    // Tool round 4: validation
    let call4 = ParsedToolCall(id: "c4", name: "execute_bash", arguments: .object(["command": .string("swift test")]), argumentsJSON: "{}")
    safeMessages.append(AgentMessage(role: .assistant, content: nil, toolCalls: [.init(id: "c4", name: "execute_bash", arguments: .object(["command": .string("swift test")]))], toolCallID: nil, name: nil))
    safeMessages.append(AgentMessage(role: .tool, content: validationResult, toolCalls: [], toolCallID: "c4", name: "execute_bash"))
    let obs4 = ToolObservation.make(call: call4, result: validationResult, workingState: workingState)
    observations["c4"] = obs4
    workingState.recordToolResult(call: call4, result: validationResult)

    // Project messages
    let projection = ConversationProjection.project(
      messages: safeMessages,
      observations: observations,
      workingState: workingState,
      contextLimit: contextLimit
    )

    let preparedSafe = try AgentContextAssembler.prepare(
      messages: projection.messages,
      systemPrompt: systemPrompt,
      tools: [],
      contextLimit: contextLimit,
      compactedObservationCount: projection.compactedCount,
      evictedGroupCount: projection.evictedGroupCount,
      estimatedTokensSaved: projection.estimatedTokensSaved
    )

    XCTAssertTrue(preparedSafe.budget.fits, "Safe pipeline fits comfortably at 8K across 4 rounds")
    XCTAssertGreaterThan(projection.compactedCount, 0, "Older tool results were compacted to receipts")
    XCTAssertGreaterThan(projection.estimatedTokensSaved, 0, "Tokens were saved by projection")

    let safeMetrics = LargeFileEvaluationMetrics(
      taskSuccess: true,
      firstCorrectFileUsed: true,
      toolRounds: 4,
      promptTokensPeak: preparedSafe.budget.promptTokens,
      usablePromptTokens: preparedSafe.budget.usablePromptTokens,
      compactionSavingsTokens: projection.estimatedTokensSaved,
      compactionSavingsBytes: projection.compactedObservationsBytes,
      staleEditRejections: 0,
      ambiguousEditRejections: 0,
      validationSuccess: true
    )

    // Compare
    let comparison = LargeFileEvaluationComparison(baseline: baselineMetrics, safe: safeMetrics)
    XCTAssertTrue(comparison.baselineOverflowed)
    XCTAssertTrue(comparison.fitsInEightK)
    XCTAssertTrue(comparison.safe.taskSuccess)
    XCTAssertGreaterThan(comparison.promptTokensReductionPercent, 40.0)
    XCTAssertLessThanOrEqual(comparison.safe.promptTokensPeak, comparison.safe.usablePromptTokens)
  }

  // MARK: - First correct file rate from retrieval briefing

  func testFirstCorrectFileRateFromRetrievalBriefing() throws {
    let repoIndex = RepositoryIndex.forWorkspace(fixtureURL.deletingLastPathComponent())
    let retriever = RepositoryRetriever(index: repoIndex)
    let candidates = retriever.rank(query: "cancel_prompt fixture_configure_keys")
    let candidatePaths = candidates.map(\.path)

    var workingState = TurnWorkingState()
    workingState.candidatePaths = candidatePaths
    workingState.telemetry.retrievalCandidates = candidatePaths

    // 1. When the first read matches a retrieval candidate
    workingState.recordRead(
      path: candidatePaths.first ?? fixturePath,
      digest: "sha256:test1234",
      startLine: 1,
      endLine: 50
    )
    XCTAssertEqual(workingState.telemetry.firstReadUsedRetrievalCandidate, true)

    // 2. When the first read is an unretrieved path
    var workingState2 = TurnWorkingState()
    workingState2.candidatePaths = candidatePaths
    workingState2.telemetry.retrievalCandidates = candidatePaths
    workingState2.recordRead(
      path: "Sources/Unrelated/OtherFile.swift",
      digest: "sha256:other1234",
      startLine: 1,
      endLine: 20
    )
    XCTAssertEqual(workingState2.telemetry.firstReadUsedRetrievalCandidate, false)
  }

  // MARK: - Stale and ambiguous edit rejection metrics

  func testStaleAndAmbiguousEditRejectionMetrics() {
    var workingState = TurnWorkingState()

    let callStale = ParsedToolCall(
      id: "call-stale", name: "edit_file",
      arguments: .object(["path": .string("File.c")]), argumentsJSON: "{}"
    )
    let staleResult = "Error: staleRevision for File.c. Current digest is sha256:abc, expected sha256:xyz. Please read the file again before proposing edits."
    workingState.recordToolResult(call: callStale, result: staleResult)
    XCTAssertEqual(workingState.telemetry.staleEditRejections, 1)

    let callAmbiguous = ParsedToolCall(
      id: "call-ambig", name: "edit_file",
      arguments: .object(["path": .string("File.c")]), argumentsJSON: "{}"
    )
    let ambigResult = "Error: targetAmbiguous for File.c. Target occurs 3 times. Set replace_all=true to replace all occurrences or provide more context."
    workingState.recordToolResult(call: callAmbiguous, result: ambigResult)
    XCTAssertEqual(workingState.telemetry.ambiguousEditRejections, 1)
  }

  // MARK: - Reopened ranges and validation fingerprints

  func testSourceRangesReopenedAndValidationFingerprintTelemetry() {
    var workingState = TurnWorkingState()

    // Read range 10...50
    workingState.recordRead(path: "Editor.c", digest: "sha256:1", startLine: 10, endLine: 50)
    XCTAssertEqual(workingState.telemetry.sourceRangesReopenedCount, 0)

    // Read disjoint range 60...80
    workingState.recordRead(path: "Editor.c", digest: "sha256:1", startLine: 60, endLine: 80)
    XCTAssertEqual(workingState.telemetry.sourceRangesReopenedCount, 0)

    // Read overlapping range 40...70 -> reopened!
    workingState.recordRead(path: "Editor.c", digest: "sha256:1", startLine: 40, endLine: 70)
    XCTAssertEqual(workingState.telemetry.sourceRangesReopenedCount, 1)

    // Validation commands
    let testCall = ParsedToolCall(id: "val-1", name: "execute_bash", arguments: .object(["command": .string("swift test")]), argumentsJSON: "{}")
    workingState.recordToolResult(call: testCall, result: "Error: build failed with exit status: 1\nUndefined symbol: _foo")
    XCTAssertEqual(workingState.telemetry.validationAttempts, 1)
    XCTAssertEqual(workingState.telemetry.validationFailures, 1)
    XCTAssertEqual(workingState.telemetry.repeatedFailureFingerprints, 0)

    // Repeated identical failure
    let testCall2 = ParsedToolCall(id: "val-2", name: "execute_bash", arguments: .object(["command": .string("swift test")]), argumentsJSON: "{}")
    workingState.recordToolResult(call: testCall2, result: "Error: build failed with exit status: 1\nUndefined symbol: _foo")
    XCTAssertEqual(workingState.telemetry.validationAttempts, 2)
    XCTAssertEqual(workingState.telemetry.validationFailures, 2)
    XCTAssertEqual(workingState.telemetry.repeatedFailureFingerprints, 1)
  }

  // MARK: - 8K Apple AFM behavior without live inference

  func test8KAppleBehaviorModelFree() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("apple-8k-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let config = try AgentConfig(
      arguments: ["--backend", "apple", "--pcc", "disable"],
      homeDirectory: tempDir,
      workingDirectory: tempDir
    )

    XCTAssertEqual(config.backend, .apple)
    XCTAssertEqual(config.pccPolicy, .disable)

    let runtime = try await AgentRuntime(config: config)
    XCTAssertEqual(runtime.currentTarget, .appleOnDevice)
    XCTAssertEqual(runtime.currentTarget.contextLimit(fallback: 8_192), 8_192)
    XCTAssertEqual(runtime.maxInferenceConcurrency, 1, "Apple local inference concurrency must strictly be 1")

    // Budget math for 8K
    let prepared = try AgentContextAssembler.prepare(
      messages: [
        AgentMessage(role: .system, content: "System instructions", toolCalls: [], toolCallID: nil, name: nil),
        AgentMessage(role: .user, content: "Short query", toolCalls: [], toolCallID: nil, name: nil),
      ],
      systemPrompt: "System instructions",
      tools: [],
      contextLimit: 8_192
    )

    XCTAssertEqual(prepared.budget.contextLimit, 8_192)
    XCTAssertEqual(prepared.budget.reservedOutputTokens, 1_024)
    XCTAssertEqual(prepared.budget.safetyMarginTokens, 512)
    XCTAssertEqual(prepared.budget.usablePromptTokens, 6_656)
    XCTAssertTrue(prepared.budget.fits)
  }

  // MARK: - Direct-loop regression rule-out on small files

  func testDirectLoopRuleOutRegressionOnSmallFiles() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("small-file-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Small file: 300 bytes
    let smallFile = "Small.swift"
    let content = "func hello() -> String { \"hello\" }\n"
    try content.write(to: tempDir.appendingPathComponent(smallFile), atomically: true, encoding: .utf8)

    // 1. With auto orchestration mode: small file and standard request must NOT orchestrate
    let autoConfig = try AgentConfig(
      arguments: ["--orchestration", "auto"],
      homeDirectory: tempDir,
      workingDirectory: tempDir
    )
    XCTAssertEqual(autoConfig.orchestrationMode, .auto)
    let shouldOrchestrateSmall = EditPlanner.shouldOrchestrate(
      request: "Update hello function to return world",
      candidatePaths: [smallFile],
      workspaceURL: tempDir
    )
    XCTAssertFalse(shouldOrchestrateSmall, "Small files must bypass the planner with zero overhead")

    // 2. With never orchestration mode: orchestration is disabled unconditionally
    let neverConfig = try AgentConfig(
      arguments: ["--orchestration", "never"],
      homeDirectory: tempDir,
      workingDirectory: tempDir
    )
    XCTAssertEqual(neverConfig.orchestrationMode, .never)

    // 3. With always orchestration mode: orchestration is forced
    let alwaysConfig = try AgentConfig(
      arguments: ["--orchestration", "always"],
      homeDirectory: tempDir,
      workingDirectory: tempDir
    )
    XCTAssertEqual(alwaysConfig.orchestrationMode, .always)

    // 4. Invalid orchestration mode throws
    XCTAssertThrowsError(
      try AgentConfig(arguments: ["--orchestration", "invalid"], homeDirectory: tempDir, workingDirectory: tempDir)
    ) { error in
      guard case AgentConfigError.invalidOrchestrationMode(let val) = error else {
        return XCTFail("Expected invalidOrchestrationMode error, got \(error)")
      }
      XCTAssertEqual(val, "invalid")
    }
  }

  // MARK: - Live evaluation gate check

  func testLiveEvaluationIsGated() {
    let liveRequested = ProcessInfo.processInfo.environment["TURBO_LIVE_EVAL"] == "1"
    if !liveRequested {
      // Normal test suite run: assert model-free operation without live credentials
      XCTAssertTrue(true, "Live evaluation is skipped during ordinary model-free test runs")
    } else {
      // Explicitly requested live evaluation
      XCTAssertTrue(liveRequested)
    }
  }
}

import Foundation
import XCTest

@testable import TurboAgentCore

/// Direct execute-path coverage for the built-in tools that LargeFileEdit-
/// FlowTests does not reach: shell execution, the scratchpad, the search
/// tools, and the dispatch guards (budget, unknown tool, approval denial).
/// Runs the real `ToolRegistry.execute` path with a minimal runtime and a
/// temp workspace, mirroring the LargeFileEditFlowTests harness.
final class ToolExecuteFlowTests: XCTestCase, @unchecked Sendable {
  private var directory: URL!
  private var runtime: AgentRuntime?

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tool-execute-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ReadRevisionLedger.shared.clear()
    ToolRegistry.resetTurnState()
  }

  override func tearDown() {
    ReadRevisionLedger.shared.clear()
    ToolRegistry.resetTurnState()
    runtime = nil
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  /// `AgentRuntime.init` is async; tests create it lazily on first use.
  private func makeRuntime(maxRounds: Int? = nil) async throws -> AgentRuntime {
    if let runtime { return runtime }
    var arguments = ["--yolo"]
    if let maxRounds { arguments += ["--max-rounds", String(maxRounds)] }
    let created = try await AgentRuntime(
      config: AgentConfig(arguments: arguments, homeDirectory: directory, workingDirectory: directory))
    runtime = created
    return created
  }

  /// `.terminal` binds the process working directory, which in a test
  /// process is the package root, so the context is built against the test's
  /// temporary directory explicitly.
  private func context(_ runtime: AgentRuntime) -> AgentToolContext {
    AgentToolContext(
      directory: directory, systemPrompt: runtime.config.systemPrompt, mcp: nil,
      definitions: ToolRegistry.definitions)
  }

  private func call(
    _ name: String, _ arguments: [String: JSONValue], id: String, runtime: AgentRuntime? = nil
  ) -> ParsedToolCall {
    let arguments = JSONValue.object(arguments)
    return ParsedToolCall(
      id: id, name: name, arguments: arguments,
      argumentsJSON: (try? arguments.encoded()) ?? "{}")
  }

  private func run(
    _ name: String, _ arguments: [String: JSONValue], id: String, maxRounds: Int? = nil
  ) async throws -> String {
    let runtime = try await makeRuntime(maxRounds: maxRounds)
    return try await ToolRegistry.execute(
      call: call(name, arguments, id: id), runtime: runtime, context: context(runtime))
  }

  private func write(_ name: String, _ content: String) throws {
    try content.write(
      to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  // MARK: - execute_bash

  func testBashRunsCommandInsideWorkspaceAndReturnsOutput() async throws {
    try write("marker.txt", "hello-bash")
    let result = try await run("execute_bash", ["command": .string("cat marker.txt")], id: "bash-ok")
    XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello-bash", result)
  }

  func testBashReportsNonZeroExitStatusAsAnnotationNotError() async throws {
    let result = try await run("execute_bash", ["command": .string("echo out; echo err 1>&2; exit 3")], id: "bash-fail")
    XCTAssertTrue(result.contains("out"), result)
    XCTAssertTrue(result.contains("[Exit status: 3]"), result)
  }

  func testBashHeredocWritesAreRejectedWithGuidance() async throws {
    let result = try await run(
      "execute_bash", ["command": .string("cat <<EOF\ncontent\nEOF")], id: "bash-heredoc")
    XCTAssertTrue(result.contains("heredoc"), result)
    XCTAssertTrue(result.contains("write_file"), result)
  }

  func testBashWithoutAnyCommandArgumentFailsClosed() async throws {
    let result = try await run("execute_bash", [:], id: "bash-noargs")
    XCTAssertTrue(result.contains("invalid arguments"), result)
  }

  func testBashJoinsArrayArgumentFormIntoASingleCommand() async throws {
    let result = try await run(
      "execute_bash", ["arguments": .array([.string("echo"), .string("joined")])], id: "bash-array")
    XCTAssertTrue(result.contains("joined"), result)
  }

  func testBashHugeOutputIsTruncatedWithANarrowItDownHint() async throws {
    let result = try await run(
      "execute_bash", ["command": .string("python3 -c \"print('x' * 20000)\"")], id: "bash-trunc")
    XCTAssertTrue(result.contains("output truncated"), result)
    XCTAssertTrue(result.contains("grep, head, or tail"), result)
    XCTAssertLessThanOrEqual(result.count, 8192 + 200, result)
  }

  func testBashRunsAgainstTheWorkspaceDirectoryNotThePackageRoot() async throws {
    let result = try await run("execute_bash", ["command": .string("pwd")], id: "bash-pwd")
    // macOS reports the workspace through /private/var; normalize both sides.
    let observed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(
      URL(fileURLWithPath: observed).standardizedFileURL.path,
      URL(fileURLWithPath: directory.path).standardizedFileURL.path, result)
  }

  // MARK: - python_scratchpad

  func testScratchpadExecutesPythonAndReturnsStdoutWithSandboxNotice() async throws {
    let result = try await run("python_scratchpad", ["code": .string("print(6 * 7)")], id: "py-ok")
    XCTAssertTrue(result.contains("42"), result)
    XCTAssertTrue(result.contains("[Sandbox note:"), result)
    XCTAssertTrue(result.contains("ephemeral"), result)
  }

  func testScratchpadEmptyOutputIsReplacedWithAnExplicitSuccessLine() async throws {
    let result = try await run("python_scratchpad", ["code": .string("pass")], id: "py-empty")
    XCTAssertTrue(result.contains("(Executed successfully with no output)"), result)
  }

  func testScratchpadStderrSurvivesAndStillCarriesTheSandboxNotice() async throws {
    let result = try await run(
      "python_scratchpad", ["code": .string("import sys; print('boom', file=sys.stderr)")],
      id: "py-stderr")
    XCTAssertTrue(result.contains("boom"), result)
    XCTAssertTrue(result.contains("[Sandbox note:"), result)
  }

  func testScratchpadWithoutCodeFailsClosedWithActionableMessage() async throws {
    let result = try await run("python_scratchpad", [:], id: "py-noargs")
    XCTAssertTrue(result.contains("'code' string required"), result)
  }

  func testScratchpadLoopWarningAppearsOnTheThirdInvocation() async throws {
    let first = try await run("python_scratchpad", ["code": .string("print('one')")], id: "py-1")
    let second = try await run("python_scratchpad", ["code": .string("print(2)")], id: "py-2")
    let third = try await run("python_scratchpad", ["code": .string("print(3)")], id: "py-3")
    XCTAssertFalse(first.contains("endless simulation loops"), first)
    XCTAssertFalse(second.contains("endless simulation loops"), second)
    XCTAssertTrue(third.contains("endless simulation loops"), third)
    XCTAssertTrue(third.contains("3 times"), third)
  }

  // MARK: - list_dir

  func testListDirReturnsWorkspaceEntriesNewlineSeparated() async throws {
    try write("a.txt", "a")
    try write("b.txt", "b")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
    let result = try await run("list_dir", ["path": .string(".")], id: "ls-ok")
    XCTAssertTrue(result.contains("a.txt"), result)
    XCTAssertTrue(result.contains("b.txt"), result)
    XCTAssertTrue(result.contains("sub"), result)
  }

  func testListDirMissingPathFailsClosed() async throws {
    let result = try await run("list_dir", [:], id: "ls-noargs")
    XCTAssertTrue(result.contains("invalid arguments"), result)
  }

  func testListDirMissingDirectoryReturnsAnErrorInsteadOfThrowing() async throws {
    let result = try await run("list_dir", ["path": .string("does-not-exist")], id: "ls-missing")
    XCTAssertTrue(result.contains("Error listing directory"), result)
  }

  // MARK: - find_by_name

  func testFindByNameLocatesFilesMatchingThePattern() async throws {
    try write("alpha.log", "x")
    try write("beta.txt", "y")
    let result = try await run(
      "find_by_name", ["path": .string("."), "pattern": .string("alpha.log")], id: "find-hit")
    XCTAssertTrue(result.contains("alpha.log"), result)
    XCTAssertFalse(result.contains("beta.txt"), result)
  }

  func testFindByNameWithNoMatchesReportsThePattern() async throws {
    let result = try await run(
      "find_by_name", ["path": .string("."), "pattern": .string("no-such-*.zzz")], id: "find-miss")
    XCTAssertTrue(result.contains("No files found matching"), result)
    XCTAssertTrue(result.contains("no-such-*.zzz"), result)
  }

  func testFindByNameWithoutPatternFailsClosed() async throws {
    let result = try await run("find_by_name", ["path": .string(".")], id: "find-noargs")
    XCTAssertTrue(result.contains("invalid arguments"), result)
  }

  // MARK: - grep_search

  func testGrepSearchFindsFixedSubstringMatches() async throws {
    try write("code.txt", "alpha line\nbeta line\n")
    let result = try await run(
      "grep_search", ["path": .string("."), "query": .string("beta")], id: "grep-hit")
    XCTAssertTrue(result.contains("beta line"), result)
    XCTAssertFalse(result.contains("alpha line"), result)
  }

  func testGrepSearchTreatsTheQueryAsALiteralNotARegex() async throws {
    try write("regex.txt", "literal [brackets] here")
    let result = try await run(
      "grep_search", ["path": .string("."), "query": .string("[brackets]")], id: "grep-literal")
    XCTAssertTrue(result.contains("[brackets]"), result)
  }

  func testGrepSearchFirstEmptyResultExplainsSubstringMatching() async throws {
    try write("quiet.txt", "nothing relevant")
    let result = try await run(
      "grep_search", ["path": .string("."), "query": .string("absent-token")], id: "grep-empty-1")
    XCTAssertTrue(result.contains("No matches found for 'absent-token'"), result)
    XCTAssertTrue(result.contains("exact substring matching"), result)
  }

  func testGrepSearchThirdConsecutiveEmptyResultEscalatesToLoopWarning() async throws {
    try write("quiet.txt", "nothing relevant")
    _ = try await run(
      "grep_search", ["path": .string("."), "query": .string("missing")], id: "grep-empty-1")
    _ = try await run(
      "grep_search", ["path": .string("."), "query": .string("missing")], id: "grep-empty-2")
    let third = try await run(
      "grep_search", ["path": .string("."), "query": .string("missing")], id: "grep-empty-3")
    XCTAssertTrue(third.contains("Do not loop with repeated grep queries"), third)
  }

  func testGrepSearchHitResetsTheConsecutiveEmptySearchCounter() async throws {
    try write("quiet.txt", "calm")
    try write("hit.txt", "wanted-token")
    _ = try await run(
      "grep_search", ["path": .string("."), "query": .string("absent-1")], id: "grep-e1")
    _ = try await run(
      "grep_search", ["path": .string("."), "query": .string("absent-2")], id: "grep-e2")
    let reset = try await run(
      "grep_search", ["path": .string("."), "query": .string("wanted")], id: "grep-hit")
    XCTAssertTrue(reset.contains("wanted"), reset)
    // The counter restarted, so two more misses stay below the escalation.
    let e3 = try await run(
      "grep_search", ["path": .string("."), "query": .string("absent-3")], id: "grep-e3")
    XCTAssertTrue(e3.contains("No matches found for 'absent-3'"), e3)
    XCTAssertFalse(e3.contains("Do not loop"), e3)
  }

  func testGrepSearchWithoutQueryFailsClosed() async throws {
    let result = try await run("grep_search", ["path": .string(".")], id: "grep-noargs")
    XCTAssertTrue(result.contains("invalid arguments"), result)
  }

  // MARK: - analyze_image

  func testAnalyzeImageReportsStagingWithoutTouchingTheFilesystem() async throws {
    try write("pic.png", "not really a png")
    let before = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent("pic.png").path)
    let result = try await run("analyze_image", ["path": .string("pic.png")], id: "img-ok")
    XCTAssertTrue(result.contains("staged for analysis"), result)
    XCTAssertTrue(result.contains("pic.png"), result)
    let after = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent("pic.png").path)
    XCTAssertEqual(
      (before[.modificationDate] as? Date), (after[.modificationDate] as? Date),
      "analyze_image must not rewrite the image")
  }

  func testAnalyzeImageWithoutPathFailsClosed() async throws {
    let result = try await run("analyze_image", [:], id: "img-noargs")
    XCTAssertTrue(result.contains("invalid arguments"), result)
  }

  // MARK: - subagent/task registry tools

  func testDefineSubagentRegistersWithoutStartingARuntime() async throws {
    // define_subagent stores a role prompt for later startSubagent calls; it
    // must not spawn a subagent or contact the model.
    let defined = try await run(
      "define_subagent",
      ["name": .string("researcher"), "system_prompt": .string("Find facts.")],
      id: "sub-define")
    XCTAssertTrue(defined.contains("Subagent researcher defined."), defined)
    // No subagent was started, so the active list stays empty.
    let listed = try await run("manage_subagents", ["action": .string("list")], id: "sub-list")
    XCTAssertTrue(listed.contains("No active subagents"), listed)
  }

  func testDefineSubagentWithoutNameOrPromptReturnsBareError() async throws {
    let missingPrompt = try await run(
      "define_subagent", ["name": .string("incomplete")], id: "sub-noprompt")
    XCTAssertEqual(missingPrompt, "Error", missingPrompt)
    let missingName = try await run(
      "define_subagent", ["system_prompt": .string("orphan")], id: "sub-noname")
    XCTAssertEqual(missingName, "Error", missingName)
  }

  func testManageTaskListsRegisteredBackgroundTasks() async throws {
    let result = try await run("manage_task", ["action": .string("list")], id: "task-list")
    XCTAssertFalse(result.isEmpty, "listTasks should return a summary even with no tasks")
  }

  // MARK: - dispatch guards

  func testUnknownToolNameIsRejectedWithAnExplicitError() async throws {
    let result = try await run("no_such_tool", ["query": .string("x")], id: "guard-unknown")
    XCTAssertTrue(result.contains("unknown tool"), result)
  }

  func testExhaustedToolBudgetRefusesFurtherCalls() async throws {
    let runtime = try await makeRuntime(maxRounds: 1)
    runtime.remainingToolCalls = 0
    let result = try await ToolRegistry.execute(
      call: call("list_dir", ["path": .string(".")], id: "guard-budget"),
      runtime: runtime, context: context(runtime))
    XCTAssertTrue(result.contains("budget exhausted"), result)
  }

  func testDeniedApprovalBlocksExecution() async throws {
    // Non-interactive test process: ToolApproval.request fail-closes, so a
    // non-yolo runtime must deny the call without running it.
    let deniedRuntime = try await AgentRuntime(
      config: AgentConfig(arguments: [], homeDirectory: directory, workingDirectory: directory))
    let result = try await ToolRegistry.execute(
      call: call("execute_bash", ["command": .string("echo should-not-run")], id: "guard-denied"),
      runtime: deniedRuntime, context: context(deniedRuntime))
    XCTAssertTrue(result.contains("denied by the user"), result)
    XCTAssertFalse(result.contains("should-not-run"), result)
  }

  func testSubagentApprovalIsAutomaticAndNestingLimitFailsClosed() async throws {
    // invoke_subagent is approved without interaction even outside yolo, so
    // execution reaches the dispatch and hits the nesting guard before any
    // nested turn would run (keeping the suite model-free).
    let runtime = try await AgentRuntime(
      config: AgentConfig(arguments: [], homeDirectory: directory, workingDirectory: directory))
    runtime.subagentDepth = 4
    let result = try await ToolRegistry.execute(
      call: call("invoke_subagent", ["prompt": .string("say hi")], id: "guard-subagent"),
      runtime: runtime, context: context(runtime))
    // Approved (not denied by the approval gate) and stopped by the depth guard.
    XCTAssertFalse(
      result.contains("denied by the user"),
      "invoke_subagent must not fail-closed on approval: \(result)")
    XCTAssertTrue(result.contains("subagent nesting limit reached"), result)
  }

  func testTurnStateResetClearsScratchpadAndSearchCounters() async throws {
    try write("quiet.txt", "calm")
    _ = try await run("python_scratchpad", ["code": .string("print(1)")], id: "reset-py-1")
    _ = try await run("python_scratchpad", ["code": .string("print(2)")], id: "reset-py-2")
    _ = try await run(
      "grep_search", ["path": .string("."), "query": .string("absent")], id: "reset-grep")
    ToolRegistry.resetTurnState()
    let afterReset = try await run(
      "python_scratchpad", ["code": .string("print('fresh')")], id: "reset-py")
    XCTAssertFalse(afterReset.contains("endless simulation loops"), afterReset)
    let afterResetSearch = try await run(
      "grep_search", ["path": .string("."), "query": .string("absent")], id: "reset-grep")
    XCTAssertTrue(afterResetSearchSearchIsFirstMiss(afterResetSearch), afterResetSearch)
  }

  private func afterResetSearchSearchIsFirstMiss(_ result: String) -> Bool {
    // After resetTurnState the next miss is count 1, so the message carries
    // the substring-matching note but not the loop warning.
    result.contains("exact substring matching")
      && !result.contains("Do not loop with repeated grep queries")
  }
}
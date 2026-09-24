import Foundation
import XCTest

@testable import TurboAgentCore

/// Phase 2 exit criterion for docs/LARGE_FILE_EDITING.md: a range read can be
/// followed by a precise anchored edit without loading the whole file into
/// model context, and stale or ambiguous edits fail closed. Runs the real
/// `ToolRegistry.execute` path with a minimal runtime so preview, approval
/// (--yolo), application, and revision reporting are all exercised.
final class LargeFileEditFlowTests: XCTestCase, @unchecked Sendable {
  private var directory: URL!
  private var runtime: AgentRuntime?

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("large-file-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    ReadRevisionLedger.shared.clear()
  }

  override func tearDown() {
    ReadRevisionLedger.shared.clear()
    runtime = nil
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  /// `AgentRuntime.init` is async; tests create it lazily on first use.
  private func makeRuntime() async throws -> AgentRuntime {
    if let runtime { return runtime }
    let created = try await AgentRuntime(
      config: AgentConfig(
        arguments: ["--yolo"], homeDirectory: directory, workingDirectory: directory))
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

  private func call(_ name: String, _ arguments: [String: JSONValue], id: String) -> ParsedToolCall {
    let arguments = JSONValue.object(arguments)
    return ParsedToolCall(
      id: id, name: name, arguments: arguments,
      argumentsJSON: (try? arguments.encoded()) ?? "{}")
  }

  private func write(_ name: String, _ content: String) throws {
    try content.write(
      to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private func digest(_ content: String) -> String {
    FileRevision.digest(of: content)
  }

  private func read(_ arguments: [String: JSONValue], id: String) async throws -> String {
    let runtime = try await makeRuntime()
    return try await ToolRegistry.execute(
      call: call("read_file", arguments, id: id), runtime: runtime, context: context(runtime))
  }

  private func edit(_ arguments: [String: JSONValue], id: String) async throws -> String {
    let runtime = try await makeRuntime()
    return try await ToolRegistry.execute(
      call: call("edit_file", arguments, id: id), runtime: runtime, context: context(runtime))
  }

  private func writeTool(_ arguments: [String: JSONValue], id: String) async throws -> String {
    let runtime = try await makeRuntime()
    return try await ToolRegistry.execute(
      call: call("write_file", arguments, id: id), runtime: runtime, context: context(runtime))
  }

  private func contents(_ name: String) throws -> String {
    try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
  }

  func testRangeReadThenAnchoredEditNeverLoadsWholeFileAndReportsNewRevision() async throws {
    // A file whose whole read would exceed the source-result ceiling.
    let body = Array(1...400).map { "line \($0) " + String(repeating: "x", count: 60) }
    var content = body.joined(separator: "\n")
    content += "\nTARGET_LINE marker"
    try write("Big.swift", content)

    // The model requests only the final range; the whole file never enters a
    // single tool result as source (the outline does not embed bodies).
    let read = try await read(
      [
        "path": .string("Big.swift"), "mode": .string("range"),
        "start_line": .integer(395), "end_line": .integer(401),
      ], id: "read-1")
    XCTAssertTrue(read.contains(#"complete="false""#))
    XCTAssertTrue(read.contains("401: TARGET_LINE marker"))
    XCTAssertTrue(read.contains(#"digest="sha256:"#))

    // Anchored edit against the revision the model actually observed.
    let result = try await edit(
      [
        "path": .string("Big.swift"), "target": .string("TARGET_LINE marker"),
        "replacement": .string("TARGET_LINE replaced"),
        "expected_digest": .string(digest(content)),
      ], id: "edit-1")
    XCTAssertTrue(result.contains("Successfully updated Big.swift"), result)
    let newDigest = FileRevision.digest(
      of: content.replacingOccurrences(
        of: "TARGET_LINE marker", with: "TARGET_LINE replaced"))
    XCTAssertTrue(result.contains("New revision: \(newDigest)"), result)

    // The file on disk changed exactly once, at the anchored region.
    let updated = try contents("Big.swift")
    XCTAssertTrue(updated.contains("TARGET_LINE replaced"))
    XCTAssertFalse(updated.contains("TARGET_LINE marker"))
    XCTAssertEqual(updated.components(separatedBy: "line 200").count, 2, "unrelated lines intact")
  }

  func testStaleEditFailsClosedAndGuidesReread() async throws {
    let original = "first\nsecond\nthird"
    try write("Small.swift", original)

    // The model read one revision; the file then changed underneath it.
    try write("Small.swift", "first\nsecond\nTHIRD")

    let result = try await edit(
      [
        "path": .string("Small.swift"), "target": .string("third"),
        "replacement": .string("fourth"), "expected_digest": .string(digest(original)),
      ], id: "edit-stale")
    XCTAssertTrue(result.contains("stale expected_digest"), result)
    XCTAssertTrue(result.lowercased().contains("read"), result)
    XCTAssertEqual(try contents("Small.swift"), "first\nsecond\nTHIRD",
                   "a stale edit must not touch the file")
  }

  func testAmbiguousEditFailsClosedWithoutReplaceAll() async throws {
    let original = "same\nmiddle\nsame"
    try write("Ambiguous.txt", original)

    let result = try await edit(
      [
        "path": .string("Ambiguous.txt"), "target": .string("same"),
        "replacement": .string("other"), "expected_digest": .string(digest(original)),
      ], id: "edit-ambiguous")
    XCTAssertTrue(result.contains("matches multiple locations"), result)
    XCTAssertTrue(result.contains("replace_all"), result)
    XCTAssertEqual(try contents("Ambiguous.txt"), original,
                   "an ambiguous edit must not touch the file")
  }

  func testEditWithoutDigestFailsClosed() async throws {
    let original = "one\ntwo"
    try write("NoDigest.txt", original)

    let result = try await edit(
      [
        "path": .string("NoDigest.txt"), "target": .string("one"),
        "replacement": .string("uno"),
      ], id: "edit-nodigest")
    XCTAssertTrue(result.contains("requires expected_digest"), result)
    XCTAssertEqual(try contents("NoDigest.txt"), original,
                   "an unguarded edit must not touch the file")
  }

  func testWholeFileReplacementAfterRangeReadIsRejectedButSucceedsAfterCompleteRead() async throws
  {
    let original = "body one\nbody two"
    try write("Replaceable.txt", original)

    // A range read does not authorize whole-file replacement, even in yolo
    // mode, even with a matching digest.
    _ = try await read(
      [
        "path": .string("Replaceable.txt"), "start_line": .integer(1),
        "end_line": .integer(1),
      ], id: "read-range")
    let rangeResult = try await writeTool(
      [
        "path": .string("Replaceable.txt"), "content": .string("whole new file"),
        "expected_digest": .string(digest(original)),
      ], id: "write-partial")
    XCTAssertTrue(rangeResult.contains("not read completely"), rangeResult)
    XCTAssertEqual(try contents("Replaceable.txt"), original,
                   "a partial read must not authorize replacement")

    // The complete read of the same revision establishes eligibility.
    _ = try await read(["path": .string("Replaceable.txt")], id: "read-complete")
    let writeResult = try await writeTool(
      [
        "path": .string("Replaceable.txt"), "content": .string("whole new file"),
        "expected_digest": .string(digest(original)),
      ], id: "write-complete")
    XCTAssertTrue(writeResult.contains("Successfully wrote"), writeResult)
    XCTAssertTrue(writeResult.contains("New revision: \(digest("whole new file"))"), writeResult)
    XCTAssertEqual(try contents("Replaceable.txt"), "whole new file")
  }

  func testWholeFileReplacementWithoutDigestIsRejected() async throws {
    let original = "legacy behavior"
    try write("Guarded.txt", original)

    let result = try await writeTool(
      ["path": .string("Guarded.txt"), "content": .string("overwrite")], id: "write-nodigest")
    XCTAssertTrue(result.contains("requires expected_digest"), result)
    XCTAssertEqual(try contents("Guarded.txt"), original)
  }

  func testNewFileCreationRemainsSupportedWithoutDigest() async throws {
    let result = try await writeTool(
      ["path": .string("Fresh.txt"), "content": .string("created")], id: "write-create")
    XCTAssertTrue(result.contains("Successfully wrote"), result)
    XCTAssertEqual(try contents("Fresh.txt"), "created")
    XCTAssertTrue(result.contains("Revision: \(digest("created"))"), result)
  }

  func testEditAfterSuccessfulEditAnchorsOnTheNewRevision() async throws {
    let original = "alpha\nbeta\ngamma"
    try write("Sequence.txt", original)

    let first = try await edit(
      [
        "path": .string("Sequence.txt"), "target": .string("beta"),
        "replacement": .string("beta2"), "expected_digest": .string(digest(original)),
      ], id: "edit-1")
    XCTAssertTrue(first.contains("Successfully updated"), first)

    let secondRevision = original.replacingOccurrences(of: "beta", with: "beta2")
    let second = try await edit(
      [
        "path": .string("Sequence.txt"), "target": .string("gamma"),
        "replacement": .string("gamma2"), "expected_digest": .string(digest(secondRevision)),
      ], id: "edit-2")
    XCTAssertTrue(second.contains("Successfully updated"), second)
    XCTAssertEqual(try contents("Sequence.txt"), "alpha\nbeta2\ngamma2")
  }

  // MARK: Phase 5 apply_patch multi-hunk flow tests

  private func patchTool(_ arguments: [String: JSONValue], id: String) async throws -> String {
    let runtime = try await makeRuntime()
    return try await ToolRegistry.execute(
      call: call("apply_patch", arguments, id: id), runtime: runtime, context: context(runtime))
  }

  func testApplyPatchExecutesAtomicallyAndRefreshesIndexWithWholeFileValidation() async throws {
    let original = """
      func foo() -> Int {
        return 1
      }

      func bar() -> Int {
        return 2
      }
      """
    try write("Multi.swift", original)

    let result = try await patchTool(
      [
        "path": .string("Multi.swift"),
        "expected_digest": .string(digest(original)),
        "hunks": .array([
          .object(["target": .string("return 1"), "replacement": .string("return 10")]),
          .object(["target": .string("return 2"), "replacement": .string("return 20")]),
        ]),
      ], id: "patch-1")

    XCTAssertTrue(result.contains("Successfully patched Multi.swift"), result)
    XCTAssertTrue(result.contains("Validation: UTF-8 verified; outline regenerated"), result)
    let expected = """
      func foo() -> Int {
        return 10
      }

      func bar() -> Int {
        return 20
      }
      """
    XCTAssertTrue(result.contains("New revision: \(digest(expected))"), result)
    XCTAssertEqual(try contents("Multi.swift"), expected)

    // Verify RepositoryIndex was refreshed
    let entry = RepositoryIndex.forWorkspace(directory).entry(for: "Multi.swift")
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.digest, digest(expected))
  }

  func testApplyPatchValidationWarnsOnBracketImbalance() async throws {
    let original = """
      func test() {
        return
      }
      """
    try write("Syntax.swift", original)

    let result = try await patchTool(
      [
        "path": .string("Syntax.swift"),
        "expected_digest": .string(digest(original)),
        "hunks": .array([
          .object(["target": .string("return"), "replacement": .string("return {")]),
        ]),
      ], id: "patch-syntax")

    XCTAssertTrue(result.contains("Successfully patched Syntax.swift"), result)
    XCTAssertTrue(result.contains("Validation Warning: unbalanced braces"), result)
  }

  func testApplyPatchOverlappingHunksFailsClosedBeforeTouchingFile() async throws {
    let original = "let greeting = \"hello world\";"
    try write("Greeting.swift", original)

    let result = try await patchTool(
      [
        "path": .string("Greeting.swift"),
        "expected_digest": .string(digest(original)),
        "hunks": .array([
          .object(["target": .string("hello world"), "replacement": .string("hi")]),
          .object(["target": .string("world"), "replacement": .string("earth")]),
        ]),
      ], id: "patch-overlap")

    XCTAssertTrue(result.contains("patch hunks overlap"), result)
    XCTAssertEqual(try contents("Greeting.swift"), original, "file must not be touched on overlap")
  }
}

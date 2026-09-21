import Foundation
import XCTest

@testable import TurboAgentCore

final class AgentWritePreviewTests: XCTestCase, @unchecked Sendable {
  private func context(_ directory: URL) -> AgentToolContext {
    AgentToolContext(
      directory: directory, systemPrompt: "test", mcp: nil, definitions: [])
  }

  private func call(_ name: String, _ arguments: JSONValue) -> ParsedToolCall {
    ParsedToolCall(id: "test", name: name, arguments: arguments, argumentsJSON: "{}")
  }

  func testNewFilePreviewUsesUnifiedDiffHeaders() {
    let diff = AgentWritePreview.render(path: "Sources/New.swift", before: nil, after: "one\ntwo")
    XCTAssertEqual(
      diff,
      """
      --- /dev/null
      +++ b/Sources/New.swift
      @@ -0,0 +1,2 @@
      +one
      +two
      """)
  }

  func testEditPlanPreviewsAndCarriesExactReplacement() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    try "alpha\nold\nomega".write(to: file, atomically: true, encoding: .utf8)
    let prepared = try await AgentWritePreview.prepare(
      call: call(
        "edit_file",
        .object([
          "path": .string("Example.swift"), "target": .string("old"),
          "replacement": .string("new"),
        ])),
      context: context(directory))
    let plan = try XCTUnwrap(prepared)

    XCTAssertEqual(plan.updatedContent, "alpha\nnew\nomega")
    XCTAssertTrue(plan.diff.contains("-old\n+new"))
    try await plan.verifySourceIsUnchanged(context: context(directory))
  }

  func testApprovedPlanRejectsAFileChangedAfterPreview() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    try "before".write(to: file, atomically: true, encoding: .utf8)
    let prepared = try await AgentWritePreview.prepare(
      call: call(
        "write_file",
        .object(["path": .string("Example.swift"), "content": .string("after")])),
      context: context(directory))
    let plan = try XCTUnwrap(prepared)
    try "changed elsewhere".write(to: file, atomically: true, encoding: .utf8)

    do {
      try await plan.verifySourceIsUnchanged(context: context(directory))
      XCTFail("Expected stale write rejection")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .sourceChanged("Example.swift"))
    }
  }

  func testLargeDiffPreviewIsBoundedAndExplicitlyMarked() {
    let before = (0..<400).map { "old \($0)" }.joined(separator: "\n")
    let after = (0..<400).map { "new \($0)" }.joined(separator: "\n")
    let diff = AgentWritePreview.render(path: "large.txt", before: before, after: after)

    XCTAssertLessThanOrEqual(diff.utf8.count, 24_100)
    XCTAssertTrue(diff.contains("diff preview truncated"))
  }
}

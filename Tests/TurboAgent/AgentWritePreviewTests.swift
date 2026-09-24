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

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func digest(_ content: String) -> String {
    FileRevision.digest(of: content)
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

  // MARK: Phase 2 anchored edit contract

  func testAnchoredEditRequiresRevisionBeforePreview() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    try "alpha\nold\nomega".write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("old"),
            "replacement": .string("new"),
          ])),
        context: context(directory))
      XCTFail("Expected revisionRequired")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .revisionRequired("Example.swift"))
    }
  }

  func testMissingDigestFailsEvenWithReplaceAll() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    try "old\nold".write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("old"),
            "replacement": .string("new"), "replace_all": .bool(true),
          ])),
        context: context(directory))
      XCTFail("Expected revisionRequired")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .revisionRequired("Example.swift"))
    }
  }

  func testStaleDigestFailsBeforeApproval() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    try "first revision".write(to: file, atomically: true, encoding: .utf8)
    let staleDigest = digest("second revision")

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("first"),
            "replacement": .string("second"), "expected_digest": .string(staleDigest),
          ])),
        context: context(directory))
      XCTFail("Expected staleRevision")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .staleRevision("Example.swift"))
    }
  }

  func testUniqueTargetSucceedsWithMatchingDigest() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "alpha\nold\nomega"
    try original.write(to: file, atomically: true, encoding: .utf8)

    let prepared = try await AgentWritePreview.prepare(
      call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("old"),
            "replacement": .string("new"), "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
    let plan = try XCTUnwrap(prepared)

    XCTAssertEqual(plan.updatedContent, "alpha\nnew\nomega")
    XCTAssertTrue(plan.diff.contains("-old\n+new"))
    try await plan.verifySourceIsUnchanged(context: context(directory))
  }

  func testDuplicateTargetsFailAsAmbiguousWithoutReplaceAll() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "same\nmiddle\nsame"
    try original.write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("same"),
            "replacement": .string("other"), "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
      XCTFail("Expected targetAmbiguous")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .targetAmbiguous("Example.swift"))
    }
  }

  func testAmbiguousTargetWithReplaceAllPreviewsEveryChange() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "same\nmiddle\nsame"
    try original.write(to: file, atomically: true, encoding: .utf8)

    let prepared = try await AgentWritePreview.prepare(
      call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("same"),
            "replacement": .string("other"), "expected_digest": .string(digest(original)),
            "replace_all": .bool(true),
          ])),
        context: context(directory))
    let plan = try XCTUnwrap(prepared)
    XCTAssertEqual(plan.updatedContent, "other\nmiddle\nother")
    XCTAssertEqual(
      plan.diff.components(separatedBy: "\n").filter { $0.hasPrefix("-same") }.count, 2)
  }

  func testMissingAndEmptyTargetsFailDistinctly() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "one\ntwo"
    try original.write(to: file, atomically: true, encoding: .utf8)

    // A target that is not in the file at all.
    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("absent"),
            "replacement": .string("x"), "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
      XCTFail("Expected targetNotFound")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .targetNotFound("Example.swift"))
    }

    // An empty target is invalid arguments, never "replace the whole file".
    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string(""),
            "replacement": .string("x"), "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
      XCTFail("Expected invalidArguments")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .invalidArguments("edit_file"))
    }
  }

  func testNoOpReplacementReportsWithoutRequestingAWrite() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "alpha\nold\nomega"
    try original.write(to: file, atomically: true, encoding: .utf8)

    let plan = try await AgentWritePreview.prepare(
      call: call(
        "edit_file",
        .object([
          "path": .string("Example.swift"), "target": .string("old"),
          "replacement": .string("old"), "expected_digest": .string(digest(original)),
        ])),
      context: context(directory))
    XCTAssertNil(plan, "a no-op replacement should not request a meaningless write")
  }

  func testAChangeBetweenReadAndPreviewFailsEvenIfTargetStillMatches() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let readRevision = "alpha\nold\nomega"
    try readRevision.write(to: file, atomically: true, encoding: .utf8)

    // The file changes after the model read it but before the edit proposal.
    let changed = "alpha\nchanged\nomega"
    try changed.write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("omega"),
            "replacement": .string("beta"), "expected_digest": .string(digest(readRevision)),
          ])),
        context: context(directory))
      XCTFail("Expected staleRevision")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .staleRevision("Example.swift"))
    }
  }

  func testSourceChangeAfterPreviewFailsBeforeWrite() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "before"
    try original.write(to: file, atomically: true, encoding: .utf8)
    // Mirror the complete read_file that authorizes whole-file replacement.
    ReadRevisionLedger.shared.record(
      resolvedPath: file.path, digest: digest(original),
      byteCount: original.utf8.count, complete: true)
    let prepared = try await AgentWritePreview.prepare(
      call: call(
          "write_file",
          .object([
            "path": .string("Example.swift"), "content": .string("after"),
            "expected_digest": .string(digest(original)),
          ])),
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

  // MARK: Phase 2 whole-file replacement guard

  func testExistingFileReplacementRequiresDigestAndCompleteReadEvidence() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "complete file body"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let resolvedPath = file.path

    // No digest at all: rejected before any preview.
    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "write_file",
          .object(["path": .string("Example.swift"), "content": .string("replaced")])),
        context: context(directory))
      XCTFail("Expected revisionRequired")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .revisionRequired("Example.swift"))
    }

    // Correct digest but only range-read evidence: still rejected.
    ReadRevisionLedger.shared.clear()
    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "write_file",
          .object([
            "path": .string("Example.swift"), "content": .string("replaced"),
            "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
      XCTFail("Expected replacementRequiresWholeFileRead")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .replacementRequiresWholeFileRead("Example.swift"))
    }

    // A partial read does not authorize replacement even when recorded.
    ReadRevisionLedger.shared.record(
      resolvedPath: resolvedPath, digest: digest(original), byteCount: 5, complete: false)
    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "write_file",
          .object([
            "path": .string("Example.swift"), "content": .string("replaced"),
            "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
      XCTFail("Expected replacementRequiresWholeFileRead")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .replacementRequiresWholeFileRead("Example.swift"))
    }

    // The retained complete read plus a matching digest permit replacement.
    ReadRevisionLedger.shared.record(
      resolvedPath: resolvedPath, digest: digest(original),
      byteCount: original.utf8.count, complete: true)
    let prepared = try await AgentWritePreview.prepare(
      call: call(
          "write_file",
          .object([
            "path": .string("Example.swift"), "content": .string("replaced"),
            "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
    let plan = try XCTUnwrap(prepared)
    XCTAssertEqual(plan.updatedContent, "replaced")
    try await plan.verifySourceIsUnchanged(context: context(directory))
  }

  func testStaleDigestOnWholeFileReplacementFailsBeforeTheLedgerCheck() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "current"
    try original.write(to: file, atomically: true, encoding: .utf8)
    ReadRevisionLedger.shared.clear()

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "write_file",
          .object([
            "path": .string("Example.swift"), "content": .string("next"),
            "expected_digest": .string(digest("older revision")),
          ])),
        context: context(directory))
      XCTFail("Expected staleRevision")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .staleRevision("Example.swift"))
    }
  }

  func testNoOpWholeFileReplacementReturnsNoPlan() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "identical"
    try original.write(to: file, atomically: true, encoding: .utf8)
    ReadRevisionLedger.shared.record(
      resolvedPath: file.path, digest: digest(original),
      byteCount: original.utf8.count, complete: true)

    let plan = try await AgentWritePreview.prepare(
      call: call(
        "write_file",
        .object([
          "path": .string("Example.swift"), "content": .string("identical"),
          "expected_digest": .string(digest(original)),
        ])),
      context: context(directory))
    XCTAssertNil(plan)
  }

  func testNewFileCreationStillPreviewsWithoutDigestOrLedger() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    ReadRevisionLedger.shared.clear()

    let prepared = try await AgentWritePreview.prepare(
      call: call(
          "write_file",
          .object(["path": .string("Created.swift"), "content": .string("brand new")])),
        context: context(directory))
    let plan = try XCTUnwrap(prepared)
    XCTAssertNil(plan.originalContent)
    XCTAssertTrue(plan.diff.contains("--- /dev/null"))
    XCTAssertTrue(plan.diff.contains("+brand new"))
    // A creation target that appeared while the preview waited is refused.
    let target = directory.appendingPathComponent("Created.swift")
    try "raced".write(to: target, atomically: true, encoding: .utf8)
    do {
      try await AgentWritePreview.verifyCreationIsStillNew(target.path, context: context(directory))
      XCTFail("Expected targetCreatedAfterPreview")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .targetCreatedAfterPreview(target.path))
    }
  }

  func testSuccessfulWriteReportsTheNewRevisionDigest() {
    let message = AgentWriteResult.successMessage(
      verb: "updated", path: "Example.swift", previousContent: "old body",
      updatedContent: "new body")
    XCTAssertTrue(message.contains("Successfully updated Example.swift"))
    XCTAssertTrue(message.contains("New revision: \(digest("new body"))"))
    XCTAssertTrue(message.contains("Previous revision: \(digest("old body"))"))
  }

  func testLargeDiffPreviewIsBoundedAndExplicitlyMarked() {
    let before = (0..<400).map { "old \($0)" }.joined(separator: "\n")
    let after = (0..<400).map { "new \($0)" }.joined(separator: "\n")
    let diff = AgentWritePreview.render(path: "large.txt", before: before, after: after)

    XCTAssertLessThanOrEqual(diff.utf8.count, 24_100)
    XCTAssertTrue(diff.contains("diff preview truncated"))
  }

  // MARK: Overlapping occurrence handling

  func testOverlappingOccurrenceIsTreatedAsASingleUniqueTarget() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "aaa"
    try original.write(to: file, atomically: true, encoding: .utf8)

    // "aa" occurs once in "aaa" under non-overlapping counting, so the edit
    // is unambiguous and replaces only that first match.
    let prepared = try await AgentWritePreview.prepare(
      call: call(
          "edit_file",
          .object([
            "path": .string("Example.swift"), "target": .string("aa"),
            "replacement": .string("bb"), "expected_digest": .string(digest(original)),
          ])),
        context: context(directory))
    let plan = try XCTUnwrap(prepared)
    XCTAssertEqual(plan.updatedContent, "bba")
  }

  // MARK: Phase 5 apply_patch multi-hunk tests

  func testApplyPatchRequiresRevisionBeforePreview() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    try "one\ntwo\nthree".write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "apply_patch",
          .object([
            "path": .string("Example.swift"),
            "hunks": .array([
              .object(["target": .string("one"), "replacement": .string("1")]),
            ]),
          ])),
        context: context(directory))
      XCTFail("Expected revisionRequired")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .revisionRequired("Example.swift"))
    }
  }

  func testApplyPatchStaleDigestFailsBeforePreview() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    try "one\ntwo\nthree".write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "apply_patch",
          .object([
            "path": .string("Example.swift"),
            "expected_digest": .string(digest("stale content")),
            "hunks": .array([
              .object(["target": .string("one"), "replacement": .string("1")]),
            ]),
          ])),
        context: context(directory))
      XCTFail("Expected staleRevision")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .staleRevision("Example.swift"))
    }
  }

  func testApplyPatchMissingTargetFailsClosed() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "one\ntwo\nthree"
    try original.write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "apply_patch",
          .object([
            "path": .string("Example.swift"),
            "expected_digest": .string(digest(original)),
            "hunks": .array([
              .object(["target": .string("missing"), "replacement": .string("found")]),
            ]),
          ])),
        context: context(directory))
      XCTFail("Expected targetNotFound")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .targetNotFound("Example.swift"))
    }
  }

  func testApplyPatchAmbiguousTargetFailsClosed() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "same\nmiddle\nsame"
    try original.write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "apply_patch",
          .object([
            "path": .string("Example.swift"),
            "expected_digest": .string(digest(original)),
            "hunks": .array([
              .object(["target": .string("same"), "replacement": .string("other")]),
            ]),
          ])),
        context: context(directory))
      XCTFail("Expected targetAmbiguous")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .targetAmbiguous("Example.swift"))
    }
  }

  func testApplyPatchOverlappingHunksFailsClosed() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "hello brave new world"
    try original.write(to: file, atomically: true, encoding: .utf8)

    do {
      _ = try await AgentWritePreview.prepare(
        call: call(
          "apply_patch",
          .object([
            "path": .string("Example.swift"),
            "expected_digest": .string(digest(original)),
            "hunks": .array([
              .object(["target": .string("brave new"), "replacement": .string("bold")]),
              .object(["target": .string("new world"), "replacement": .string("universe")]),
            ]),
          ])),
        context: context(directory))
      XCTFail("Expected overlappingHunks")
    } catch let error as AgentWritePreview.Error {
      XCTAssertEqual(error, .overlappingHunks("Example.swift"))
    }
  }

  func testApplyPatchMultipleNonAdjacentHunksSucceeds() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = """
      func alpha() -> Int {
        return 1
      }

      func beta() -> String {
        return "two"
      }

      func gamma() -> Bool {
        return false
      }
      """
    try original.write(to: file, atomically: true, encoding: .utf8)

    let prepared = try await AgentWritePreview.prepare(
      call: call(
        "apply_patch",
        .object([
          "path": .string("Example.swift"),
          "expected_digest": .string(digest(original)),
          "hunks": .array([
            // Provide hunks in arbitrary order to verify deterministic application
            .object(["target": .string("return false"), "replacement": .string("return true")]),
            .object(["target": .string("return 1"), "replacement": .string("return 100")]),
          ]),
        ])),
      context: context(directory))
    let plan = try XCTUnwrap(prepared)

    let expectedUpdated = """
      func alpha() -> Int {
        return 100
      }

      func beta() -> String {
        return "two"
      }

      func gamma() -> Bool {
        return true
      }
      """
    XCTAssertEqual(plan.updatedContent, expectedUpdated)
    XCTAssertTrue(plan.diff.contains("return 100"))
    XCTAssertTrue(plan.diff.contains("return true"))
    try await plan.verifySourceIsUnchanged(context: context(directory))
  }

  func testApplyPatchNoOpReturnsNilPlan() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Example.swift")
    let original = "one\ntwo\nthree"
    try original.write(to: file, atomically: true, encoding: .utf8)

    let plan = try await AgentWritePreview.prepare(
      call: call(
        "apply_patch",
        .object([
          "path": .string("Example.swift"),
          "expected_digest": .string(digest(original)),
          "hunks": .array([
            .object(["target": .string("two"), "replacement": .string("two")]),
          ]),
        ])),
      context: context(directory))
    XCTAssertNil(plan, "a no-op patch should return nil")
  }
}

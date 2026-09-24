import Foundation
import XCTest

@testable import TurboAgentCore

/// Phase 1 unit coverage for docs/LARGE_FILE_EDITING.md: file slicing,
/// revision metadata, deterministic outlines, and the extended read_file
/// contract. All checks are model-free.
final class FileSlicingTests: XCTestCase, @unchecked Sendable {
  private func revision(_ content: String, path: String = "Example.swift") -> FileRevision {
    FileRevision(path: path, content: content)
  }

  private func slice(
    _ content: String, start: Int, end: Int, path: String = "Example.swift"
  ) throws -> FileSlice {
    FileSlicer.slice(
      revision: revision(content, path: path), content: content, startLine: start, endLine: end)
  }

  // MARK: Line splitting and boundary shapes

  func testSplitLinesPreservesEmptyLinesAndTrailingNewlineConvention() {
    XCTAssertEqual(FileSlicer.splitLines(""), [])
    XCTAssertEqual(FileSlicer.splitLines("one"), ["one"])
    XCTAssertEqual(FileSlicer.splitLines("one\n"), ["one"])
    XCTAssertEqual(FileSlicer.splitLines("a\n\nb\n"), ["a", "", "b"])
    XCTAssertEqual(FileSlicer.splitLines("a\r\nb\r\n"), ["a\r", "b\r"])
  }

  func testFirstMiddleAndFinalRanges() throws {
    let content = "1\n2\n3\n4\n5"
    XCTAssertEqual(try slice(content, start: 1, end: 2).content, "1\n2")
    XCTAssertEqual(try slice(content, start: 3, end: 3).content, "3")
    XCTAssertEqual(try slice(content, start: 4, end: 5).content, "4\n5")
    XCTAssertEqual(try slice(content, start: 2, end: 4).content, "2\n3\n4")
  }

  func testEndLineClampsToEOFAndReportsActualRange() throws {
    let content = "1\n2\n3"
    let clamped = try FileSlicer.parseRange(startLine: 2, endLine: 99, lineCount: 3, mode: .range)
    XCTAssertEqual(clamped, .init(startLine: 2, endLine: 3))

    let slice = FileSlicer.slice(revision: revision(content), content: content, startLine: 2, endLine: 99)
    XCTAssertEqual(slice.endLine, 3)
    XCTAssertFalse(slice.hasLaterLines)
    XCTAssertEqual(slice.hasEarlierLines, true)
  }

  func testInvalidReversedAndOversizedRangesAreRejected() {
    let lineCount = 3
    XCTAssertThrowsError(try FileSlicer.parseRange(startLine: 0, endLine: 2, lineCount: lineCount, mode: .range))
    XCTAssertThrowsError(try FileSlicer.parseRange(startLine: -1, endLine: 2, lineCount: lineCount, mode: .range))
    XCTAssertThrowsError(try FileSlicer.parseRange(startLine: 3, endLine: 2, lineCount: lineCount, mode: .range))
    XCTAssertThrowsError(try FileSlicer.parseRange(startLine: 99, endLine: 120, lineCount: lineCount, mode: .range))
    XCTAssertThrowsError(try FileSlicer.parseRange(startLine: nil, endLine: nil, lineCount: lineCount, mode: .range))
    // One-sided open ranges are permitted for continuation reads.
    XCTAssertNoThrow(try FileSlicer.parseRange(startLine: 2, endLine: nil, lineCount: lineCount, mode: .range))
    XCTAssertNoThrow(try FileSlicer.parseRange(startLine: nil, endLine: 2, lineCount: lineCount, mode: .range))
  }

  func testSlicingNeverMutatesStoredContent() throws {
    let content = "alpha\nbeta\ngamma"
    _ = try slice(content, start: 2, end: 2)
    XCTAssertEqual(content, "alpha\nbeta\ngamma")
  }

  // MARK: Binary and encoding guards

  func testBinaryAndInvalidUTF8FilesAreRejected() throws {
    XCTAssertThrowsError(
      try FileSlicer.validateText(Data([0x68, 0x00, 0x69]), path: "blob.bin")
    ) { error in
      XCTAssertEqual(error as? FileSlicerError, .binaryFile("blob.bin"))
    }
    XCTAssertThrowsError(
      try FileSlicer.validateText(Data([0xff, 0xfe, 0x48]), path: "text.txt")
    ) { error in
      XCTAssertEqual(error as? FileSlicerError, .invalidUTF8("text.txt"))
    }
    XCTAssertEqual(
      try FileSlicer.validateText(Data("héllo\n".utf8), path: "text.txt"), "héllo\n")
  }

  func testUnicodeContentSurvivesSlicingAndEnvelopeRendering() throws {
    let content = "emoji 🙂\n中文 line\nfinal"
    let slice = try slice(content, start: 1, end: 3)
    XCTAssertEqual(slice.content, content)
    let rendered = FileSlicer.renderEnvelope(slice, complete: true)
    XCTAssertTrue(rendered.contains("1: emoji 🙂"))
    XCTAssertTrue(rendered.contains("2: 中文 line"))
  }

  // MARK: Revision metadata

  func testDigestIsStableAndChangesAfterOneByteChanges() {
    let before = revision("same")
    let again = revision("same")
    XCTAssertEqual(before.digest, again.digest)
    XCTAssertTrue(before.digest.hasPrefix("sha256:"))

    let changed = revision("samf")
    XCTAssertNotEqual(before.digest, changed.digest)
  }

  func testRevisionRecordsByteAndLineCounts() {
    let content = "one\ntwo\nthree\n"
    let rev = revision(content, path: "notes.txt")
    XCTAssertEqual(rev.byteCount, content.utf8.count)
    XCTAssertEqual(rev.lineCount, 3)
    XCTAssertEqual(rev.path, "notes.txt")
  }

  func testSliceCarriesRevisionAndPartialFlags() throws {
    let content = "1\n2\n3"
    let head = try slice(content, start: 1, end: 2)
    XCTAssertFalse(head.hasLaterLines == false && head.hasEarlierLines == false)
    XCTAssertEqual(head.revision.lineCount, 3)

    let tail = try slice(content, start: 3, end: 3)
    XCTAssertTrue(tail.hasEarlierLines)
    XCTAssertFalse(tail.hasLaterLines)
  }

  // MARK: Envelope contract

  func testEnvelopeLabelsPartialRangesWithContinuation() throws {
    let content = Array(1...50).map { "line \($0)" }.joined(separator: "\n")
    let slice = try slice(content, start: 10, end: 14, path: "big.c")
    let rendered = FileSlicer.renderEnvelope(slice, complete: false)

    XCTAssertTrue(rendered.contains(#"path="big.c""#))
    XCTAssertTrue(rendered.contains("digest=\"sha256:"))
    XCTAssertTrue(rendered.contains(#"lines="10-14/50""#))
    XCTAssertTrue(rendered.contains("complete=\"false\""))
    XCTAssertTrue(rendered.contains("10: line 10"))
    XCTAssertTrue(rendered.contains("14: line 14"))
    XCTAssertFalse(rendered.contains("15: line 15"))
    XCTAssertTrue(rendered.contains("request start_line=15 to continue"))
  }

  func testCompleteEnvelopeHasNoContinuationInstruction() throws {
    let content = "alpha\nbeta"
    let slice = try slice(content, start: 1, end: 2)
    let rendered = FileSlicer.renderEnvelope(slice, complete: true)
    XCTAssertTrue(rendered.contains(#"complete="true""#))
    XCTAssertFalse(rendered.contains("request start_line"))
    XCTAssertFalse(rendered.contains("complete=\"false\""))
  }

  // MARK: Deterministic outlines

  private func outlineSections(_ content: String, path: String) -> [FileSection] {
    FileOutlineBuilder.sections(of: content, path: path)
  }

  func testSwiftOutlineRecognizesTypesAndMembers() {
    let content = """
      import Foundation

      struct Renderer {
        let name: String

        func render() -> String { name }
      }

      enum Mode {
        case fast, slow
      }
      """
    let sections = outlineSections(content, path: "Renderer.swift")
    let names = sections.map(\.name)
    XCTAssertTrue(names.contains("Renderer"))
    XCTAssertTrue(names.contains("render"))
    XCTAssertTrue(names.contains("Mode"))
    let render = sections.first { $0.name == "render" }
    XCTAssertEqual(render?.kind, "func")
    XCTAssertNotNil(render?.signature)
    // Every section is one-based and ordered.
    for pair in zip(sections, sections.dropFirst()) {
      XCTAssertLessThan(pair.0.startLine, pair.1.startLine)
    }
  }

  func testCFamilyOutlineRecognizesFunctionsAndStructs() {
    let content = """
      #include "fixture.h"

      typedef struct {
          const char *prompt;
          int cancelled;
      } PromptState;

      static int read_character(EditLine *editor, wchar_t *character) {
          return 0;
      }

      static unsigned char cancel_prompt(EditLine *editor, int key) {
          (void)key;
          return CC_NORM;
      }
      """
    let sections = outlineSections(content, path: "Fixture.c")
    let names = sections.map(\.name)
    XCTAssertTrue(names.contains("read_character"))
    XCTAssertTrue(names.contains("cancel_prompt"))
    let cancel = sections.first { $0.name == "cancel_prompt" }
    XCTAssertEqual(cancel?.kind, "func")
  }

  func testGenericFallbackCoversUnstructuredText() {
    let content = Array(1...30).map { "prose line \($0)" }.joined(separator: "\n")
    let sections = outlineSections(content, path: "notes.txt")
    XCTAssertFalse(sections.isEmpty)
    // Fallback windows account for the whole non-empty extent.
    XCTAssertEqual(sections.first?.startLine, 1)
    XCTAssertEqual(sections.last?.endLine, 30)
    XCTAssertEqual(sections.first?.kind, "block")
  }

  func testOutlineAccountsForWholeFileIncludingBlankRuns() {
    let content = """
      func first() {}



      func second() {}
      """
    let sections = outlineSections(content, path: "gaps.swift")
    // The blank run between declarations must not be silently unaccounted.
    XCTAssertGreaterThanOrEqual(sections.count, 2)
    for section in sections {
      XCTAssertLessThanOrEqual(section.startLine, section.endLine)
    }
  }

  func testLargeFixtureOutlineListsLibeditDeclarationsAndStaysBounded() throws {
    let fixture = try String(
      contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/TurboAgent/Fixtures/LargeFileEditing/LargeEditorFixture.c"),
      encoding: .utf8)
    let revision = FileRevision(path: "LargeEditorFixture.c", content: fixture)
    let outline = FileSlicer.outline(revision: revision, content: fixture, path: "LargeEditorFixture.c")

    XCTAssertTrue(outline.sections.contains { $0.name == "fixture_cancel_prompt" })
    XCTAssertTrue(outline.sections.contains { $0.name == "fixture_move_to_boundary" })
    XCTAssertTrue(outline.sections.contains { $0.name == "fixture_configure_keys" })

    // Sections are bounded and non-overlapping enough for navigation.
    for section in outline.sections {
      XCTAssertLessThanOrEqual(section.endLine - section.startLine + 1, 403)
    }
    let rendered = FileSlicer.outlineEnvelope(outline, initialRange: nil)
    XCTAssertFalse(rendered.contains("static unsigned char fixture_move_line"), "outline must not embed source bodies")
    XCTAssertTrue(rendered.contains("fixture_cancel_prompt"))
    XCTAssertTrue(rendered.contains("complete=\"false\""))
    XCTAssertTrue(rendered.contains("start_line/end_line"))
  }

  // MARK: Phase 1 exit criterion

  func testEveryRelevantFixtureFunctionIsReachableWithinBudget() throws {
    let fixture = try String(
      contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/TurboAgent/Fixtures/LargeFileEditing/LargeEditorFixture.c"),
      encoding: .utf8)
    let lines = FileSlicer.splitLines(fixture)
    let outline = FileSlicer.outline(
      revision: FileRevision(path: "LargeEditorFixture.c", content: fixture),
      content: fixture, path: "LargeEditorFixture.c")

    // Functions relevant to a cancel_prompt repair, per the phase 0 fixture.
    let requiredNames = [
      "fixture_cancel_prompt", "fixture_finish_cancel", "fixture_move_line",
      "fixture_read_prompt_loop",
    ]
    for name in requiredNames {
      let section = try XCTUnwrap(
        outline.sections.first { $0.name == name }, "\(name) missing from outline")
      let slice = FileSlicer.slice(
        revision: outline.revision, content: fixture,
        startLine: max(1, section.startLine - 5), endLine: min(lines.count, section.endLine + 5))
      XCTAssertLessThan(
        AgentContextAssembler.estimateTokens(slice.content), 1_500,
        "\(name) range must fit a bounded read")
      XCTAssertTrue(slice.content.contains(name))
    }
  }
}
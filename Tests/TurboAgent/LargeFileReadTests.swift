import Foundation
import XCTest

@testable import TurboAgentCore

/// Phase 1 contract tests for the extended read_file tool:
/// mode/auto/range/outline behavior, envelope labeling, and range rejection.
/// Exercises the same `LargeFileRead.render` core the tool path uses,
/// model-free, through real temporary files.
final class LargeFileReadTests: XCTestCase, @unchecked Sendable {
  private var directory: URL!
  private var files: [String] = []

  override func tearDown() {
    for path in FileManager.default.temporaryDirectory
      .appendingPathComponent("large-file-read-\(ObjectIdentifier(self).hashValue)", isDirectory: true)
      .appendingPathComponent("")
      .path
      .split(separator: "\0")
    {
      _ = path
    }
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("large-file-read-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func write(_ name: String, _ content: String) throws -> String {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  /// Exceeds FileSlicer.maximumSliceTokens (3,000 tokens) so auto mode must
  /// fall back to an outline instead of returning the whole file.
  private var large: String {
    Array(1...400).map { "line \($0) " + String(repeating: "x", count: 60) }
      .joined(separator: "\n")
  }

  private func arguments(_ values: [String: JSONValue]) -> JSONValue {
    .object(values)
  }

  private func arguments(_ pairs: [(String, JSONValue)]) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: pairs))
  }

  // MARK: Argument decoding

  func testPlainPathArgumentDecodesAsAutoMode() {
    XCTAssertNotNil(LargeFileRead.Request(arguments: arguments([("path", .string("x"))])))
    XCTAssertNil(LargeFileRead.Request(arguments: .string("path")))
    XCTAssertNotNil(
      LargeFileRead.Request(
        arguments: arguments([("path", .string("x")), ("mode", .string("range"))])))
    XCTAssertNotNil(
      LargeFileRead.Request(arguments: arguments([("start_line", .integer(2))])))
    XCTAssertEqual(
      LargeFileRead.Request(arguments: arguments([("path", .string("x"))]))?.mode, .auto)
  }

  func testUnknownModeDegradesToAutoRatherThanBypassingRevisionGuards() throws {
    // An unrecognized mode never bypasses the range/outline contract: it
    // degrades to auto so every result still carries revision metadata.
    let request = LargeFileRead.Request(
      arguments: arguments([("path", .string("x")), ("mode", .string("turbo"))]))
    XCTAssertEqual(request?.mode, .auto)
  }

  // MARK: auto mode

  func testAutoReturnsCompleteFileWithinCeiling() throws {
    let small = "alpha\nbeta"
    let rendered = try LargeFileRead.render(
      request: LargeFileRead.Request(arguments: .object([:])), content: small, path: "small.swift")
    XCTAssertTrue(rendered.contains("complete=\"true\""))
    XCTAssertTrue(rendered.contains("1: alpha"))
    XCTAssertTrue(rendered.contains("2: beta"))
    XCTAssertTrue(rendered.contains("digest=\"sha256:"))
  }

  func testAutoFallsBackToOutlineWithExcerptForLargeFiles() throws {
    let rendered = try LargeFileRead.render(
      request: LargeFileRead.Request(arguments: .object([:])), content: large, path: "big.txt")
    // Outline envelope plus a bounded initial excerpt, both labeled partial.
    XCTAssertTrue(rendered.contains("outline=\"true\""))
    XCTAssertTrue(rendered.contains("complete=\"false\""))
    XCTAssertTrue(rendered.contains("start_line/end_line"))
    XCTAssertFalse(rendered.contains("complete=\"true\""))
    // The excerpt is bounded, not the whole file.
    let tokens = AgentContextAssembler.estimateTokens(rendered)
    XCTAssertLessThan(tokens, FileSlicer.maximumSliceTokens + 200)
  }

  // MARK: Range reads

  func testRangeRequestReturnsOnlyRequestedSlice() throws {
    let request = LargeFileRead.Request(
      arguments: arguments([("start_line", .integer(10)), ("end_line", .integer(12))]))
    let rendered = try LargeFileRead.render(request: request, content: large, path: "big.txt")
    XCTAssertTrue(rendered.contains(#"lines="10-12/400""#))
    XCTAssertTrue(rendered.contains("10: line 10 x"))
    XCTAssertTrue(rendered.contains("complete=\"false\""))
    // Slice content only: line 1 and line 400 must not appear.
    XCTAssertFalse(rendered.contains("\n1: line 1"))
    XCTAssertFalse(rendered.contains("400: line 400"))
    XCTAssertFalse(rendered.contains("400: line 400"))
  }

  func testRangeRequestClampsEndToEOF() throws {
    let rendered = try LargeFileRead.render(
      request: LargeFileRead.Request(
        arguments: arguments([
          ("path", .string("big.txt")), ("start_line", .integer(398)),
          ("end_line", .integer(4000)),
        ])),
      content: large, path: "big.txt")
    XCTAssertTrue(rendered.contains(#"lines="398-400/400""#))
    XCTAssertTrue(rendered.contains("400: line 400"))
  }

  func testInvalidRangeFailsWithActionableError() throws {
    let request = LargeFileRead.Request(
      arguments: arguments([("start_line", .integer(5)), ("end_line", .integer(2))]))
    XCTAssertThrowsError(
      try LargeFileRead.render(request: request, content: "a\nb", path: "a.txt")
    ) { error in
      guard case FileSlicerError.invalidRange = error as! FileSlicerError else {
        return XCTFail("unexpected error \(error)")
      }
    }
  }

  func testRangeModeWithoutRangeFailsRatherThanReturningWholeFile() throws {
    XCTAssertThrowsError(
      try LargeFileRead.render(
        request: LargeFileRead.Request(
          arguments: arguments([("mode", .string("range"))])),
        content: large, path: "big.txt")
    )
  }

  // MARK: Outline mode

  func testOutlineModeReturnsNoSourceBodies() throws {
    let rendered = try LargeFileRead.render(
      request: LargeFileRead.Request(
        arguments: arguments([("mode", .string("outline"))])),
      content: large, path: "big.txt")
    XCTAssertTrue(rendered.contains("outline=\"true\""))
    XCTAssertFalse(rendered.contains("line 200"))
    XCTAssertFalse(rendered.contains("complete=\"true\""))
  }

  // MARK: Binary rejection through the tool contract

  func testToolContractRejectsBinaryFileWithGuidance() throws {
    let binary = Data([0x48, 0x00, 0x49])
    XCTAssertThrowsError(
      try FileSlicer.validateText(binary, path: "blob.bin")
    ) { error in
      XCTAssertTrue(
        (error as? FileSlicerError)?.description.contains("binary") == true)
    }
  }
}
import Foundation

/// One-based, inclusive line-range representation used in the model-facing
/// contract. Zero-based half-open ranges are internal only.
struct FileSlice: Sendable, Equatable {
  let revision: FileRevision
  let startLine: Int
  let endLine: Int
  let content: String
  let hasEarlierLines: Bool
  let hasLaterLines: Bool
}

enum FileSlicerError: Error, Equatable, CustomStringConvertible {
  case invalidUTF8(String)
  case binaryFile(String)
  case invalidRange(requested: String, lineCount: Int)

  var description: String {
    switch self {
    case .invalidUTF8(let path):
      return
        "cannot read \(path): the file is not valid UTF-8. Large-file range reads require text."
    case .binaryFile(let path):
      return
        "cannot read \(path): the file contains NUL bytes or is binary. Use shell tools for binary data."
    case .invalidRange(let requested, let lineCount):
      return
        "invalid line range \(requested) for a file with \(lineCount) lines. Use start_line <= end_line, both >= 1."
    }
  }
}

/// Line-preserving, deterministic slicing over an in-memory UTF-8 string.
enum FileSlicer {
  /// Conservative default ceiling for a single source read result, tuned for
  /// an 8K backend whose usable prompt budget is 6,656 tokens. The ceiling
  /// becomes dynamic once runtime headroom is exposed to tools.
  static let maximumSliceTokens = 3_000
  /// Files larger than this are never rendered whole in `auto` mode.
  static let outlineThresholdTokens = 2_500
  /// Detection windows for binary content.
  private static let binaryProbeBytes = 8_000

  /// Splits content into lines, preserving empty lines and the CRLF
  /// convention (the carriage return stays on its line). A trailing newline
  /// terminates the last line instead of opening a new one:
  /// `splitLines("a\n")` is ["a"], `splitLines("a\n\n")` is ["a", ""].
  /// Splitting runs on the LF scalar because "\r\n" is a single Swift
  /// `Character` grapheme and would otherwise never match a newline test.
  static func splitLines(_ content: String) -> [String] {
    guard !content.isEmpty else { return [] }
    var lines = content.components(separatedBy: "\n")
    if lines.count > 1 && lines.last == "" {
      // One trailing terminator closes the last line; it opens no new one.
      lines.removeLast()
    }
    return lines
  }

  enum Mode: String { case auto, range, outline }

  struct ParsedRange: Equatable {
    let startLine: Int
    let endLine: Int
  }

  /// Validates a model-supplied one-based inclusive range against the line
  /// count. Rejects zero, negative, reversed, and unreasonably wide ranges;
  /// clamps only the end of a valid range to EOF and reports the actual range.
  static func parseRange(
    startLine: Int?, endLine: Int?, lineCount: Int, mode: Mode
  ) throws -> ParsedRange? {
    switch mode {
    case .outline:
      return nil
    case .auto, .range:
      break
    }
    switch (startLine, endLine) {
    case (nil, nil):
      if mode == .range {
        throw FileSlicerError.invalidRange(requested: "missing", lineCount: lineCount)
      }
      return nil
    case (nil, .some), (.some, nil):
      // One bound implies the other: open-ended from a line to EOF or from
      // the first line, which keeps continuation reads unambiguous.
      let start = startLine ?? 1
      let end = endLine ?? lineCount
      return try validated(start: start, end: end, lineCount: lineCount)
    case (.some(let start), .some(let end)):
      return try validated(start: start, end: end, lineCount: lineCount)
    }
  }

  private static func validated(start: Int, end: Int, lineCount: Int) throws -> ParsedRange {
    guard start >= 1, end >= start else {
      throw FileSlicerError.invalidRange(requested: "\(start)-\(end)", lineCount: lineCount)
    }
    guard start <= max(lineCount, 1) else {
      throw FileSlicerError.invalidRange(
        requested: "\(start)-\(end)", lineCount: lineCount)
    }
    return ParsedRange(startLine: start, endLine: min(end, lineCount))
  }

  static func slice(
    revision: FileRevision, content: String, startLine: Int, endLine: Int
  ) -> FileSlice {
    let lines = splitLines(content)
    let lower = max(0, startLine - 1)
    let upper = min(endLine, lines.count)
    let selected = lines[lower..<max(lower, upper)].joined(separator: "\n")
    return FileSlice(
      revision: revision, startLine: startLine, endLine: min(endLine, max(lines.count, 1)),
      content: selected, hasEarlierLines: startLine > 1, hasLaterLines: min(endLine, lines.count) < lines.count
    )
  }

  /// Rejects binary and invalid-UTF-8 content before rendering a slice.
  static func validateText(_ data: Data, path: String) throws -> String {
    if data.contains(0) {
      throw FileSlicerError.binaryFile(path)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw FileSlicerError.invalidUTF8(path)
    }
    return text
  }

  /// Removes a limited trailing partial line so a probe window never shows a
  /// truncated UTF-8 multibyte sequence as if it were complete text.
  static func probeText(_ data: Data, limit: Int = binaryProbeBytes) -> Bool {
    let window = data.prefix(limit)
    return !window.contains(0)
  }

  /// Renders one slice in the stable envelope contract, including explicit
  /// partial labeling and continuation information.
  static func renderEnvelope(_ slice: FileSlice, complete: Bool) -> String {
    let path = slice.revision.path
    var header =
      "[file path=\"\(path)\" digest=\"\(slice.revision.digest)\" "
    header += complete
      ? "lines=\"1-\(slice.revision.lineCount)/\(slice.revision.lineCount)\" complete=\"true\"]"
      : "lines=\"\(slice.startLine)-\(slice.endLine)/\(slice.revision.lineCount)\" complete=\"false\"]"
    var rendered = [header]
    let lines = splitLines(slice.content)
    for (offset, line) in lines.enumerated() {
      rendered.append("\(slice.startLine + offset): \(line)")
    }
    rendered.append(
      complete
        ? "[end file]"
        : "[end partial file; request start_line=\(slice.endLine + 1) to continue]")
    return rendered.joined(separator: "\n")
  }

  static func outlineEnvelope(_ outline: FileOutline, initialRange: ClosedRange<Int>?) -> String {
    var rendered = [
      "[file path=\"\(outline.revision.path)\" digest=\"\(outline.revision.digest)\" "
        + "lines=\"1-\(outline.revision.lineCount)/\(outline.revision.lineCount)\" "
        + "bytes=\"\(outline.revision.byteCount)\" complete=\"false\" outline=\"true\"]",
    ]
    for section in outline.sections {
      rendered.append(
        "  \(section.startLine)-\(section.endLine)  \(section.kind) \(section.name)")
    }
    if let initialRange {
      rendered.append("")
      rendered.append("## initial excerpt lines \(initialRange.lowerBound)-\(initialRange.upperBound)")
    }
    rendered.append(
      "[end outline; source not included. Request read_file with start_line/end_line for the section you need.]"
    )
    return rendered.joined(separator: "\n")
  }

  /// One-file deterministic outline: recognized declarations first, with a
  /// non-empty-line window fallback for unstructured text.
  static func outline(revision: FileRevision, content: String, path: String) -> FileOutline {
    let sections = FileOutlineBuilder.sections(of: content, path: path)
    return FileOutline(revision: revision, sections: sections)
  }
}
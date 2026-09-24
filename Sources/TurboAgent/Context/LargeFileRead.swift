import Foundation

/// Phase 1 read_file rendering: mode/range selection over one already-read
/// file. Deterministic and runtime-free so it can be exercised model-free.
///
/// `auto` returns the whole file only when it fits within the source-result
/// ceiling; otherwise it returns a deterministic outline plus a small initial
/// excerpt. `range` requires or derives start_line/end_line and returns only
/// that bounded slice. `outline` returns the section map without source
/// bodies. No result is ever returned unlabeled as partial when it is partial.
enum LargeFileRead {
  struct Request: Equatable {
    var mode: FileSlicer.Mode
    var startLine: Int?
    var endLine: Int?

    /// Decodes the large-file portion of a read_file argument object.
    /// Returns nil only when arguments are not an object; a plain {"path"}
    /// request is auto mode, which is also the doc contract default.
    init?(arguments: JSONValue) {
      guard case .object(let arguments) = arguments else { return nil }
      func int(_ key: String) -> Int? {
        switch arguments[key] {
        case .integer(let value): return Int(value)
        case .number(let value): return Int(value)
        default: return nil
        }
      }
      // An unrecognized mode string keeps the request well-defined by
      // degrading to auto rather than bypassing revision labeling.
      self.mode =
        arguments["mode"]?.string.flatMap { FileSlicer.Mode(rawValue: $0) } ?? .auto
      self.startLine = int("start_line")
      self.endLine = int("end_line")
    }
  }

  /// Renders a model-facing result for one complete in-memory file read, or
  /// nil when the request carries no large-file semantics and the legacy
  /// whole-file path should handle it. `recordRead` runs after rendering with
  /// `complete` true only for an unlabeled whole-file result; phase 2's
  /// whole-file replacement eligibility comes from that fact, never from a
  /// model claim.
  static func render(
    request: Request?, content: String, path: String,
    recordRead: ((Bool) -> Void)? = nil
  ) throws -> String {
    guard let request else { return "" }
    let revision = FileRevision(path: path, content: content)
    let lines = FileSlicer.splitLines(content)

    switch request.mode {
    case .outline:
      let outline = FileSlicer.outline(revision: revision, content: content, path: path)
      recordRead?(false)
      return FileSlicer.outlineEnvelope(outline, initialRange: nil)

    case .auto, .range:
      let requested = try FileSlicer.parseRange(
        startLine: request.startLine, endLine: request.endLine,
        lineCount: lines.count, mode: request.mode)
      guard let requested else {
        // No explicit range in auto mode: return the whole file only when it
        // fits within the source-result ceiling.
        if AgentContextAssembler.estimateTokens(content) <= FileSlicer.maximumSliceTokens {
          let slice = FileSlicer.slice(
            revision: revision, content: content, startLine: 1, endLine: lines.count)
          recordRead?(true)
          return FileSlicer.renderEnvelope(slice, complete: true)
        }
        // Too large to return whole: outline plus a small initial excerpt
        // with explicit instructions to request a range.
        let outline = FileSlicer.outline(revision: revision, content: content, path: path)
        let initial = initialRange(for: outline)
        var rendered = FileSlicer.outlineEnvelope(outline, initialRange: initial)
        if let initial {
          let excerpt = FileSlicer.slice(
            revision: revision, content: content,
            startLine: initial.lowerBound, endLine: initial.upperBound)
          rendered += "\n\n" + FileSlicer.renderEnvelope(excerpt, complete: false)
        }
        recordRead?(false)
        return rendered
      }
      let slice = FileSlicer.slice(
        revision: revision, content: content, startLine: requested.startLine,
        endLine: requested.endLine)
      let complete = !slice.hasEarlierLines && !slice.hasLaterLines
      recordRead?(complete)
      return FileSlicer.renderEnvelope(slice, complete: complete)
    }
  }

  /// A small excerpt shown beneath an outline so the model can start without
  /// a second round when the first section is what it needs.
  static func initialRange(for outline: FileOutline) -> ClosedRange<Int>? {
    guard let first = outline.sections.first else { return nil }
    let start = max(1, first.startLine)
    let end = min(outline.revision.lineCount, first.endLine)
    guard start <= end else { return nil }
    return start...end
  }
}
import Foundation

/// Importance level controlling observation retention in the active-turn
/// projection. Higher importance observations are kept full for longer.
enum ObservationImportance: Int, Sendable, Comparable {
  case low = 0      // successful commands, no-op reads
  case normal = 1   // successful reads, successful edits
  case high = 2     // most recent source slice, most recent failed command
  case pinned = 3   // stale/ambiguous errors until the file is re-read

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The bounded compact representation of a completed tool exchange, eligible
/// for use in later inference requests in place of the full tool result.
///
/// Receipts must be deterministic and engine-authored. They must not embed
/// model reasoning or unverified claims from the model's own arguments.
struct ToolReceipt: Sendable, Equatable {
  /// One-line human-readable outcome, e.g. "read 45 lines (partial)"
  let summary: String
  /// Workspace-relative paths touched by the tool call.
  let paths: [String]
  /// File revisions observed or produced, for stale-check accounting.
  let revisions: [FileRevision]
  /// Machine-readable outcome token: "ok", "partial", "error", "denied".
  let outcome: String

  /// Renders a compact, labeled string suitable for use as a tool result
  /// in a projected message. Always shorter than the full result.
  func render() -> String {
    var lines: [String] = ["[receipt outcome=\"\(outcome)\""]
    if !paths.isEmpty {
      let joinedPaths = paths.joined(separator: ",")
      lines[0] += " paths=\"\(joinedPaths)\""
    }
    lines[0] += "]"
    lines.append(summary)
    for rev in revisions {
      let base = (rev.path as NSString).lastPathComponent
      lines.append("revision: \(base)=\(rev.digest)")
    }
    lines.append("[end receipt]")
    return lines.joined(separator: "\n")
  }
}

/// Runtime record of one completed tool exchange within the current user turn.
///
/// The observation is not sent to the model directly; `ConversationProjection`
/// decides whether to include the full result or compact it to `receipt`.
struct ToolObservation: Sendable {
  let callID: String
  let name: String
  let arguments: JSONValue
  /// The complete tool result string, as stored in the canonical message list.
  let fullResult: String
  /// Compact receipt used when the observation is eligible for compaction.
  let receipt: ToolReceipt
  /// Retention priority for the active-turn projection.
  var importance: ObservationImportance

  /// True when this is a source read (read_file) result.
  var isSourceRead: Bool { name == "read_file" }
  /// True when this is a write or edit result.
  var isEdit: Bool { name == "edit_file" || name == "write_file" || name == "apply_patch" }
  /// True when this is a shell command result.
  var isCommand: Bool { name == "execute_bash" || name == "python_scratchpad" }

  /// True when the full result looks like a failure (edit conflict, error, etc.).
  var isFailure: Bool {
    return fullResult.hasPrefix("Error") || fullResult.hasPrefix("Error:")
      || fullResult.contains("staleRevision") || fullResult.contains("targetAmbiguous")
      || fullResult.contains("targetNotFound") || fullResult.contains("revisionRequired")
      || fullResult.contains("overlappingHunks")
  }
}

extension ToolObservation {
  /// Builds a `ToolObservation` from a completed tool call and its result.
  /// Extracts revision metadata from the result envelope when present.
  static func make(
    call: ParsedToolCall, result: String, workingState: TurnWorkingState
  ) -> ToolObservation {
    let paths = extractPaths(from: call)
    let revisions = workingState.currentRevisions(for: paths)
    let importance = classifyImportance(name: call.name, result: result)
    let receipt = makeReceipt(call: call, result: result, paths: paths, revisions: revisions)
    return ToolObservation(
      callID: call.id, name: call.name, arguments: call.arguments,
      fullResult: result, receipt: receipt, importance: importance)
  }

  private static func extractPaths(from call: ParsedToolCall) -> [String] {
    guard case .object(let args) = call.arguments,
      case .string(let path) = args["path"]
    else { return [] }
    return [path]
  }

  private static func classifyImportance(
    name: String, result: String
  ) -> ObservationImportance {
    let isError =
      result.hasPrefix("Error") || result.contains("staleRevision")
      || result.contains("targetAmbiguous") || result.contains("targetNotFound")
      || result.contains("revisionRequired") || result.contains("overlappingHunks")
    if isError
      && (name == "edit_file" || name == "write_file" || name == "apply_patch")
      && (result.contains("staleRevision") || result.contains("revisionRequired")) {
      return .pinned  // must stay until the file is re-read
    }
    if isError { return .normal }
    if name == "read_file" { return .normal }
    if name == "edit_file" || name == "write_file" || name == "apply_patch" { return .normal }
    if name == "execute_bash" || name == "python_scratchpad" { return .normal }
    return .low
  }

  private static func makeReceipt(
    call: ParsedToolCall, result: String, paths: [String], revisions: [FileRevision]
  ) -> ToolReceipt {
    let outcome: String
    if result.hasPrefix("Error") { outcome = "error" }
    else if result.contains("complete=\"false\"") { outcome = "partial" }
    else if result.hasPrefix("No-op:") { outcome = "noop" }
    else { outcome = "ok" }

    let summary = makeSummary(name: call.name, result: result, paths: paths)
    return ToolReceipt(summary: summary, paths: paths, revisions: revisions, outcome: outcome)
  }

  private static func makeSummary(name: String, result: String, paths: [String]) -> String {
    let base = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
    switch name {
    case "read_file":
      // Extract line range from envelope if present, e.g. lines="1-45/388"
      if let range = result.range(of: "lines=\"([^\"]+)\"", options: .regularExpression) {
        let match = String(result[range])
        if let firstQuote = match.firstIndex(of: "\""), let lastQuote = match.lastIndex(of: "\""), firstQuote != lastQuote {
            let extracted = String(match[match.index(after: firstQuote)..<lastQuote])
            return base.isEmpty ? "read \(extracted)" : "read \(base) \(extracted)"
        }
      }
      return base.isEmpty ? "read file" : "read \(base)"
    case "edit_file":
      if result.contains("Successfully updated") { return base.isEmpty ? "edited" : "edited \(base)" }
      return base.isEmpty ? "edit: \(String(result.prefix(60)))" : "\(base): \(String(result.prefix(50)))"
    case "apply_patch":
      if result.contains("Successfully patched") { return base.isEmpty ? "patched" : "patched \(base)" }
      return base.isEmpty ? "patch: \(String(result.prefix(60)))" : "\(base): \(String(result.prefix(50)))"
    case "write_file":
      if result.contains("Successfully wrote") || result.contains("Created") {
        return base.isEmpty ? "wrote" : "wrote \(base)"
      }
      return base.isEmpty ? "write: \(String(result.prefix(60)))" : "\(base): \(String(result.prefix(50)))"
    case "execute_bash", "python_scratchpad":
      // Preserve exit status
      if let exitLine = result.split(separator: "\n").first(where: { $0.contains("Exit") || $0.contains("exit") }) {
        return String(exitLine.prefix(80))
      }
      return String(result.prefix(80))
    default:
      return String(result.prefix(80))
    }
  }
}

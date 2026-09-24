import Foundation

/// Per-user-turn deterministic working state tracked by the agent.
///
/// This is ephemeral runtime state, not durable memory. It is never written
/// into `ContinuityCore` automatically. It is discarded when the user turn
/// finishes. Its purpose is to give the projection layer engine-authored facts
/// that survive tool-result compaction and exchange eviction.
struct TurnWorkingState: Sendable {
  // MARK: - Objective

  /// The original user request text.
  var objective: String = ""

  // MARK: - Files

  /// Workspace-relative paths the model has inspected or intends to edit.
  var candidatePaths: [String] = []

  /// Most recent known revision per resolved path.
  /// Key: workspace-relative path. Value: digest string.
  var knownRevisions: [String: String] = [:]

  /// Line ranges inspected per path. Key: path, Value: list of (start, end) pairs.
  var inspectedRanges: [String: [(start: Int, end: Int)]] = [:]

  // MARK: - Edits

  /// Brief descriptions of edits successfully applied this turn.
  var appliedEdits: [String] = []

  // MARK: - Commands

  /// Brief records of commands run and their exit status.
  var commandResults: [CommandRecord] = []

  struct CommandRecord: Sendable {
    let command: String
    let exitStatus: Int?
    let succeeded: Bool
  }

  // MARK: - Failures

  /// The most recent unresolved failure description (stale write, test failure, etc.).
  var lastFailure: String?

  // MARK: - Telemetry

  /// Structured local telemetry for the turn.
  var telemetry = LargeFileEditingTelemetry()

  /// Number of tool results compacted to receipts in the current projection.
  var compactedObservationCount: Int = 0

  /// Number of complete tool exchange groups evicted in the current projection.
  var evictedGroupCount: Int = 0

  /// Optional repository retrieval hints injected at the start of a task.
  var retrievalBriefing: String? = nil

  // MARK: - Task Graph

  /// Remaining or pending task IDs in the current turn's task graph.
  var remainingTasks: [String] = []

  /// Current task graph execution status or summary.
  var taskGraphSummary: String? = nil

  // MARK: - Projection rendering

  /// Hard byte ceiling for the rendered working-state block.
  private static let maxRenderedBytes = 1_200

  /// Whether there are any concrete facts to report beyond the user prompt.
  var hasFacts: Bool {
    !candidatePaths.isEmpty || !knownRevisions.isEmpty || !appliedEdits.isEmpty
      || !commandResults.isEmpty || lastFailure != nil
      || compactedObservationCount > 0 || evictedGroupCount > 0
      || !remainingTasks.isEmpty || taskGraphSummary != nil
  }

  /// Renders the current state as a concise block for injection into
  /// the model's context. Engine-authored facts only; no model reasoning.
  /// Always bounded to `maxRenderedBytes`.
  func render() -> String {
    guard hasFacts else { return "" }
    var lines: [String] = ["## Current task state"]
    if !objective.isEmpty { lines.append("Objective: " + String(objective.prefix(200))) }

    let targets = candidatePaths.prefix(8)
    if !targets.isEmpty { lines.append("Targets: " + targets.joined(separator: ", ")) }

    // Revisions
    let revPairs = knownRevisions.sorted(by: { $0.key < $1.key }).prefix(6)
    if !revPairs.isEmpty {
      let revLine = revPairs.map { "\(($0.key as NSString).lastPathComponent): \($0.value)" }.joined(separator: ", ")
      lines.append("Revisions: " + revLine)
    }

    // Inspected ranges
    for path in candidatePaths.prefix(4) {
      guard let ranges = inspectedRanges[path], !ranges.isEmpty else { continue }
      let base = (path as NSString).lastPathComponent
      let rangeStr = ranges.prefix(6).map { "\($0.start)-\($0.end)" }.joined(separator: ",")
      lines.append("Inspected: \(base):\(rangeStr)")
    }

    // Applied edits
    let edits = appliedEdits.suffix(4)
    if !edits.isEmpty { lines.append("Applied: " + edits.joined(separator: "; ")) }

    // Commands
    let cmds = commandResults.suffix(3)
    if !cmds.isEmpty {
      let cmdLine = cmds.map { r in
        let status = r.exitStatus.map { " (exit \($0))" } ?? ""
        return String(r.command.prefix(40)) + status
      }.joined(separator: "; ")
      lines.append("Commands: " + cmdLine)
    }

    // Last failure
    if let failure = lastFailure {
      lines.append("Last failure: " + String(failure.prefix(200)))
    }

    // Task graph
    if let summary = taskGraphSummary {
      lines.append("Tasks: " + String(summary.prefix(200)))
    } else if !remainingTasks.isEmpty {
      let taskList = remainingTasks.prefix(6).joined(separator: ", ")
      lines.append("Remaining tasks: " + taskList)
    }

    // Compaction telemetry
    if compactedObservationCount > 0 || evictedGroupCount > 0 {
      var tel = "Compacted observations: \(compactedObservationCount)"
      if evictedGroupCount > 0 { tel += "; evicted exchange groups: \(evictedGroupCount)" }
      lines.append(tel)
    }

    let rendered = lines.joined(separator: "\n")
    if rendered.utf8.count <= Self.maxRenderedBytes { return rendered }
    // Truncate to ceiling while keeping the header
    var result = ""
    for line in lines {
      let candidate = result.isEmpty ? line : result + "\n" + line
      if candidate.utf8.count > Self.maxRenderedBytes { break }
      result = candidate
    }
    return result
  }

  // MARK: - Mutation helpers

  mutating func recordRead(path: String, digest: String, startLine: Int?, endLine: Int?) {
    if !candidatePaths.contains(path) { candidatePaths.append(path) }
    knownRevisions[path] = digest
    if let s = startLine, let e = endLine {
      let existingRanges = inspectedRanges[path] ?? []
      if existingRanges.contains(where: { max($0.start, s) <= min($0.end, e) }) {
        telemetry.sourceRangesReopenedCount += 1
      }
      inspectedRanges[path, default: []].append((start: s, end: e))
      telemetry.sourceRangesRead[path, default: []].append((start: s, end: e))
    }
    if telemetry.firstReadPath == nil {
      telemetry.firstReadPath = path
      let hitCandidate = telemetry.retrievalCandidates.contains(path)
        || (retrievalBriefing?.contains(path) == true)
      telemetry.firstReadUsedRetrievalCandidate = hitCandidate
    }
    // Remove any prior failure related to stale reads of this path.
    if let failure = lastFailure, failure.contains(path) { lastFailure = nil }
  }

  mutating func recordEdit(path: String, newDigest: String, description: String) {
    knownRevisions[path] = newDigest
    appliedEdits.append(description)
    // An edit immediately compacts the read result (the revision is now stale).
  }

  mutating func recordCommand(command: String, exitStatus: Int?, succeeded: Bool) {
    commandResults.append(CommandRecord(command: command, exitStatus: exitStatus, succeeded: succeeded))
    if !succeeded {
      lastFailure = "command failed: " + String(command.prefix(100))
    } else if commandResults.last.map({ !$0.succeeded }) == .some(false) {
      // A new success doesn't automatically clear a prior non-command failure.
    }
    let lowerCmd = command.lowercased()
    let isValidation = lowerCmd.contains("test") || lowerCmd.contains("build") || lowerCmd.contains("check")
    if isValidation {
      telemetry.validationAttempts += 1
      if !succeeded {
        telemetry.validationFailures += 1
        let fingerprint = String(command.prefix(60))
        if telemetry.failureFingerprints.contains(fingerprint) {
          telemetry.repeatedFailureFingerprints += 1
        } else {
          telemetry.failureFingerprints.insert(fingerprint)
        }
      }
    }
  }

  mutating func recordFailure(_ description: String) {
    lastFailure = String(description.prefix(300))
  }

  mutating func clearFailure() {
    lastFailure = nil
  }

  /// Returns the most recent known `FileRevision` objects for the given paths,
  /// used when building receipts.
  func currentRevisions(for paths: [String]) -> [FileRevision] {
    paths.compactMap { path in
      guard let digest = knownRevisions[path] else { return nil }
      return FileRevision(path: path, digest: digest)
    }
  }

  /// Updates working state after a tool execution completes.
  mutating func recordToolResult(call: ParsedToolCall, result: String) {
    telemetry.totalToolRounds += 1
    let path = call.stringArgument("path")
    switch call.name {
    case "read_file":
      if let path {
        if !candidatePaths.contains(path) { candidatePaths.append(path) }
        var digest: String? = nil
        if let range = result.range(of: "digest=\"([^\"]+)\"", options: .regularExpression) {
          let match = String(result[range])
          if let firstQuote = match.firstIndex(of: "\""), let lastQuote = match.lastIndex(of: "\""), firstQuote != lastQuote {
            digest = String(match[match.index(after: firstQuote)..<lastQuote])
          }
        }
        var startLine: Int? = nil
        var endLine: Int? = nil
        if let range = result.range(of: "lines=\"([^\"]+)\"", options: .regularExpression) {
          let match = String(result[range])
          if let firstQuote = match.firstIndex(of: "\""), let lastQuote = match.lastIndex(of: "\""), firstQuote != lastQuote {
            let lineStr = String(match[match.index(after: firstQuote)..<lastQuote])
            let parts = lineStr.split(separator: "/")
            if let rangePart = parts.first {
              let bounds = rangePart.split(separator: "-")
              if bounds.count == 2, let s = Int(bounds[0]), let e = Int(bounds[1]) {
                startLine = s
                endLine = e
              }
            }
          }
        }
        if let digest {
          recordRead(path: path, digest: digest, startLine: startLine, endLine: endLine)
        }
      }
      if result.hasPrefix("Error") {
        recordFailure(result)
      }
    case "edit_file", "write_file", "apply_patch":
      if let path {
        if !candidatePaths.contains(path) { candidatePaths.append(path) }
        if result.contains("Successfully") {
          var newDigest: String? = nil
          if let range = result.range(of: "(New revision|Revision): (sha256:[a-f0-9]+)", options: .regularExpression) {
            let match = String(result[range])
            if let colon = match.range(of: ": sha256:") {
              newDigest = String(match[match.index(after: colon.lowerBound)...]).trimmingCharacters(in: .whitespaces)
            }
          }
          if let newDigest {
            recordEdit(path: path, newDigest: newDigest, description: "\(call.name) \((path as NSString).lastPathComponent)")
          }
        } else if result.hasPrefix("Error") || result.contains("staleRevision") || result.contains("targetAmbiguous") || result.contains("targetNotFound") || result.contains("revisionRequired") || result.contains("overlappingHunks") {
          if result.contains("staleRevision") {
            telemetry.staleEditRejections += 1
          }
          if result.contains("targetAmbiguous") {
            telemetry.ambiguousEditRejections += 1
          }
          recordFailure(result)
        }
      }
    case "execute_bash", "python_scratchpad":
      let cmd = call.stringArgument("command") ?? call.stringArgument("code") ?? call.name
      let failed = result.hasPrefix("Error") || (result.contains("exit status: ") && !result.contains("exit status: 0"))
      var exitCode: Int? = nil
      if let range = result.range(of: "exit status: ([0-9]+)", options: .regularExpression) {
        let match = String(result[range])
        if let space = match.lastIndex(of: " ") {
          exitCode = Int(match[match.index(after: space)...])
        }
      }
      recordCommand(command: cmd, exitStatus: exitCode, succeeded: !failed)
    default:
      if result.hasPrefix("Error") {
        recordFailure(result)
      }
    }
  }
}

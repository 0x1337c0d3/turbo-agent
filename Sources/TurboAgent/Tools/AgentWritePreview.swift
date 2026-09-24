import Foundation

/// One anchored edit proposal against a specific source revision. The model
/// proposes; the runtime verifies, previews and applies.
struct AgentWritePlan: Sendable, Equatable {
  let path: String
  let resolvedPath: String
  let originalContent: String?
  let updatedContent: String
  let diff: String

  func verifySourceIsUnchanged(context: AgentToolContext) async throws {
    let current = try await AgentWritePreview.readExistingFile(resolvedPath, context: context)
    guard current == originalContent else {
      throw AgentWritePreview.Error.sourceChanged(path)
    }
  }
}

enum AgentWritePreview {
  enum Error: Swift.Error, CustomStringConvertible, Equatable {
    case invalidArguments(String)
    case missingFile(String)
    case targetNotFound(String)
    case sourceChanged(String)
    // Phase 2 of docs/LARGE_FILE_EDITING.md: anchored edits are revision
    // guarded, unique by default, and fail closed before any preview is shown.
    case revisionRequired(String)
    case staleRevision(String)
    case targetAmbiguous(String)
    case replacementRequiresWholeFileRead(String)
    case targetCreatedAfterPreview(String)
    // Phase 5 of docs/LARGE_FILE_EDITING.md: multi-hunk patch validation
    case overlappingHunks(String)

    var description: String {
      switch self {
      case .invalidArguments(let tool): return "invalid arguments for \(tool)"
      case .missingFile(let path): return "file not found: \(path)"
      case .targetNotFound(let path):
        return
          "target string not found in \(path). Ensure 'target' exactly matches the current file."
      case .sourceChanged(let path):
        return "\(path) changed after its diff preview; refusing to apply a stale write"
      case .revisionRequired(let path):
        return
          "\(path) requires expected_digest set to the file revision digest from your last read_file. Read the file, then re-propose the edit."
      case .staleRevision(let path):
        return
          "\(path) changed since your last read (stale expected_digest). Read the current revision and re-propose the edit."
      case .targetAmbiguous(let path):
        return
          "target matches multiple locations in \(path). Provide a larger unique target or set replace_all to replace every occurrence."
      case .replacementRequiresWholeFileRead(let path):
        return
          "\(path) was not read completely at the digest you supplied. Whole-file replacement requires a complete read_file of the current revision; use edit_file for bounded changes or read the full file first."
      case .targetCreatedAfterPreview(let path):
        return "\(path) was created after its diff preview; refusing to overwrite it"
      case .overlappingHunks(let path):
        return "patch hunks overlap in \(path). Ensure each hunk targets a distinct, non-overlapping region of the file."
      }
    }
  }

  private static let contextLines = 3
  private static let maximumLines = 240
  private static let maximumBytes = 24_000

  static func digestMatches(current: String, expected: String) -> Bool {
    var clean = expected.trimmingCharacters(in: .whitespacesAndNewlines)
    if let eqIndex = clean.lastIndex(of: "=") {
      let after = String(clean[clean.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if after.hasPrefix("sha256:") {
        clean = after
      }
    } else if let colonIndex = clean.firstIndex(of: ":"), clean[..<colonIndex].contains(".") {
      let after = String(clean[clean.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if after.hasPrefix("sha256:") {
        clean = after
      }
    }
    clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "… \t\n\r\"'"))
    if current == clean { return true }
    if clean.hasPrefix("sha256:") && clean.count >= 20 && current.hasPrefix(clean) {
      return true
    }
    return false
  }

  static func prepare(call: ParsedToolCall, context: AgentToolContext) async throws
    -> AgentWritePlan?
  {
    guard call.name == "write_file" || call.name == "edit_file" || call.name == "apply_patch"
    else { return nil }
    guard let path = call.stringArgument("path") else {
      throw Error.invalidArguments(call.name)
    }
    let resolvedPath = context.path(path)
    if call.name == "write_file" {
      return try await prepareWholeFileReplacement(
        call: call, path: path, resolvedPath: resolvedPath, context: context)
    }
    if call.name == "apply_patch" {
      return try await prepareApplyPatch(
        call: call, path: path, resolvedPath: resolvedPath, context: context)
    }
    return try await prepareAnchoredEdit(
      call: call, path: path, resolvedPath: resolvedPath, context: context)
  }

  // MARK: apply_patch

  struct PatchHunk: Sendable, Equatable, Codable {
    let target: String
    let replacement: String
  }

  private static func prepareApplyPatch(
    call: ParsedToolCall, path: String, resolvedPath: String, context: AgentToolContext
  ) async throws -> AgentWritePlan? {
    guard let hunksArray = call.arrayArgument("hunks"), !hunksArray.isEmpty else {
      throw Error.invalidArguments(call.name)
    }
    var hunks: [PatchHunk] = []
    for item in hunksArray {
      guard case .object(let dict) = item,
        case .string(let target)? = dict["target"],
        case .string(let replacement)? = dict["replacement"],
        !target.isEmpty
      else {
        throw Error.invalidArguments(call.name)
      }
      hunks.append(PatchHunk(target: target, replacement: replacement))
    }
    guard let expectedDigest = call.stringArgument("expected_digest") else {
      throw Error.revisionRequired(path)
    }
    let original = try await readExistingFile(resolvedPath, context: context)
    guard let original else { throw Error.missingFile(path) }

    let currentDigest = FileRevision.digest(of: original)
    guard digestMatches(current: currentDigest, expected: expectedDigest) else {
      throw Error.staleRevision(path)
    }

    var locatedHunks: [(hunk: PatchHunk, range: Range<String.Index>)] = []
    for hunk in hunks {
      let count = occurrenceCount(of: hunk.target, in: original)
      guard count > 0 else { throw Error.targetNotFound(path) }
      guard count == 1 else { throw Error.targetAmbiguous(path) }
      guard let range = original.range(of: hunk.target) else {
        throw Error.targetNotFound(path)
      }
      locatedHunks.append((hunk: hunk, range: range))
    }

    // Reject overlapping hunks
    let sortedByStart = locatedHunks.sorted { $0.range.lowerBound < $1.range.lowerBound }
    for i in 0..<(sortedByStart.count - 1) {
      let current = sortedByStart[i].range
      let next = sortedByStart[i + 1].range
      if current.upperBound > next.lowerBound {
        throw Error.overlappingHunks(path)
      }
    }

    // Apply hunks against base in reverse order of position so indices remain valid
    var updated = original
    let sortedDescending = locatedHunks.sorted { $0.range.lowerBound > $1.range.lowerBound }
    for located in sortedDescending {
      updated.replaceSubrange(located.range, with: located.hunk.replacement)
    }

    if updated == original {
      return nil
    }

    return AgentWritePlan(
      path: path, resolvedPath: resolvedPath, originalContent: original,
      updatedContent: updated, diff: render(path: path, before: original, after: updated))
  }

  // MARK: edit_file

  private static func prepareAnchoredEdit(
    call: ParsedToolCall, path: String, resolvedPath: String, context: AgentToolContext
  ) async throws -> AgentWritePlan? {
    guard let target = call.stringArgument("target"),
      let replacement = call.stringArgument("replacement")
    else {
      throw Error.invalidArguments(call.name)
    }
    guard !target.isEmpty else { throw Error.invalidArguments(call.name) }
    guard let expectedDigest = call.stringArgument("expected_digest") else {
      // Failing before the read keeps stale files from even showing a diff.
      throw Error.revisionRequired(path)
    }
    let replaceAll = call.boolArgument("replace_all") ?? false
    let original = try await readExistingFile(resolvedPath, context: context)
    guard let original else { throw Error.missingFile(path) }
    // The revision observed by the model must be the revision being edited.
    // The later complete-content check protects only the preview-to-apply gap.
    let currentDigest = FileRevision.digest(of: original)
    guard digestMatches(current: currentDigest, expected: expectedDigest) else { throw Error.staleRevision(path) }

    let occurrences = occurrenceCount(of: target, in: original)
    guard occurrences > 0 else { throw Error.targetNotFound(path) }
    guard occurrences == 1 || replaceAll else { throw Error.targetAmbiguous(path) }
    let updated: String
    if replaceAll {
      updated = original.replacingOccurrences(of: target, with: replacement)
    } else {
      guard let range = original.range(of: target) else {
        throw Error.targetNotFound(path)
      }
      updated = original.replacingCharacters(in: range, with: replacement)
    }
    if updated == original {
      // A no-op replacement is reported without asking for a write.
      return nil
    }
    return AgentWritePlan(
      path: path, resolvedPath: resolvedPath, originalContent: original,
      updatedContent: updated, diff: render(path: path, before: original, after: updated))
  }

  /// Counts occurrences without substring-overlap ambiguity: each match starts
  /// at or after the end of the previous one, matching replaceAll semantics.
  private static func occurrenceCount(of target: String, in source: String) -> Int {
    guard !target.isEmpty else { return 0 }
    var count = 0
    var searchStart = source.startIndex
    while let range = source.range(of: target, range: searchStart..<source.endIndex) {
      count += 1
      searchStart = range.upperBound == searchStart
        ? source.index(after: range.upperBound) : range.upperBound
    }
    return count
  }

  // MARK: write_file

  private static func prepareWholeFileReplacement(
    call: ParsedToolCall, path: String, resolvedPath: String, context: AgentToolContext
  ) async throws -> AgentWritePlan? {
    guard let content = call.stringArgument("content") else {
      throw Error.invalidArguments(call.name)
    }
    let original = try await readExistingFile(resolvedPath, context: context)
    guard let original else {
      // Creating a new file keeps the existing preview/approval behavior.
      return AgentWritePlan(
        path: path, resolvedPath: resolvedPath, originalContent: nil,
        updatedContent: content, diff: render(path: path, before: nil, after: content))
    }
    guard let expectedDigest = call.stringArgument("expected_digest") else {
      throw Error.revisionRequired(path)
    }
    let currentDigest = FileRevision.digest(of: original)
    guard digestMatches(current: currentDigest, expected: expectedDigest) else {
      throw Error.staleRevision(path)
    }
    // Partial evidence (a range read, an outline, a receipt, or separate
    // slices) never authorizes whole-file replacement.
    guard ReadRevisionLedger.shared.isCompleteRead(
      resolvedPath: resolvedPath, digest: currentDigest)
    else {
      throw Error.replacementRequiresWholeFileRead(path)
    }
    if content == original {
      return nil
    }
    return AgentWritePlan(
      path: path, resolvedPath: resolvedPath, originalContent: original,
      updatedContent: content, diff: render(path: path, before: original, after: content))
  }

  /// Confirms a creation target did not appear and a replacement target did
  /// not change between preview and approval.
  static func verifyCreationIsStillNew(
    _ resolvedPath: String, context: AgentToolContext
  ) async throws {
    let current = try await readExistingFile(resolvedPath, context: context)
    guard current == nil else {
      throw Error.targetCreatedAfterPreview(resolvedPath)
    }
  }

  static func readExistingFile(_ path: String, context: AgentToolContext) async throws -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    if let read = context.interaction?.readFile { return try await read(path) }
    return try String(contentsOfFile: path, encoding: .utf8)
  }

  static func render(path: String, before: String?, after: String) -> String {
    let oldLines = lines(before ?? "")
    let newLines = lines(after)
    let oldHeader = before == nil ? "/dev/null" : "a/\(path)"
    var rendered = ["--- \(oldHeader)", "+++ b/\(path)"]
    guard before != after else {
      rendered.append("(no changes)")
      return rendered.joined(separator: "\n")
    }

    var prefix = 0
    while prefix < oldLines.count, prefix < newLines.count,
      oldLines[prefix] == newLines[prefix]
    {
      prefix += 1
    }
    var suffix = 0
    while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
      oldLines[oldLines.count - suffix - 1] == newLines[newLines.count - suffix - 1]
    {
      suffix += 1
    }

    let oldChangeEnd = oldLines.count - suffix
    let newChangeEnd = newLines.count - suffix
    let leadingStart = max(0, prefix - contextLines)
    let trailingCount = min(contextLines, suffix)
    let oldCount = prefix - leadingStart + oldChangeEnd - prefix + trailingCount
    let newCount = prefix - leadingStart + newChangeEnd - prefix + trailingCount
    rendered.append(
      "@@ -\(hunkStart(leadingStart, count: oldCount)),\(oldCount) +\(hunkStart(leadingStart, count: newCount)),\(newCount) @@"
    )

    var omitted = 0
    var byteCount = rendered.reduce(0) { $0 + $1.utf8.count + 1 }
    func append(_ marker: Character, _ line: String) {
      let candidate = String(marker) + line
      guard rendered.count < maximumLines,
        byteCount + candidate.utf8.count + 1 <= maximumBytes
      else {
        omitted += 1
        return
      }
      rendered.append(candidate)
      byteCount += candidate.utf8.count + 1
    }
    for index in leadingStart..<prefix { append(" ", oldLines[index]) }
    for index in prefix..<oldChangeEnd { append("-", oldLines[index]) }
    for index in prefix..<newChangeEnd { append("+", newLines[index]) }
    if trailingCount > 0 {
      for index in oldChangeEnd..<(oldChangeEnd + trailingCount) {
        append(" ", oldLines[index])
      }
    }
    if omitted > 0 {
      rendered.append("... diff preview truncated; \(omitted) lines omitted ...")
    }
    return rendered.joined(separator: "\n")
  }

  private static func lines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func hunkStart(_ zeroBasedStart: Int, count: Int) -> Int {
    count == 0 ? 0 : zeroBasedStart + 1
  }
}

extension ParsedToolCall {
  /// Boolean tool argument from the model's call; absent means false.
  func boolArgument(_ key: String) -> Bool? {
    guard case .object(let arguments) = arguments else { return nil }
    return arguments[key]?.boolean
  }
}

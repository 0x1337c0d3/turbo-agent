import Foundation

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

    var description: String {
      switch self {
      case .invalidArguments(let tool): return "invalid arguments for \(tool)"
      case .missingFile(let path): return "file not found: \(path)"
      case .targetNotFound(let path):
        return
          "target string not found in \(path). Ensure 'target' exactly matches the current file."
      case .sourceChanged(let path):
        return "\(path) changed after its diff preview; refusing to apply a stale write"
      }
    }
  }

  private static let contextLines = 3
  private static let maximumLines = 240
  private static let maximumBytes = 24_000

  static func prepare(call: ParsedToolCall, context: AgentToolContext) async throws
    -> AgentWritePlan?
  {
    guard call.name == "write_file" || call.name == "edit_file" else { return nil }
    guard let path = call.stringArgument("path") else {
      throw Error.invalidArguments(call.name)
    }
    let resolvedPath = context.path(path)
    let original = try await readExistingFile(resolvedPath, context: context)
    let updated: String
    if call.name == "write_file" {
      guard let content = call.stringArgument("content") else {
        throw Error.invalidArguments(call.name)
      }
      updated = content
    } else {
      guard let target = call.stringArgument("target"),
        let replacement = call.stringArgument("replacement")
      else {
        throw Error.invalidArguments(call.name)
      }
      guard let original else { throw Error.missingFile(path) }
      guard original.contains(target) else { throw Error.targetNotFound(path) }
      updated = original.replacingOccurrences(of: target, with: replacement)
    }
    return AgentWritePlan(
      path: path, resolvedPath: resolvedPath, originalContent: original,
      updatedContent: updated, diff: render(path: path, before: original, after: updated))
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

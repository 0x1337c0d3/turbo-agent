import Darwin
import Foundation

/// Model output is a proposal, never authorization to act on the user's machine.
enum ToolApproval {
  /// File-writing arguments carry whole file bodies and edit targets. The
  /// approval view renders the diff separately, so the argument block shows
  /// a size notice instead of duplicating megabytes of source. Without this
  /// an 8K model's oversized target/replacement would also land verbatim in
  /// the transcript as tool-call arguments.
  static func redactedArguments(_ call: ParsedToolCall) -> JSONValue {
    guard case .object(let arguments) = call.arguments else { return call.arguments }
    var redacted: [String: JSONValue] = arguments
    for key in ["target", "replacement", "content"] {
      guard case .string(let value)? = arguments[key] else { continue }
      let bytes = value.utf8.count
      redacted[key] = .string("<omitted: \(bytes) bytes; see diff preview>")
    }
    return .object(redacted)
  }

  static func request(_ call: ParsedToolCall, diff: String? = nil) -> Bool {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
    if let diff { displayDiff(diff) }
    let displayedArguments: JSONValue
    if diff != nil, let path = call.stringArgument("path") {
      displayedArguments = .object(["path": .string(path)])
    } else {
      displayedArguments = redactedArguments(call)
    }
    guard let arguments = try? JSONEncoder().encode(displayedArguments),
      let object = try? JSONSerialization.jsonObject(with: arguments),
      let formatted = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: formatted, encoding: .utf8)
    else { return false }
    printColor("\n[Tool approval] \(call.name)\n\(text)\nAllow this call? [y/N] ", color: "yellow")
    return accepts(Swift.readLine())
  }

  static func displayDiff(_ diff: String) {
    guard isatty(STDOUT_FILENO) == 1 else { return }
    printColor("\n[Diff preview]\n\(diff)\n", color: "blue")
  }

  static func accepts(_ answer: String?) -> Bool {
    guard let answer else { return false }
    return ["y", "yes"].contains(
      answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}

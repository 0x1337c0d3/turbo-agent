import Darwin
import Foundation

/// Model output is a proposal, never authorization to act on the user's machine.
enum ToolApproval {
  static func request(_ call: ParsedToolCall, diff: String? = nil) -> Bool {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
    if let diff { displayDiff(diff) }
    let displayedArguments: JSONValue
    if diff != nil, let path = call.stringArgument("path") {
      displayedArguments = .object(["path": .string(path)])
    } else {
      displayedArguments = call.arguments
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

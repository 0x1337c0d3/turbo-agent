import AgentLineEditor
import Foundation

// MARK: - Utilities
func printColor(_ text: String, color: String) {
  let colorCode: String
  switch color {
  case "green": colorCode = "\u{001B}[32m"
  case "yellow": colorCode = "\u{001B}[33m"
  case "blue": colorCode = "\u{001B}[34m"
  case "reset": colorCode = "\u{001B}[0m"
  case "gray": colorCode = "\u{001B}[90m"
  default: colorCode = ""
  }
  terminalPrint("\(colorCode)\(TerminalText.safe(text))\u{001B}[0m", terminator: "")
  fflush(stdout)
}

func getTerminalWidth() -> Int {
  var w = winsize()
  if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 && w.ws_col > 0 {
    return Int(w.ws_col)
  }
  return 80
}

func printSeparator() {
  let width = getTerminalWidth()
  printColor(String(repeating: "─", count: width) + "\n", color: "gray")
}

struct ReadlineWrapper {
  static var historyFilePath: String? {
    guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
    let dir = home + "/.cache/TurboFieldfareAgent"
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: nil)
    return dir + "/history.txt"
  }

  nonisolated(unsafe) static var sigintSource: DispatchSourceSignal?
  nonisolated(unsafe) static var ctrlCCount = 0
  nonisolated(unsafe) static var lastCtrlCTime = Date.distantPast

  static func setup() {
    // libedit decodes input using the process character locale.
    setlocale(LC_CTYPE, "")
    sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource?.setEventHandler {
      if Date().timeIntervalSince(lastCtrlCTime) > 3.0 {
        ctrlCCount = 0
      }
      ctrlCCount += 1
      lastCtrlCTime = Date()

      if ctrlCCount >= 2 {
        print("\n[Force Exited by User]")
        exit(1)
      } else {
        print("\n[Press ctrl-c again to exit]")
      }
    }
    sigintSource?.resume()
  }

  static func read(prompt: String) -> String? {
    if sigintSource == nil { setup() }
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
      ProcessInfo.processInfo.environment["TERM"] != "dumb"
    else {
      return Swift.readLine()
    }
    // Native libedit uses one delimiter for both ends of invisible ANSI spans.
    let nativePrompt = prompt.replacingOccurrences(of: "\u{02}", with: "\u{01}")
    let input = nativePrompt.withCString { promptPointer in
      if let path = historyFilePath {
        return path.withCString {
          agent_read_prompt_with_transcript(promptPointer, $0) { action, rows in
            AgentTerminal.navigate(Int(action), promptRows: Int(rows)) ? 1 : 0
          }
        }
      }
      return agent_read_prompt_with_transcript(promptPointer, nil) { action, rows in
        AgentTerminal.navigate(Int(action), promptRows: Int(rows)) ? 1 : 0
      }
    }
    guard let input else { return nil }
    defer { free(input) }
    ctrlCCount = 0
    signal(SIGINT, SIG_IGN)
    return String(cString: input)
  }
}

// MARK: - CLI entry point
public enum AgentCommand {
  public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async throws {
    if arguments.contains("--help") || arguments.contains("-h") {
      print("TurboFieldfareAgent: use --acp for ACP over stdio; omit it for the terminal REPL.\n")
      print(
        """
        TurboFieldfareAgent [options]
          --backend <apple|openai>         Select AFM 3 or an OpenAI-compatible API
          --pcc <auto|disable|require>     Private Cloud Compute policy for Apple Foundation Models
          --max-rounds <count>             Limit tool rounds (defaults to 32 on-device)
          --yolo                           Approve tool calls without prompting
          --acp                            Serve Agent Client Protocol over stdio

        """)
      return
    }
    if arguments.contains("--acp") {
      try await ACPServer.run(arguments: arguments.filter { $0 != "--acp" })
      return
    }
    let config = try AgentConfig(arguments: arguments)
    printColor(
      "Starting TurboFieldfareAgent [Backend: \(config.backend.rawValue), PCC: \(config.pccPolicy.rawValue)]\n",
      color: "blue")
    let runtime = try await AgentRuntime(config: config)
    await ToolRegistry.reloadMCPTools()
    let session = AgentSession(runtime: runtime)
    try await session.startRepl()
  }
}

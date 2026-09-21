import AppKit
import Foundation

final class AgentSession {
  let runtime: AgentRuntime
  var messages: [AgentMessage]
  let memoryService: MemoryService

  init(runtime: AgentRuntime) {
    self.runtime = runtime
    let memoryConfig = MemoryConfiguration.fromEnvironment(ProcessInfo.processInfo.environment)
    self.memoryService = MemoryService(configuration: memoryConfig, log: { _ in })
    self.messages = [
      AgentMessage(
        role: .system, content: runtime.config.systemPrompt, toolCalls: [], toolCallID: nil,
        name: nil)
    ]
    let service = self.memoryService
    Task { [service] in await service.warmUp() }
  }

  private func handleShellCommand(userInput: String) {
    let cmdStr = String(userInput.dropFirst()).trimmingCharacters(in: .whitespaces)
    printColor("\n● Shell: \(cmdStr)\n", color: "green")
    var outputStr: String
    do {
      outputStr = try ShellCommand.run(cmdStr)
    } catch {
      printColor("Error running shell command: \(error)\n", color: "yellow")
      return
    }
    if outputStr.isEmpty { outputStr = "(No output)" }

    let displayRes =
      outputStr.count > 2000 ? String(outputStr.prefix(2000)) + "... (truncated)" : outputStr
    printColor("   \(displayRes)\n", color: "gray")

    let contextStr = "[User Executed Shell Command]: \(cmdStr)\n[Output]:\n\(displayRes)"
    messages.append(
      AgentMessage(
        role: .user, content: contextStr, toolCalls: [], toolCallID: nil, name: nil))
  }

  private func processSlashCommand(userInput: String) -> String? {
    guard userInput.hasPrefix("/") else { return userInput }

    let parts = userInput.split(separator: " ", maxSplits: 1)
    guard let command = parts.first else { return userInput }

    let cmdName = String(command.dropFirst())
    let args = parts.count > 1 ? String(parts[1]) : ""

    let fm = FileManager.default
    let homeDir = fm.homeDirectoryForCurrentUser.path
    let localDir = fm.currentDirectoryPath

    let skills = SkillLibrary.discover(roots: [
      URL(fileURLWithPath: homeDir).appendingPathComponent(".agents/skills"),
      URL(fileURLWithPath: localDir).appendingPathComponent(".agents/skills"),
    ])
    if cmdName.isEmpty || cmdName == "skills" {
      printColor("\n[Available Skills]:\n", color: "blue")
      if skills.isEmpty {
        printColor("  (No skills found in ~/.agents/skills/ or ./.agents/skills/)\n", color: "gray")
      } else {
        for skill in skills.keys.sorted() {
          printColor("  /\(skill)\n", color: "green")
        }
      }
      return nil
    }

    let loadedSkillPath = skills[cmdName]?.path
    let loadedSkillContent = loadedSkillPath.flatMap {
      try? String(contentsOfFile: $0, encoding: .utf8)
    }

    if let skillContent = loadedSkillContent, let skillPath = loadedSkillPath {
      printColor("[Loaded skill /\(cmdName) from \(skillPath)]\n", color: "blue")
      return "[Skill: \(cmdName), source: \(skillPath)]\n\(skillContent)\n\nUser Request:\n\(args)"
    } else {
      printColor(
        "Warning: Skill '/\(cmdName)' not found in ~/.agents/skills/ or ./.agents/skills/\n",
        color: "yellow")
      return nil
    }
  }

  private func printHelp() {
    printColor(
      """

      [Agent Help]
        Enter a message to ask the agent to work. Enter submits the prompt.
        Shift+Enter inserts a newline (Ctrl+J also works).
        Ctrl+A/Ctrl+E move to the start/end of the current line.
        Ctrl+O expands/collapses tool responses in place.
        Page Up/Page Down browse the retained transcript at the prompt.
        Ctrl+C clears the prompt; press again within 3 seconds to exit.
        Shift+Tab            Switch inference backend (Apple AFM / OpenAI).
        Shift+Enter requires a terminal that reports modified Enter keys.

      Commands
        ?                    Show this help (press Enter).
        /skills or /         List available slash skills.
        /<skill> [request]   Load a skill and send it with your request.
        /backend [name]      Show or switch active inference backend.
        /pcc [policy]        Cycle or set Apple PCC policy (auto/require/disable).
        @path                Attach a UTF-8 text file to your prompt.
        @"path with spaces"  Attach a file with spaces in its name.
        /prompt              Show the current system prompt.
        /copy                Copy the last assistant response as Markdown.
        /compact             Summarize and compress the conversation history.
        /clear or /new       Reset the context window to start fresh.
        /mcp                 Show configured MCP servers.
        /mcp reload          Reload MCP configuration and tool definitions.
        !<command>           Run a shell command; add its output to the conversation.
        /exit or /quit       Exit the agent.

      File references
        Example: Explain @Sources/TurboFieldfareAgent/Session.swift
        Paths are relative to the working directory; absolute and ~/ paths work.
        Up to 16 files, 256 KiB combined. Missing or invalid files stop submission.
        Separate references with whitespace; punctuation is part of the path.
        Emails stay literal; prefix an @ mention with a backslash to keep it literal.

      Skills
        Slash skills use <skill>.md or <skill>/SKILL.md in:
          ~/.agents/skills/  or  ./.agents/skills/
        If both contain the same name, the home-directory skill takes precedence.
        Example: review.md is invoked with /review Check my latest changes.
        Skill instructions are loaded only when invoked, not at startup.
        Reference documents are read only as needed for the selected skill.

      Built-in tools
        Ask for these in your message; the agent chooses when to call them.
        read_file            Read a file.
        write_file           Write a file.
        edit_file            Replace matching text in a file.
        execute_bash         Run a shell command.
        read_url             Fetch a URL and extract readable text.
        invoke_subagent      Delegate a task to a subagent.

      """, color: "gray")
    _ = processSlashCommand(userInput: "/skills")
  }

  func startRepl() async throws {
    runtime.statusLine.start(maxContext: try runtime.backend.capabilities.maxContextLength)
    AgentTerminal.beginTranscript()
    AgentTerminal.onToggleMode = { [weak self] in
      guard let self = self else { return }
      let available = self.runtime.availableTargets
      guard available.count > 1 else {
        let current = self.runtime.currentTarget.label
        printColor("\n[Only one model target available: \(current)]\n", color: "gray")
        return
      }
      let currentIdx = available.firstIndex(of: self.runtime.currentTarget) ?? 0
      let nextIdx = (currentIdx + 1) % available.count
      let nextTarget = available[nextIdx]

      self.runtime.switchTo(target: nextTarget)
      let locTag = nextTarget.isLocal ? " [Local]" : " [Cloud]"
      let modelDetail: String
      if nextTarget == .openai, let m = self.runtime.openAIBackend?.client.modelName {
        modelDetail = " (\(m))"
      } else {
        modelDetail = ""
      }
      printColor("\n[Switched to \(nextTarget.label)\(modelDetail)\(locTag)]\n", color: "yellow")
    }

    defer {
      AgentTerminal.endTranscript()
      runtime.statusLine.stop()
    }
    printColor(
      "\nType ? and press Enter for commands, skills, and built-in tools.\n", color: "gray")
    while let input = readInput() {
      if input == "/exit" || input == "/quit" {
        break
      }
      if await handleCommand(input) { continue }
      guard let request = processSlashCommand(userInput: input) else { continue }
      let prompt: String
      do {
        let directory = URL(
          fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        prompt = request + (try FileReferences.context(in: input, directory: directory))
      } catch {
        printColor("\n[Error: \(error)]\n", color: "yellow")
        continue
      }
      runtime.resetToolBudget()
      let priorMessageCount = messages.count
      messages.append(
        AgentMessage(role: .user, content: prompt, toolCalls: [], toolCallID: nil, name: nil)
      )
      do {
        _ = try await completeTurn()
      } catch ConversationTurn.TurnError.roundLimit {
        printColor(
          "\n[Turn limit reached (\(runtime.effectiveMaxRounds) rounds). Conversation preserved. You can continue or provide new instructions.]\n",
          color: "yellow")
      } catch is CancellationError {
        // Cancelled by user (e.g. ESC). Cleanly end turn and return to REPL prompt.
        if messages.count == priorMessageCount + 1 { messages.removeLast() }
      } catch {
        printColor("\n[Error: \(error)]\n", color: "yellow")
        // Keep completed tool-call/result pairs if a later generation fails.
        if messages.count == priorMessageCount + 1 { messages.removeLast() }
      }
    }
  }

  func completeTurn(resultLimit: Int = 300) async throws -> String {
    let cancellation = AgentCancellation()
    let terminal = TerminalGeneration(cancellation: cancellation)
    defer { terminal.restore() }
    let context = AgentToolContext.terminal(
      runtime, cancellation: cancellation, terminal: terminal, memoryService: memoryService)
    return try await AgentTurn.run(
      runtime: runtime, messages: &messages,
      context: context, resultLimit: resultLimit)
  }

  private func readInput() -> String? {
    terminalPrint("")
    printSeparator()
    runtime.statusLine.preparePrompt()
    let prompt = "\u{01}\u{001B}[32m\u{02}> \u{01}\u{001B}[0m\u{02}"
    guard let input = ReadlineWrapper.read(prompt: prompt) else { return nil }
    AgentTerminal.recordPrompt(input)
    printSeparator()
    return input
  }

  private func handleCommand(_ input: String) async -> Bool {
    if input.trimmingCharacters(in: .whitespacesAndNewlines) == "?" {
      printHelp()
      return true
    }
    switch input {
    case "": break
    case "/prompt":
      printColor("\n[System Prompt]:\n\(runtime.config.systemPrompt)\n", color: "gray")
    case "/backend", "/model":
      let current = self.runtime.currentTarget
      let available = self.runtime.availableTargets.map { target in
        "\(target.rawValue)\(target.isLocal ? " [Local]" : " [Cloud]")"
      }.joined(separator: ", ")
      printColor(
        "\n[Active Target]: \(current.label)\(current.isLocal ? " [Local]" : " [Cloud]")\n[Available Targets]: \(available)\n[Tip]: Press Shift-Tab to cycle targets, or use /backend <target>.\n",
        color: "cyan")
    case _ where input.hasPrefix("/backend ") || input.hasPrefix("/model "):
      let prefix = input.hasPrefix("/backend ") ? "/backend " : "/model "
      let target = input.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let resolved: AgentRuntime.ModelTarget?
      switch target {
      case "local", "apple-local", "core", "device", "on-device":
        resolved = .appleOnDevice
      case "pcc", "apple-pcc", "cloud", "pro":
        resolved = .appleCloud
      case "openai", "remote", "openrouter":
        resolved = .openai
      default:
        resolved = AgentRuntime.ModelTarget(rawValue: target)
      }
      if let resolvedTarget = resolved, self.runtime.availableTargets.contains(resolvedTarget) {
        self.runtime.switchTo(target: resolvedTarget)
        let locTag = resolvedTarget.isLocal ? " [Local]" : " [Cloud]"
        printColor("\n[Switched to \(resolvedTarget.label)\(locTag)]\n", color: "yellow")
      } else {
        let available = self.runtime.availableTargets.map { $0.rawValue }.joined(separator: ", ")
        printColor(
          "\n[Target '\(target)' not available. Choose from: \(available)]\n", color: "yellow")
      }
    case "/pcc":
      switch self.runtime.applePCCPolicy {
      case .auto: self.runtime.applePCCPolicy = .disable
      case .disable: self.runtime.applePCCPolicy = .require
      case .require: self.runtime.applePCCPolicy = .auto
      }
      let desc: String
      switch self.runtime.applePCCPolicy {
      case .auto:
        desc = "auto (prefer on-device, PCC fallback)"
        self.runtime.statusLine.snapshot.modelLabel = "AFM Auto"
      case .disable:
        desc = "disable (on-device only)"
        self.runtime.statusLine.snapshot.modelLabel = "AFM On-Device"
      case .require:
        desc = "require (Private Cloud Compute only)"
        self.runtime.statusLine.snapshot.modelLabel = "AFM Cloud (PCC)"
      }
      self.runtime.statusLine.refresh(force: true)
      printColor("\n[AFM PCC Policy: \(desc)]\n", color: "yellow")
    case _ where input.hasPrefix("/pcc "):
      let target = input.dropFirst("/pcc ".count).trimmingCharacters(in: .whitespacesAndNewlines)
      if let policy = PCCPolicy(rawValue: target) {
        self.runtime.applePCCPolicy = policy
        switch policy {
        case .auto: self.runtime.statusLine.snapshot.modelLabel = "AFM Auto"
        case .disable: self.runtime.statusLine.snapshot.modelLabel = "AFM On-Device"
        case .require: self.runtime.statusLine.snapshot.modelLabel = "AFM Cloud (PCC)"
        }
        self.runtime.statusLine.refresh(force: true)
        printColor("\n[AFM PCC Policy set to: \(policy.rawValue)]\n", color: "yellow")
      } else {
        printColor(
          "\n[Invalid PCC policy '\(target)'. Choose: auto, disable, require]\n", color: "yellow")
      }
    case "/copy":
      copyLastResponse()
    case "/compact":
      await compactHistory()
    case "/mcp reload":
      await reloadMCP()
    case "/mcp":
      printMCPServers()
    case "/consolidate":
      await runConsolidation()
    case "/clear", "/new":
      messages = [messages[0]]
      printColor("\n[Context cleared. Starting fresh.]\n", color: "green")
    case _ where input.hasPrefix("!"):
      handleShellCommand(userInput: input)
    default: return false
    }
    return true
  }

  private func runConsolidation() async {
    let memoryService = self.memoryService
    printColor("\n[Running memory consolidation...]\n", color: "blue")
    do {
      let result = try await ConsolidationAgent.run(
        runtime: runtime,
        memoryService: memoryService,
        conversationHistory: messages
      )
      printColor("\n[Consolidation Complete]:\n\(result)\n", color: "green")
    } catch {
      printColor("\n[Consolidation Failed]: \(error)\n", color: "yellow")
    }
  }

  private func compactHistory() async {
    guard messages.count > 1 else {
      printColor(
        "\n[History is already empty or only contains the system prompt.]\n", color: "yellow")
      return
    }

    printColor("\n[Compacting history...]\n", color: "blue")
    let originalMessages = messages

    messages.append(
      AgentMessage(
        role: .user,
        content: "Summarize the work done so far, noting any current objectives and dead-ends.",
        toolCalls: [], toolCallID: nil, name: nil))

    do {
      runtime.resetToolBudget()
      let summary = try await completeTurn()
      messages = [
        originalMessages[0],
        AgentMessage(
          role: .user, content: "Summary of previous work:\n\(summary)", toolCalls: [],
          toolCallID: nil, name: nil),
      ]
      printColor("\n[History compacted successfully.]\n", color: "green")
    } catch {
      printColor("\n[Error compacting history: \(error)]\n", color: "red")
      messages = originalMessages
    }
  }

  private func copyLastResponse() {
    guard
      let response = messages.last(where: {
        $0.role == .assistant && $0.toolCalls.isEmpty && !($0.content ?? "").isEmpty
      })?.content
    else {
      printColor("\n[No assistant response to copy.]\n", color: "yellow")
      return
    }
    let clipboard = NSPasteboard.general
    clipboard.clearContents()
    if clipboard.setString(response, forType: .string) {
      printColor("\n[Last response copied as Markdown.]\n", color: "green")
    } else {
      printColor("\n[Could not copy the last response to the clipboard.]\n", color: "yellow")
    }
  }

  private func reloadMCP() async {
    MCPClient.shared = MCPClient()
    await ToolRegistry.reloadMCPTools()
    guard MCPClient.shared != nil else {
      printColor("\n[MCP Client]: Failed to reload configuration.\n", color: "red")
      return
    }
    printColor("\n[MCP Client]: Reloaded successfully.\n", color: "green")
  }

  private func printMCPServers() {
    guard let client = MCPClient.shared else {
      printColor("\n[MCP Client]: Not initialized or no configuration found.\n", color: "yellow")
      return
    }
    printColor("\n[MCP Servers]:\n", color: "blue")
    for server in client.servers {
      printColor("  - \(server.name) (\(server.connectionDetails))\n", color: "green")
    }
    if client.servers.isEmpty {
      printColor("  (No MCP servers configured or running)\n", color: "gray")
    }
  }
}

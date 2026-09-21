import Foundation

struct AgentToolContext: Sendable {
  let directory: URL
  let systemPrompt: String
  let mcp: MCPClient?
  let definitions: [AgentToolDefinition]
  let interaction: AgentInteraction?
  let cancellation: AgentCancellation
  let terminal: TerminalGeneration?
  let memoryService: MemoryService?

  init(
    directory: URL,
    systemPrompt: String,
    mcp: MCPClient?,
    definitions: [AgentToolDefinition],
    interaction: AgentInteraction? = nil,
    cancellation: AgentCancellation = AgentCancellation(),
    terminal: TerminalGeneration? = nil,
    memoryService: MemoryService? = nil
  ) {
    self.directory = directory
    self.systemPrompt = systemPrompt
    self.mcp = mcp
    self.definitions = definitions
    self.interaction = interaction
    self.cancellation = cancellation
    self.terminal = terminal
    self.memoryService = memoryService
  }

  static func terminal(
    _ runtime: AgentRuntime,
    cancellation: AgentCancellation = AgentCancellation(),
    terminal: TerminalGeneration? = nil,
    memoryService: MemoryService? = nil
  ) -> Self {
    Self(
      directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      systemPrompt: runtime.config.systemPrompt, mcp: MCPClient.shared,
      definitions: ToolRegistry.definitions, interaction: nil,
      cancellation: cancellation, terminal: terminal, memoryService: memoryService)
  }

  func path(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL.path
  }
}

/// One conversation loop shared by terminal, ACP and delegated tasks.
enum AgentTurn {
  static func run(
    runtime: AgentRuntime, messages: inout [AgentMessage],
    context: AgentToolContext, resultLimit: Int = 300, forceLocal: Bool = false
  ) async throws -> String {
    let memoryBootstrap: String
    if let memoryService = context.memoryService {
      if let session = await memoryService.beginSession(
        id: "agent_turn", workspaceOverride: context.directory.path, modelID: nil, tag: nil,
        focus: nil)
      {
        let instructions = await memoryService.instructions(for: session)
        memoryBootstrap = "\n\n" + instructions
      } else {
        memoryBootstrap = ""
      }
    } else {
      memoryBootstrap = ""
    }

    ToolRegistry.resetTurnState()
    runtime.resetToolBudget()
    defer {
      if messages.count > 1, !memoryBootstrap.isEmpty {
        messages[0] = AgentMessage(
          role: .system, content: context.systemPrompt, toolCalls: [], toolCallID: nil, name: nil)
      }
    }
    let maxRounds = forceLocal ? runtime.config.maxRounds : runtime.effectiveMaxRounds
    let result = try await ConversationTurn.run(
      messages: &messages,
      maximumRounds: maxRounds,
      cancellation: context.cancellation,
      generate: { messages in
        var msgs = messages
        if msgs.count > 1, !memoryBootstrap.isEmpty {
          msgs[0] = AgentMessage(
            role: .system, content: context.systemPrompt + memoryBootstrap, toolCalls: [],
            toolCallID: nil, name: nil)
        }
        try context.cancellation.check()
        return try await runtime.generate(
          messages: msgs, tools: context.definitions,
          interaction: context.interaction,
          cancellation: context.cancellation,
          terminal: context.terminal,
          forceLocal: forceLocal)
      },
      execute: { parsedCall in
        try context.cancellation.check()
        // Tool IDs in UI events are unique across generations and subagents.
        let call = ParsedToolCall(
          id: UUID().uuidString, name: parsedCall.name,
          arguments: parsedCall.arguments, argumentsJSON: parsedCall.argumentsJSON)
        if let interaction = context.interaction {
          interaction.tool(call, "pending", nil)
        }
        let result = try await ToolRegistry.execute(call: call, runtime: runtime, context: context)
        if let interaction = context.interaction {
          let failed =
            result.hasPrefix("Error") || result.hasPrefix("Tool call denied")
            || interaction.cancellation.isCancelled
          interaction.tool(call, failed ? "failed" : "completed", result)
        } else {
          AgentTerminal.toolResult(
            header: "\(call.name)(\(call.argumentSummary))",
            result: result, limit: resultLimit)
        }
        try context.cancellation.check()
        return result
      })
    return result
  }
}

protocol ACPBackend: Sendable {
  func newSession(id: String, directory: URL, servers: [String: AgentMCPConfig.ServerConfig])
    async throws -> [String]
  func prompt(session: String, text: String, interaction: AgentInteraction) async throws -> String
}

/// Owns one model/KV lineage. ACPServer admits only one active prompt at a time.
/// Conversations retain independent transcripts, tools, project roots and skills.
actor AgentCore: ACPBackend {
  private struct Session {
    let config: AgentConfig
    let directory: URL
    let skills: [String: URL]
    let serverConfigs: [String: AgentMCPConfig.ServerConfig]

    let memoryService: MemoryService?
    var mcp: MCPClient?
    var definitions: [AgentToolDefinition]?
    var messages: [AgentMessage]
  }
  private let arguments: [String]
  private var sessions: [String: Session] = [:]
  private var runtime: AgentRuntime?
  private var busy = false

  init(arguments: [String]) { self.arguments = arguments }

  func newSession(id: String, directory: URL, servers: [String: AgentMCPConfig.ServerConfig]) throws
    -> [String]
  {
    let config = try AgentConfig(arguments: arguments, workingDirectory: directory)
    let skills = SkillLibrary.discover(roots: [
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills"),
      directory.appendingPathComponent(".agents/skills"),
    ])
    var configured = MCPClient.localConfigurations()
    // Editor-supplied servers replace native entries with the same name.
    configured.merge(servers) { _, supplied in supplied }
    let memoryConfig = MemoryConfiguration.fromEnvironment(ProcessInfo.processInfo.environment)
    let memoryService = MemoryService(configuration: memoryConfig, log: { _ in })
    Task { await memoryService.warmUp() }
    sessions[id] = Session(
      config: config, directory: directory, skills: skills, serverConfigs: configured,
      memoryService: memoryService,
      messages: [
        .init(
          role: .system, content: config.systemPrompt, toolCalls: [], toolCallID: nil, name: nil)
      ])
    return skills.keys.sorted()
  }

  func prompt(session id: String, text: String, interaction: AgentInteraction) async throws
    -> String
  {
    guard !busy else { throw ACPError(code: -32000, message: "Another turn is active") }
    busy = true
    defer { busy = false }
    guard var session = sessions[id] else { throw ACPError.invalid("Unknown session") }
    try interaction.cancellation.check()
    if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/skills" {
      interaction.text(session.skills.keys.sorted().map { "/" + $0 }.joined(separator: "\n"))
      return "end_turn"
    }
    let prompt = try SkillLibrary.expand(text, skills: session.skills)
    if session.definitions == nil {
      let mcp = MCPClient(configurations: session.serverConfigs, directory: session.directory)
      let tools = ToolRegistry.adaptedMCPTools(await mcp.listAllTools())
      try interaction.cancellation.check()
      session.mcp = mcp
      let memDefs = await ToolRegistry.memoryDefinitions(service: session.memoryService)
      session.definitions = ToolRegistry.baseDefinitions + tools + memDefs
    }
    if runtime == nil { runtime = try await AgentRuntime(config: session.config) }
    guard let runtime else { throw ACPError(code: -32603, message: "Runtime unavailable") }
    try interaction.cancellation.check()
    runtime.resetToolBudget()
    let context = AgentToolContext(
      directory: session.directory, systemPrompt: session.config.systemPrompt,
      mcp: session.mcp, definitions: session.definitions ?? [], interaction: interaction,
      cancellation: interaction.cancellation, terminal: nil,
      memoryService: session.memoryService)

    let previousCount = session.messages.count
    session.messages.append(
      .init(role: .user, content: prompt, toolCalls: [], toolCallID: nil, name: nil))
    do {
      _ = try await AgentTurn.run(runtime: runtime, messages: &session.messages, context: context)
      try interaction.cancellation.check()
      sessions[id] = session
      return "end_turn"
    } catch {
      // No invented assistant message if generation did not commit a response.
      if session.messages.count == previousCount + 1 { session.messages.removeLast() }
      if interaction.cancellation.isCancelled || error is CancellationError {
        session.mcp = nil
        session.definitions = nil
      }
      sessions[id] = session
      if interaction.cancellation.isCancelled || error is CancellationError {
        throw CancellationError()
      }
      if case ConversationTurn.TurnError.roundLimit = error { return "max_turn_requests" }
      throw error
    }
  }
}

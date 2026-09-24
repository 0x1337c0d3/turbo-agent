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
  /// The memory session this turn runs in, when one has begun. Set by
  /// `AgentTurn.run`; memory tool calls reuse it so a fact records the
  /// conversation that produced it instead of a shared placeholder.
  var memorySession: MemorySessionContext?
  /// Whether the completed exchange belongs in the conversation journal.
  /// Subagents and consolidation runs borrow the parent's memory session
  /// but their transcripts are machinery, not what was asked and answered.
  var journalsTurn: Bool

  init(
    directory: URL,
    systemPrompt: String,
    mcp: MCPClient?,
    definitions: [AgentToolDefinition],
    interaction: AgentInteraction? = nil,
    cancellation: AgentCancellation = AgentCancellation(),
    terminal: TerminalGeneration? = nil,
    memoryService: MemoryService? = nil,
    memorySession: MemorySessionContext? = nil,
    journalsTurn: Bool = true
  ) {
    self.directory = directory
    self.systemPrompt = systemPrompt
    self.mcp = mcp
    self.definitions = definitions
    self.interaction = interaction
    self.cancellation = cancellation
    self.terminal = terminal
    self.memoryService = memoryService
    self.memorySession = memorySession
    self.journalsTurn = journalsTurn
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
    // The prompt a session opens with, before the memory bootstrap is
    // installed. It is what a later consolidation is shown: the memory
    // fragment is machinery, not a thing worth distilling into a fact.
    let userRequest = messages.last(where: { $0.role == .user })?.content ?? ""
    var memoryBootstrap = ""
    var runningContext = context
    // One continuity session per user request, keyed to the workspace the
    // request runs in, so the journal reads as one conversation and every
    // write is attributed to it.
    if let memoryService = runningContext.memoryService,
      let session = await memoryService.beginSession(
        id: UUID().uuidString, workspaceOverride: runningContext.directory.path,
        modelID: runtime.currentTarget.rawValue, tag: nil, focus: userRequest)
    {
      runningContext.memorySession = session
      let instructions = await memoryService.instructions(for: session)
      memoryBootstrap = "\n\n" + instructions
    }
    let context = runningContext

    ToolRegistry.resetTurnState()
    runtime.resetToolBudget()
    defer {
      if messages.count > 1, !memoryBootstrap.isEmpty {
        messages[0] = AgentMessage(
          role: .system, content: context.systemPrompt, toolCalls: [], toolCallID: nil, name: nil)
      }
    }
    var retrievalBriefing: String?
    var candidatePaths: [String] = []
    if !userRequest.isEmpty {
      let repoIndex = RepositoryIndex.forWorkspace(context.directory)
      let retriever = RepositoryRetriever(index: repoIndex)
      retrievalBriefing = retriever.briefing(for: userRequest)
      let candidates = retriever.rank(query: userRequest)
      candidatePaths = candidates.prefix(6).map(\.path)
    }

    let orchestrationEnabled = runtime.config.orchestrationMode != .never
    let shouldOrchestrate = orchestrationEnabled && (
      runtime.config.orchestrationMode == .always ||
      EditPlanner.shouldOrchestrate(
        request: userRequest, candidatePaths: candidatePaths, workspaceURL: context.directory)
    )

    if shouldOrchestrate {
      do {
        let graph = try await EditPlanner.plan(
          request: userRequest,
          candidatePaths: candidatePaths,
          workspaceURL: context.directory,
          generate: { plannerPrompt in
            let msgs: [AgentMessage] = [
              AgentMessage(role: .system, content: EditPlanner.plannerInstructions, toolCalls: [], toolCallID: nil, name: nil),
              AgentMessage(role: .user, content: plannerPrompt, toolCalls: [], toolCallID: nil, name: nil),
            ]
            let (content, _) = try await runtime.generate(
              messages: msgs, tools: [], interaction: context.interaction,
              cancellation: context.cancellation, terminal: nil, forceLocal: forceLocal)
            return content
          }
        )
        let hasMutatingTasks = graph.tasks.contains(where: {
          $0.kind == .edit || $0.kind == .create || $0.kind == .delete
        })
        guard hasMutatingTasks else {
          throw TaskGraphValidationError.emptyTasks
        }
        let coordinator = PatchCoordinator()
        let result = try await coordinator.execute(
          graph: graph,
          workspaceURL: context.directory,
          runtime: runtime,
          context: context,
          generator: ModelTaskProposalGenerator(runtime: runtime, forceLocal: forceLocal)
        )
        if result.succeeded {
          var telemetry = runtime.latestTelemetry ?? LargeFileEditingTelemetry()
          telemetry.taskSucceeded = true
          telemetry.retrievalCandidates = candidatePaths
          telemetry.executorWaves = graph.waves.count
          runtime.latestTelemetry = telemetry
          if context.journalsTurn,
            let memoryService = context.memoryService, let session = context.memorySession {
            await memoryService.recordTurn(
              session: session, prompt: userRequest, reply: result.summary)
          }
          if isatty(STDOUT_FILENO) == 1 && context.interaction == nil {
            printColor("\n\(result.summary)\n", color: "green")
          }
          return result.summary
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Fall back to direct tool loop if planning or orchestration fails
        var telemetry = runtime.latestTelemetry ?? LargeFileEditingTelemetry()
        telemetry.invalidPlans += 1
        runtime.latestTelemetry = telemetry
      }
    }

    let maxRounds = forceLocal ? runtime.config.maxRounds : runtime.effectiveMaxRounds
    let contextLimit = forceLocal ? 8_192 : runtime.currentTarget.contextLimit(
      fallback: (try? runtime.backend)?.capabilities.maxContextLength ?? 8_192)
    let result = try await ConversationTurn.run(
      messages: &messages,
      maximumRounds: maxRounds,
      cancellation: context.cancellation,
      contextLimit: contextLimit,
      projectMessages: true,
      retrievalBriefing: retrievalBriefing,
      candidatePaths: candidatePaths,
      onWorkingStateUpdate: { [weak runtime] state in
        runtime?.latestTelemetry = state.telemetry
      },
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

    if var telemetry = runtime.latestTelemetry {
      telemetry.taskSucceeded = true
      runtime.latestTelemetry = telemetry
    }

    // The turn is the record, not a side effect of it: prompt, reply and
    // what the session changed. Never on the reply path -- the reply is
    // already owed -- and a journal failure degrades rather than throws.
    // A subagent's or consolidation's exchange is machinery, not a
    // conversation turn, so it is not journaled.
    if context.journalsTurn,
      let memoryService = context.memoryService, let session = context.memorySession {
      await memoryService.recordTurn(
        session: session, prompt: userRequest, reply: result)
    }
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

  /// One diagnostics line to stderr. ACP JSON-RPC and the terminal UI own
  /// stdout, so anything printed there is protocol corruption.
  private static func writeNotice(_ text: String) {
    FileHandle.standardError.write(Data("[memory] \(text)\n".utf8))
  }

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
    // A refusal is visible at start rather than discovered as facts from two
    // projects in one bootstrap.
    // A refusal is visible at start rather than discovered as facts from two
    // projects in one bootstrap. Covers both the configured refusal and a
    // session opened from a directory that is not a project. Stderr, never
    // stdout: ACP frames and the terminal transcript share stdout.
    let refusal = memoryConfig.disabledReason
      ?? MemoryConfiguration.junkDrawerReason(
        forPath: directory.path, environment: ProcessInfo.processInfo.environment)
    if let refusal {
      Self.writeNotice("memory disabled: \(refusal)")
    }
    Task { await memoryService.warmUp(workspaceOverride: directory.path) }
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

import Foundation

/// Stable success wording for both file-writing tools. The new revision is
/// always present (phase 2 contract) so the next edit can anchor on it.
enum AgentWriteResult {
  static func successMessage(
    verb: String, path: String, previousContent: String?, updatedContent: String
  ) -> String {
    var lines = ["Successfully \(verb) \(path)"]
    if let previous = previousContent {
      lines.append("New revision: \(FileRevision.digest(of: updatedContent))")
      lines.append(
        "Previous revision: \(FileRevision.digest(of: previous)) (now stale)")
    } else {
      lines.append("Revision: \(FileRevision.digest(of: updatedContent))")
    }
    return lines.joined(separator: "\n")
  }
}

struct ToolRegistry {
  nonisolated(unsafe) static var definitions: [AgentToolDefinition] = baseDefinitions
  nonisolated(unsafe) static var mcpTools: Set<String> = []
  private static let scratchpadLock = NSLock()
  nonisolated(unsafe) private static var scratchpadInvocations = 0
  private static let searchHistoryLock = NSLock()
  nonisolated(unsafe) private static var consecutiveEmptySearches = 0
  nonisolated(unsafe) private static var lastEmptySearchPath = ""

  static func resetTurnState() {
    scratchpadLock.withLock {
      scratchpadInvocations = 0
    }
    searchHistoryLock.withLock {
      consecutiveEmptySearches = 0
      lastEmptySearchPath = ""
    }
  }
  static let baseDefinitions: [AgentToolDefinition] = [
    AgentToolDefinition(
      name: "web_search",
      description:
        "Searches the web for technical documentation, algorithms, puzzle solutions, or reference articles, returning titles, snippets, and URLs. Use this to discover external concepts, historical solutions, or mathematical algorithms.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "query": .object(["type": .string("string")])
        ]),
        "required": .array([.string("query")]),
      ])
    ),
    AgentToolDefinition(
      name: "read_url",
      description:
        "Fetches the content of a URL and converts the HTML into readable Markdown text.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "url": .object(["type": .string("string")])
        ]),
        "required": .array([.string("url")]),
      ])
    ),
    AgentToolDefinition(
      name: "invoke_subagent",
      description:
        "Spawns a subagent to complete a complex sub-task. Use this to delegate long research or refactoring tasks.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "prompt": .object(["type": .string("string")])
        ]),
        "required": .array([.string("prompt")]),
      ])
    ),
    AgentToolDefinition(
      name: "read_file",
      description:
        "Reads a text file, or a bounded line range of it. Whole-file reads are refused for large files; request mode=outline first, then mode=range with start_line/end_line. Partial results are explicitly labeled with a digest and continuation line.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")]),
          "start_line": .object([
            "type": .string("integer"),
            "description": .string("First line to read, one-based and inclusive."),
          ]),
          "end_line": .object([
            "type": .string("integer"),
            "description": .string("Last line to read, one-based and inclusive; clamped to EOF."),
          ]),
          "mode": .object([
            "type": .string("string"),
            "description": .string(
              "auto (default) returns the whole file only when it fits; otherwise an outline plus a small initial range. range returns only the requested slice. outline returns the section map without source bodies."),
          ]),
        ]),
        "required": .array([.string("path")]),
      ])
    ),
    AgentToolDefinition(
      name: "write_file",
      description:
        "Creates a new file, or replaces an existing file only after a complete read_file of its current revision. Set expected_digest to the digest from that read; range or outline reads do not qualify. Use edit_file for bounded changes.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")]),
          "content": .object(["type": .string("string")]),
          "expected_digest": .object([
            "type": .string("string"),
            "description": .string(
              "For existing files: the digest from a complete read_file of the current revision. Not required when creating a new file."),
          ]),
        ]),
        "required": .array([.string("path"), .string("content")]),
      ])
    ),
    AgentToolDefinition(
      name: "edit_file",
      description:
        "Replaces one exact target string with a replacement string. The target must occur exactly once unless replace_all is true, and expected_digest must match the digest from your most recent read_file of the file. Returns the new revision digest.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")]),
          "target": .object([
            "type": .string("string"),
            "description": .string(
              "Exact source text read from the file; it must occur exactly once unless replace_all is set."),
          ]),
          "replacement": .object(["type": .string("string")]),
          "expected_digest": .object([
            "type": .string("string"),
            "description": .string(
              "The revision digest from read_file, for example sha256:... Fails as staleRevision if the file changed since that read."),
          ]),
          "replace_all": .object([
            "type": .string("boolean"),
            "description": .string(
              "Explicitly replace every occurrence of target. Without it, an ambiguous target fails instead of guessing."),
          ]),
        ]),
        "required": .array([.string("path"), .string("target"), .string("replacement")]),
      ])
    ),
    AgentToolDefinition(
      name: "apply_patch",
      description:
        "Applies multiple non-adjacent anchored replacements to a file atomically against one observed revision. All targets must exist exactly once, must not overlap, and expected_digest must match the file revision. Returns the new revision digest.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object([
            "type": .string("string"),
            "description": .string("Path to the file to patch."),
          ]),
          "expected_digest": .object([
            "type": .string("string"),
            "description": .string(
              "The revision digest from read_file, for example sha256:... Fails as staleRevision if the file changed since that read."),
          ]),
          "hunks": .object([
            "type": .string("array"),
            "description": .string("Array of non-overlapping hunks to apply to the file."),
            "items": .object([
              "type": .string("object"),
              "properties": .object([
                "target": .object([
                  "type": .string("string"),
                  "description": .string("Exact bounded source text to be replaced. Must occur exactly once."),
                ]),
                "replacement": .object([
                  "type": .string("string"),
                  "description": .string("New replacement source text."),
                ]),
              ]),
              "required": .array([.string("target"), .string("replacement")]),
            ]),
          ]),
        ]),
        "required": .array([.string("path"), .string("expected_digest"), .string("hunks")]),
      ])
    ),
    AgentToolDefinition(
      name: "execute_bash",
      description: "Executes a shell command natively",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "command": .object(["type": .string("string")])
        ]),
        "required": .array([.string("command")]),
      ])
    ),
    AgentToolDefinition(
      name: "python_scratchpad",
      description:
        "Executes Python code in an ephemeral scratchpad environment and returns stdout and stderr. Use this to quickly test algorithms, evaluate mathematical expressions, or simulate puzzle state transitions.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "code": .object(["type": .string("string")])
        ]),
        "required": .array([.string("code")]),
      ])
    ),
    AgentToolDefinition(
      name: "list_dir",
      description: "List the contents of a directory.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")])]),
        "required": .array([.string("path")]),
      ])
    ),
    AgentToolDefinition(
      name: "find_by_name",
      description: "Search for files and directories matching specific patterns.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")]),
          "pattern": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("path"), .string("pattern")]),
      ])
    ),
    AgentToolDefinition(
      name: "grep_search",
      description:
        "Searches for exact text substring matches within files or directories. Note: this uses exact substring matching, not regular expressions. To inspect a specific known file, prefer read_file.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object(["type": .string("string")]),
          "query": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("path"), .string("query")]),
      ])
    ),
    AgentToolDefinition(
      name: "analyze_image",
      description:
        "Examine a local image file. The image will be staged and appended to your context for analysis.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")])]),
        "required": .array([.string("path")]),
      ])
    ),
    AgentToolDefinition(
      name: "define_subagent",
      description: "Defines a new type of subagent.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "name": .object(["type": .string("string")]),
          "system_prompt": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("name"), .string("system_prompt")]),
      ])
    ),
    AgentToolDefinition(
      name: "manage_subagents",
      description: "List or kill active subagents.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "action": .object(["type": .string("string")])
        ]),
        "required": .array([.string("action")]),
      ])
    ),
    AgentToolDefinition(
      name: "send_message",
      description: "Communicate with a subagent.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "id": .object(["type": .string("string")]),
          "message": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("id"), .string("message")]),
      ])
    ),
    AgentToolDefinition(
      name: "schedule",
      description: "Set a timer or recurring schedule.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "duration_seconds": .object(["type": .string("integer")]),
          "prompt": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("duration_seconds"), .string("prompt")]),
      ])
    ),
    AgentToolDefinition(
      name: "manage_task",
      description: "Manage background tasks.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "action": .object(["type": .string("string")])
        ]),
        "required": .array([.string("action")]),
      ])
    ),
  ]

  static func memoryDefinitions(service: MemoryService?) async -> [AgentToolDefinition] {
    guard let service = service else { return [] }
    return await service.toolDefinitions().map { def in
      AgentToolDefinition(
        name: def.name,
        description: def.description,
        parameters: try! mapMemorySchema(def.parameters)
      )
    }
  }

  private static func mapMemorySchema(_ schema: MemoryToolSchema) throws -> JSONValue {
    switch schema {
    case .string: return .object(["type": .string("string")])
    case .integer: return .object(["type": .string("integer")])
    case .number: return .object(["type": .string("number")])
    case .stringArray:
      return .object(["type": .string("array"), "items": .object(["type": .string("string")])])
    case .object(let properties, let required):
      var mappedProps: [String: JSONValue] = [:]
      for (key, val) in properties { mappedProps[key] = try mapMemorySchema(val) }
      return .object([
        "type": .string("object"), "properties": .object(mappedProps),
        "required": .array(required.map { .string($0) }),
      ])
    }
  }

  static func adaptedMCPTools(
    _ tools: [AgentToolDefinition],
    reportError: (String) -> Void = { printColor($0 + "\n", color: "yellow") }
  ) -> [AgentToolDefinition] {
    let reservedNames = Set(baseDefinitions.map(\.name))
    return tools.compactMap { tool in
      guard !reservedNames.contains(tool.name) else {
        reportError("Skipping MCP tool \(tool.name): name is reserved by a built-in tool")
        return nil
      }
      guard case .object = tool.parameters else {
        reportError("Skipping MCP tool \(tool.name): input schema must be a JSON object")
        return nil
      }
      return tool
    }
  }

  static func reloadMCPTools(memoryService: MemoryService? = nil) async {
    var newDefs = baseDefinitions
    var newMcpTools = Set<String>()
    if let client = MCPClient.shared {
      let tools = adaptedMCPTools(await client.listAllTools())
      newDefs.append(contentsOf: tools)
      newMcpTools = Set(tools.map { $0.name })
    }
    newDefs.append(contentsOf: await memoryDefinitions(service: memoryService))
    definitions = newDefs
    mcpTools = newMcpTools
  }

  static func isMCPTool(_ name: String, definitions: [AgentToolDefinition]) -> Bool {
    !baseDefinitions.contains(where: { $0.name == name })
      && definitions.contains(where: { $0.name == name })
  }

  static func execute(
    call: ParsedToolCall, runtime: AgentRuntime,
    context suppliedContext: AgentToolContext? = nil
  ) async throws -> String {
    let context = suppliedContext ?? .terminal(runtime)
    try context.cancellation.check()
    guard runtime.remainingToolCalls > 0 else {
      return "Error: tool-call budget exhausted for this user turn"
    }
    runtime.remainingToolCalls -= 1
    let writePlan: AgentWritePlan?
    do {
      writePlan = try await AgentWritePreview.prepare(call: call, context: context)
    } catch {
      return "Error preparing diff preview: \(error)"
    }
    let approved: Bool
    if runtime.config.yolo {
      if let writePlan { ToolApproval.displayDiff(writePlan.diff) }
      approved = true
    } else if call.name == "invoke_subagent" {
      approved = true
    } else if let interaction = context.interaction {
      approved = await interaction.approve(call, writePlan?.diff)
    } else {
      approved = ToolApproval.request(call, diff: writePlan?.diff)
    }
    guard approved else {
      return
        "Tool call denied by the user or unavailable in non-interactive mode. Do not retry without a new user request."
    }
    try context.cancellation.check()
    context.interaction?.tool(call, "in_progress", nil)
    let result: String
    switch call.name {
    case "invoke_subagent":
      result = try await executeInvokeSubagent(call: call, runtime: runtime, context: context)
    case "web_search":
      result = try await executeWebSearch(call: call, context: context)
    case "read_url":
      result = try await executeReadURL(call: call, context: context)
    case "read_file":
      result = try await executeReadFile(call: call, context: context)
    case "write_file":
      result = try await executeWriteFile(call: call, context: context, plan: writePlan)
    case "edit_file":
      result = try await executeEditFile(call: call, context: context, plan: writePlan)
    case "apply_patch":
      result = try await executeApplyPatch(call: call, context: context, plan: writePlan)
    case "execute_bash":
      result = try await executeBash(call: call, context: context)
    case "python_scratchpad":
      result = try await executePythonScratchpad(call: call, context: context)
    case "list_dir":
      result = try await executeListDir(call: call, context: context)
    case "find_by_name":
      result = try await executeFindByName(call: call, context: context)
    case "grep_search":
      result = try await executeGrepSearch(call: call, context: context)
    case "analyze_image":
      result = await executeAnalyzeImage(call: call, context: context)
    case "define_subagent":
      guard let name = call.stringArgument("name"),
        let prompt = call.stringArgument("system_prompt")
      else { return "Error" }
      await AgentManager.shared.defineSubagent(name: name, prompt: prompt)
      result = "Subagent \(name) defined."
    case "manage_subagents":
      result = await AgentManager.shared.listSubagents()
    case "send_message":
      guard let id = call.stringArgument("id"), let msg = call.stringArgument("message") else {
        return "Error"
      }
      result = await AgentManager.shared.sendMessage(id: id, message: msg)
    case "schedule":
      guard let duration = call.intArgument("duration_seconds"),
        let prompt = call.stringArgument("prompt")
      else { return "Error" }
      let id = UUID().uuidString
      await AgentManager.shared.startTask(id: id, description: "Timer for \(duration)s: \(prompt)")
      {
        try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
        print("\n[Timer Fired]: \(prompt)")
      }
      result = "Scheduled task \(id)"
    case "manage_task":
      result = await AgentManager.shared.listTasks()
    default:
      if let memoryService = context.memoryService,
        await memoryService.toolDefinitions().contains(where: { $0.name == call.name })
      {
        // Reuse the turn's session when one is running, so a fact records
        // the conversation that produced it. Fall back only when memory is
        // enabled but the turn began without a session.
        let session: MemorySessionContext?
        if let running = context.memorySession {
          session = running
        } else {
          session = await memoryService.beginSession(
            id: "agent_turn", workspaceOverride: context.directory.path, modelID: nil, tag: nil,
            focus: nil)
        }
        guard let session = session else { return "Error: memory session rejected" }
        do {
          let data = call.argumentsJSON.data(using: .utf8)!
          let dict = try JSONDecoder().decode([String: MemoryToolValue].self, from: data)
          let memResult = await memoryService.execute(name: call.name, arguments: dict, in: session)
          result = memResult.jsonString()
        } catch {
          result = "Error parsing memory tool args: \(error)"
        }
      } else if isMCPTool(call.name, definitions: context.definitions) {
        result = await executeMCP(call: call, mcp: context.mcp)
      } else {
        result = "Error: unknown tool"
      }
    }
    try context.cancellation.check()
    return result
  }

  private static func executeInvokeSubagent(
    call: ParsedToolCall, runtime: AgentRuntime,
    context: AgentToolContext
  ) async throws -> String {
    try context.cancellation.check()
    guard runtime.subagentDepth < 4 else { return "Error: subagent nesting limit reached" }
    runtime.subagentDepth += 1
    defer { runtime.subagentDepth -= 1 }
    var messages = [
      AgentMessage(
        role: .system,
        content: context.systemPrompt
          + "\nYou are a delegated subagent. Return your result clearly.", toolCalls: [],
        toolCallID: nil, name: nil),
      AgentMessage(
        role: .user, content: call.stringArgument("prompt") ?? "", toolCalls: [], toolCallID: nil,
        name: nil),
    ]
    var context = context
    context.journalsTurn = false
    do {
      return try await AgentTurn.run(
        runtime: runtime, messages: &messages, context: context, resultLimit: 200)
    } catch is CancellationError {
      throw CancellationError()
    } catch { return "Error: subagent failed: \(error)" }
  }

  private static func executeMCP(call: ParsedToolCall, mcp: MCPClient?) async -> String {
    guard let mcp else { return "Error: MCP Client not initialized" }
    guard let argsData = try? JSONEncoder().encode(call.arguments),
      let argsJson = String(data: argsData, encoding: .utf8)
    else {
      return "Error: invalid MCP arguments"
    }
    return await mcp.callTool(name: call.name, argsJson: argsJson)
  }

  private static func executeWebSearch(call: ParsedToolCall, context: AgentToolContext) async throws
    -> String
  {
    try context.cancellation.check()
    guard let query = call.stringArgument("query"),
      let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    else {
      return "Error: invalid arguments: 'query' required"
    }

    var results: [String] = []

    // 1. DuckDuckGo Instant Answers
    if let ddgURL = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json") {
      try context.cancellation.check()
      if let (data, _) = try? await URLSession.shared.data(from: ddgURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        if let heading = json["Heading"] as? String, !heading.isEmpty,
          let abstract = json["AbstractText"] as? String, !abstract.isEmpty
        {
          let url = json["AbstractURL"] as? String ?? ""
          results.append("### \(heading)\n\(abstract)\nURL: \(url)")
        }
      }
    }

    // 2. Wikipedia Search API
    if let wikiURL = URL(
      string:
        "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&format=json&utf8=1"
    ) {
      try context.cancellation.check()
      var request = URLRequest(url: wikiURL)
      request.setValue("TurboAgent/1.0", forHTTPHeaderField: "User-Agent")
      if let (data, _) = try? await URLSession.shared.data(for: request),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let queryObj = json["query"] as? [String: Any],
        let searchList = queryObj["search"] as? [[String: Any]]
      {
        for item in searchList.prefix(4) {
          if let title = item["title"] as? String,
            let snippetRaw = item["snippet"] as? String
          {
            let snippet = snippetRaw.replacingOccurrences(
              of: "<[^>]+>", with: "", options: .regularExpression
            )
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            let pageURL =
              "https://en.wikipedia.org/wiki/"
              + (title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)
            results.append("### \(title)\n\(snippet)...\nURL: \(pageURL)")
          }
        }
      }
    }

    try context.cancellation.check()
    guard !results.isEmpty else {
      return "No web search results found for '\(query)'."
    }

    return results.joined(separator: "\n\n")
  }

  private static func executeReadURL(call: ParsedToolCall, context: AgentToolContext) async throws
    -> String
  {
    try context.cancellation.check()
    guard let urlString = call.stringArgument("url"), let url = URL(string: urlString) else {
      return "Error: invalid URL"
    }
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      try context.cancellation.check()
      guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode)
      else {
        return "Error: Bad HTTP response"
      }
      guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
      else {
        return "Error: Unable to decode text"
      }
      return ReadableHTML.text(from: html)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error fetching URL: \(error)"
    }
  }

  private static func executeReadFile(call: ParsedToolCall, context: AgentToolContext) async throws
    -> String
  {
    try context.cancellation.check()
    guard let path = call.stringArgument("path") else { return "Error: invalid arguments" }
    let resolved = context.path(path)
    do {
      if let large = try await executeLargeFileRead(
        call: call, path: path, resolvedPath: resolved, context: context)
      {
        return large
      }
      let content = try await readFile(resolved, context: context)
      // Legacy whole-file path: one complete read of the current revision.
      recordRead(resolvedPath: resolved, content: content, complete: true)
      return content
    } catch let error as FileSlicerError {
      return "Error: \(error.description)"
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error reading file: \(error)"
    }
  }

  /// Phase 2: complete reads feed the whole-file-replacement ledger. The
  /// resolved path keys the store, never the model-authored path string.
  private static func recordRead(resolvedPath: String, content: String, complete: Bool) {
    ReadRevisionLedger.shared.record(
      resolvedPath: resolvedPath, digest: FileRevision.digest(of: content),
      byteCount: content.utf8.count, complete: complete)
  }

  private static func executeWriteFile(
    call: ParsedToolCall, context: AgentToolContext, plan: AgentWritePlan?
  ) async throws -> String {
    try context.cancellation.check()
    guard let plan else { return "No-op: the replacement content is identical to the existing file; no write was performed." }
    do {
      if plan.originalContent == nil {
        // The creation path still confirms the target did not appear while
        // the diff awaited approval.
        try await AgentWritePreview.verifyCreationIsStillNew(
          plan.resolvedPath, context: context)
      }
      try await plan.verifySourceIsUnchanged(context: context)
      try await writeFile(plan.resolvedPath, content: plan.updatedContent, context: context)
      RepositoryIndex.forWorkspace(context.directory).refresh(resolvedPath: plan.resolvedPath)
      return AgentWriteResult.successMessage(
        verb: "wrote", path: plan.path, previousContent: plan.originalContent,
        updatedContent: plan.updatedContent)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error writing file: \(error)"
    }
  }

  private static func executeEditFile(
    call: ParsedToolCall, context: AgentToolContext, plan: AgentWritePlan?
  ) async throws -> String {
    try context.cancellation.check()
    guard let plan else { return "No-op: the replacement content is identical to the existing file; no write was performed." }
    do {
      try await plan.verifySourceIsUnchanged(context: context)
      try await writeFile(plan.resolvedPath, content: plan.updatedContent, context: context)
      RepositoryIndex.forWorkspace(context.directory).refresh(resolvedPath: plan.resolvedPath)
      return AgentWriteResult.successMessage(
        verb: "updated", path: plan.path, previousContent: plan.originalContent,
        updatedContent: plan.updatedContent)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error editing file: \(error)"
    }
  }

  private static func executeApplyPatch(
    call: ParsedToolCall, context: AgentToolContext, plan: AgentWritePlan?
  ) async throws -> String {
    try context.cancellation.check()
    guard let plan else {
      return "No-op: the replacement content is identical to the existing file; no write was performed."
    }
    do {
      try await plan.verifySourceIsUnchanged(context: context)
      try await writeFile(plan.resolvedPath, content: plan.updatedContent, context: context)
      RepositoryIndex.forWorkspace(context.directory).refresh(resolvedPath: plan.resolvedPath)
      let validation = validateWholeFile(path: plan.resolvedPath, content: plan.updatedContent)
      var message = AgentWriteResult.successMessage(
        verb: "patched", path: plan.path, previousContent: plan.originalContent,
        updatedContent: plan.updatedContent)
      if !validation.isEmpty {
        message += "\n" + validation
      }
      return message
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error applying patch: \(error)"
    }
  }

  static func validateWholeFile(path: String, content: String) -> String {
    guard let reread = try? String(contentsOfFile: path, encoding: .utf8), reread == content else {
      return "[Validation Warning: written file could not be reread cleanly as UTF-8]"
    }
    let sections = FileOutlineBuilder.sections(of: content, path: path)
    let declCount = sections.filter { $0.kind != "block" }.count

    let ext = (path as NSString).pathExtension.lowercased()
    var syntaxNotes: [String] = []
    if ["swift", "c", "h", "cpp", "cc", "hpp", "js", "ts", "json"].contains(ext) {
      var braces = 0
      var brackets = 0
      var parens = 0
      for char in content {
        switch char {
        case "{": braces += 1
        case "}": braces -= 1
        case "[": brackets += 1
        case "]": brackets -= 1
        case "(": parens += 1
        case ")": parens -= 1
        default: break
        }
      }
      if braces != 0 { syntaxNotes.append("unbalanced braces (net: \(braces))") }
      if brackets != 0 { syntaxNotes.append("unbalanced brackets (net: \(brackets))") }
      if parens != 0 { syntaxNotes.append("unbalanced parentheses (net: \(parens))") }
    }

    if !syntaxNotes.isEmpty {
      return "[Validation Warning: \(syntaxNotes.joined(separator: ", "))]"
    }
    return "[Validation: UTF-8 verified; outline regenerated with \(declCount) declarations]"
  }

  private static func readFile(_ path: String, context: AgentToolContext) async throws -> String {
    try context.cancellation.check()
    if let read = context.interaction?.readFile { return try await read(path) }
    return try String(contentsOfFile: path, encoding: .utf8)
  }

  /// Phase 1 of docs/LARGE_FILE_EDITING.md: revisioned line-range reads with
  /// deterministic outlines. ACP client reads stay intact; slicing happens
  /// after the client returns content.
  private static func executeLargeFileRead(
    call: ParsedToolCall, path: String, resolvedPath: String, context: AgentToolContext
  ) async throws -> String? {
    guard let request = LargeFileRead.Request(arguments: call.arguments) else { return nil }
    // ACP client reads stay intact; slicing happens after the client returns.
    let raw = try await readFile(resolvedPath, context: context)
    return try LargeFileRead.render(request: request, content: raw, path: path) { sliceComplete in
      // Only an unlabeled complete read authorizes whole-file replacement.
      recordRead(resolvedPath: resolvedPath, content: raw, complete: sliceComplete)
    }
  }

  static func writeFile(_ path: String, content: String, context: AgentToolContext)
    async throws
  {
    try context.cancellation.check()
    if let write = context.interaction?.writeFile {
      try await write(path, content)
      return
    }
    try content.write(toFile: path, atomically: true, encoding: .utf8)
  }

  private static func executeBash(call: ParsedToolCall, context: AgentToolContext) async throws
    -> String
  {
    try context.cancellation.check()
    let commandCandidate =
      call.stringArgument("command")
      ?? call.stringArgument("cmd")
      ?? call.stringArgument("command_line")
      ?? call.stringArgument("arguments")
    let command: String
    if let cmd = commandCandidate {
      command = cmd
    } else if case .object(let dict) = call.arguments,
      case .array(let arr) = dict["arguments"]
    {
      command = arr.compactMap {
        if case .string(let s) = $0 { return s } else { return nil }
      }.joined(separator: " ")
    } else {
      return "Error: invalid arguments"
    }
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: #"(?i)cat\s*<<\s*\\?['"]?[A-Za-z0-9_]+['"]?"#, options: .regularExpression)
      != nil
    {
      return
        "Error: Creating or modifying files using shell heredocs ('cat <<EOF') is prohibited because it causes quote-escaping and string syntax errors. Please use the dedicated 'write_file' tool (or 'edit_file') with the file path and content directly."
    }
    do {
      let output = try await ShellCommand.run(
        command, directory: context.directory, cancellation: context.cancellation)
      let maxOutputChars = 2_500
      guard output.count > maxOutputChars else { return output }
      let head = String(output.prefix(600))
      let tail = String(output.suffix(1_800))
      return head
        + "\n... (output truncated: \(output.count) characters too large for context window. please use grep, head, or tail to narrow it down)\n..."
        + tail
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error: \(error)"
    }
  }

  private static func executePythonScratchpad(call: ParsedToolCall, context: AgentToolContext)
    async throws
    -> String
  {
    try context.cancellation.check()
    guard let code = call.stringArgument("code") else {
      return "Error: invalid arguments: 'code' string required"
    }
    let count = scratchpadLock.withLock {
      scratchpadInvocations += 1
      return scratchpadInvocations
    }
    do {
      let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(
        "scratchpad_\(UUID().uuidString).py")
      try code.write(to: tempFile, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: tempFile) }
      let rawOutput = try await ShellCommand.run(
        "python3 \"\(tempFile.path)\"", directory: context.directory,
        cancellation: context.cancellation)
      let baseOutput: String
      if rawOutput.count > 2_500 {
        let head = String(rawOutput.prefix(600))
        let tail = String(rawOutput.suffix(1_800))
        baseOutput = head + "\n... (output truncated)\n..." + tail
      } else {
        baseOutput = rawOutput.isEmpty ? "(Executed successfully with no output)" : rawOutput
      }
      var notice =
        "\n\n[Sandbox note: Code executed in python_scratchpad is ephemeral and NOT saved to disk. To persist code or changes to the project, use `write_file`.]"
      if count >= 3 {
        notice +=
          "\n[Notice: You have used python_scratchpad \(count) times. Avoid endless simulation loops; proceed to implement and verify your solution in the workspace.]"
      }
      return baseOutput + notice
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error executing scratchpad: \(error)"
    }
  }

  private static func executeListDir(call: ParsedToolCall, context: AgentToolContext) async throws
    -> String
  {
    try context.cancellation.check()
    guard let path = call.stringArgument("path") else { return "Error: invalid arguments" }
    do {
      let contents = try FileManager.default.contentsOfDirectory(atPath: context.path(path))
      return contents.joined(separator: "\n")
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error listing directory: \(error)"
    }
  }

  private static func executeFindByName(call: ParsedToolCall, context: AgentToolContext)
    async throws
    -> String
  {
    try context.cancellation.check()
    guard let path = call.stringArgument("path"), let pattern = call.stringArgument("pattern")
    else { return "Error: invalid arguments" }
    do {
      let output = try await ShellCommand.run(
        "find \"\(context.path(path))\" -name \"\(pattern)\"", directory: context.directory,
        cancellation: context.cancellation)
      return output.isEmpty ? "No files found matching \(pattern)" : output
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error finding files: \(error)"
    }
  }

  private static func executeGrepSearch(call: ParsedToolCall, context: AgentToolContext)
    async throws
    -> String
  {
    try context.cancellation.check()
    guard let path = call.stringArgument("path"), let query = call.stringArgument("query") else {
      return "Error: invalid arguments"
    }
    // Use -F (fixed string) so special characters like [ ] don't cause regex errors.
    // Wrap in `sh -c '... ; exit 0'` so grep's exit 1 (no matches) doesn't trigger
    // ShellCommand's [Exit status: N] annotation — exit 1 is not an error.
    let absPath = context.path(path)
    // Shell-escape single quotes in path.
    let safePath = absPath.replacingOccurrences(of: "'", with: "'\\''")
    // Shell-escape single quotes in query.
    let safeQuery = query.replacingOccurrences(of: "'", with: "'\\''")
    let command = "grep -rInF '\(safeQuery)' '\(safePath)' || true"
    do {
      let raw = try await ShellCommand.run(
        command, directory: context.directory,
        cancellation: context.cancellation)
      // Strip any residual [Exit status: N] trailer.
      let lines = raw.components(separatedBy: "\n").filter {
        !$0.hasPrefix("[Exit status:") && !$0.hasPrefix("[Output truncated")
      }
      let trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        let count = searchHistoryLock.withLock {
          if lastEmptySearchPath == path {
            consecutiveEmptySearches += 1
          } else {
            lastEmptySearchPath = path
            consecutiveEmptySearches = 1
          }
          return consecutiveEmptySearches
        }
        var msg = "No matches found for '\(query)' in \(path)."
        if count >= 3 {
          msg +=
            "\n\n[Notice: You have performed \(count) consecutive searches with no matches in \(path). Do not loop with repeated grep queries. Use 'read_file' to examine the target file directly, or proceed to implement your edit.]"
        } else {
          msg +=
            " (Note: grep_search uses exact substring matching. If you are searching in a single file, use 'read_file' to view its contents directly.)"
        }
        return msg
      }
      searchHistoryLock.withLock {
        consecutiveEmptySearches = 0
        lastEmptySearchPath = ""
      }
      guard trimmed.count <= 8192 else {
        return String(trimmed.prefix(8192)) + "\n... (output truncated)"
      }
      return trimmed
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return "Error running grep: \(error)"
    }
  }

  private static func executeAnalyzeImage(call: ParsedToolCall, context: AgentToolContext) async
    -> String
  {
    guard let path = call.stringArgument("path") else { return "Error: invalid arguments" }
    // For the CLI context, we need to instruct the runtime to stage the image.
    // Since TurboAgent doesn't natively hold the StagedImage context here,
    // we emit a system directive that the image is staged if running in App,
    // or print a local warning.
    return "Image at \(path) staged for analysis. Instruct the user to view or describe it."
  }
}

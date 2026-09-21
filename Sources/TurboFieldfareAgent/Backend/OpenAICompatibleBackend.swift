import Foundation

public enum OpenAIBackendError: Error, CustomStringConvertible {
  case missingConfiguration(String)

  public var description: String {
    switch self {
    case .missingConfiguration(let msg): return msg
    }
  }
}

final class OpenAICompatibleBackend: InferenceBackend, @unchecked Sendable {
  var capabilities: BackendCapabilities
  let client: OpenAIClient
  private let statusLine: AgentStatusLine

  init(client: OpenAIClient? = OpenAIClient(), statusLine: AgentStatusLine? = nil) throws {
    guard let client else {
      throw OpenAIBackendError.missingConfiguration(
        "OpenAI configuration not found in ~/.config/TurboFieldfareAgent/settings.json or OPENAI_API_KEY environment variable is unset."
      )
    }
    self.client = client
    self.statusLine = statusLine ?? AgentStatusLine()
    let initialLength =
      client.cachedContextLength ?? client.fallbackContextLength(for: client.modelName)
    self.capabilities = BackendCapabilities(
      name: "OpenAI Compatible Cloud (\(client.modelName))",
      supportsTools: true,
      supportsStreaming: false,
      maxContextLength: initialLength,
      isOnDevice: false,
      isPrivateCloudCompute: false
    )
  }

  @discardableResult
  func updateContextLength() async -> Int {
    if let len = await client.fetchModelContextLength() {
      self.capabilities = BackendCapabilities(
        name: "OpenAI Compatible Cloud (\(client.modelName))",
        supportsTools: true,
        supportsStreaming: false,
        maxContextLength: len,
        isOnDevice: false,
        isPrivateCloudCompute: false
      )
      self.statusLine.snapshot.maxContext = len
      self.statusLine.refresh(force: true)
      return len
    }
    return capabilities.maxContextLength
  }

  func generate(
    messages: [AgentMessage],
    tools: [AgentToolDefinition]?,
    interaction: AgentInteraction?
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    try await generate(
      messages: messages, tools: tools, interaction: interaction,
      cancellation: nil, terminal: nil)
  }

  func generate(
    messages: [AgentMessage],
    tools: [AgentToolDefinition]?,
    interaction: AgentInteraction?,
    cancellation: AgentCancellation?,
    terminal: TerminalGeneration?
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    let effectiveCancellation = interaction?.cancellation ?? cancellation ?? AgentCancellation()
    let activeTerminal: TerminalGeneration?
    let ownsTerminal: Bool
    if interaction == nil {
      if let terminal {
        activeTerminal = terminal
        ownsTerminal = false
        terminal.beginGeneration()
      } else {
        activeTerminal = TerminalGeneration(cancellation: effectiveCancellation)
        ownsTerminal = true
      }
    } else {
      activeTerminal = nil
      ownsTerminal = false
    }
    defer {
      if ownsTerminal { activeTerminal?.restore() }
    }

    let effectiveInstructions = AgentContextAssembler.effectiveInstructions(
      in: messages, fallback: "")
    let budgetedPromptTokens =
      (try? AgentContextAssembler.prepare(
        messages: messages, systemPrompt: effectiveInstructions, tools: tools ?? [],
        contextLimit: capabilities.maxContextLength))?.budget.promptTokens
      ?? messages.reduce(0) { total, msg in
        total + AgentContextAssembler.estimateTokens(msg.content ?? "") + 6
      }

    if interaction == nil {
      statusLine.beginGeneration(contextTokens: budgetedPromptTokens)
    }

    if client.cachedContextLength == nil {
      await updateContextLength()
    }

    try effectiveCancellation.check()

    let start = ProcessInfo.processInfo.systemUptime
    let result: (content: String, calls: [ParsedToolCall], usage: OpenAIResponse.Usage?)
    do {
      let task = Task {
        try await client.generate(messages: messages, tools: tools)
      }
      effectiveCancellation.onCancel {
        task.cancel()
      }
      result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch is CancellationError {
      await activeTerminal?.finishGeneration()
      throw CancellationError()
    } catch {
      await activeTerminal?.finishGeneration()
      if interaction == nil {
        statusLine.snapshot.phase = "Error"
        statusLine.refresh(force: true)
      }
      throw error
    }

    let decodeSeconds = ProcessInfo.processInfo.systemUptime - start
    await activeTerminal?.finishGeneration()
    let completionTokens = result.usage?.completionTokens ?? max(1, result.content.count / 4)
    let totalTokens = result.usage?.totalTokens ?? (budgetedPromptTokens + completionTokens)
    if interaction == nil {
      statusLine.finish(
        tokens: completionTokens, decodeSeconds: decodeSeconds, contextTokens: totalTokens)
    }

    if effectiveCancellation.isCancelled || Task.isCancelled {
      throw CancellationError()
    }

    if let interaction {
      if !result.content.isEmpty {
        interaction.text(result.content)
      }
    } else {
      if !result.content.isEmpty {
        terminalPrint(TerminalText.safe(result.content))
      }
    }
    return (result.content, result.calls)
  }
}

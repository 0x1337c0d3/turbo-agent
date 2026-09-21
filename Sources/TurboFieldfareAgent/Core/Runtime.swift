import Foundation

enum AgentRuntimeError: Error, CustomStringConvertible {
  case noAvailableBackend
  var description: String {
    "No inference backend is available. Configure OPENAI_API_KEY or run on a system with Apple Foundation Models."
  }
}

final class AgentRuntime: @unchecked Sendable {
  let config: AgentConfig
  var appleBackend: AppleFoundationModelBackend?
  var openAIBackend: OpenAICompatibleBackend?
  let statusLine = AgentStatusLine()
  var remainingToolCalls = 64
  var subagentDepth = 0
  var activeBackendKind: AgentBackendKind

  public enum ModelTarget: String, Sendable, CaseIterable {
    case appleAutomatic = "apple"
    case appleOnDevice = "apple-local"
    case appleCloud = "apple-pcc"
    case openai

    public var label: String {
      switch self {
      case .appleAutomatic: return "Apple AFM 3 (Automatic)"
      case .appleOnDevice: return "Apple AFM 3 Core (On-Device)"
      case .appleCloud: return "Apple AFM Cloud Pro (Private Cloud Compute)"
      case .openai: return "OpenAI-compatible API"
      }
    }

    public var isLocal: Bool { self == .appleOnDevice }

    func contextLimit(fallback: Int) -> Int {
      switch self {
      case .appleAutomatic, .appleOnDevice: return 8_192
      case .appleCloud: return 32_768
      case .openai: return fallback
      }
    }
  }

  var currentTarget: ModelTarget {
    switch activeBackendKind {
    case .apple:
      switch applePCCPolicy {
      case .auto: return .appleAutomatic
      case .disable: return .appleOnDevice
      case .require: return .appleCloud
      }
    case .openai: return .openai
    }
  }

  var availableTargets: [ModelTarget] {
    var targets: [ModelTarget] = []
    if appleBackend != nil { targets += [.appleAutomatic, .appleOnDevice, .appleCloud] }
    if openAIBackend != nil { targets.append(.openai) }
    return targets
  }

  var backend: any InferenceBackend {
    get throws {
      switch activeBackendKind {
      case .apple: if let appleBackend { return appleBackend }
      case .openai: if let openAIBackend { return openAIBackend }
      }
      if let appleBackend { return appleBackend }
      if let openAIBackend { return openAIBackend }
      throw AgentRuntimeError.noAvailableBackend
    }
  }

  var applePCCPolicy: PCCPolicy {
    get { appleBackend?.pccPolicy ?? config.pccPolicy }
    set { appleBackend?.pccPolicy = newValue }
  }

  var effectiveMaxRounds: Int {
    if let explicit = config.explicitMaxRounds { return explicit }
    return currentTarget.isLocal ? config.maxRounds : Int.max
  }

  func resetToolBudget() {
    remainingToolCalls = effectiveMaxRounds == Int.max ? Int.max : max(64, effectiveMaxRounds * 2)
  }

  init(config: AgentConfig) async throws {
    self.config = config
    activeBackendKind = config.backend
    #if canImport(FoundationModels)
      if #available(macOS 27.0, *) {
        appleBackend = AppleFoundationModelBackend(
          pccPolicy: config.pccPolicy, systemPrompt: config.systemPrompt, statusLine: statusLine)
      }
    #endif
    if let client = OpenAIClient() {
      openAIBackend = try? OpenAICompatibleBackend(client: client, statusLine: statusLine)
    }
    if activeBackendKind == .apple, appleBackend == nil { activeBackendKind = .openai }
    if activeBackendKind == .openai, openAIBackend == nil, appleBackend != nil {
      activeBackendKind = .apple
    }
    guard !availableTargets.isEmpty else { throw AgentRuntimeError.noAvailableBackend }
    switchTo(target: currentTarget)
  }

  func switchTo(target: ModelTarget) {
    switch target {
    case .appleAutomatic:
      activeBackendKind = .apple
      applePCCPolicy = .auto
      statusLine.snapshot.maxContext = target.contextLimit(fallback: 8_192)
      statusLine.snapshot.modelLabel = "AFM Auto"
    case .appleOnDevice:
      activeBackendKind = .apple
      applePCCPolicy = .disable
      statusLine.snapshot.maxContext = target.contextLimit(fallback: 8_192)
      statusLine.snapshot.modelLabel = "AFM On-Device"
    case .appleCloud:
      activeBackendKind = .apple
      applePCCPolicy = .require
      statusLine.snapshot.maxContext = target.contextLimit(fallback: 32_768)
      statusLine.snapshot.modelLabel = "AFM Cloud (PCC)"
    case .openai:
      activeBackendKind = .openai
      statusLine.snapshot.maxContext = openAIBackend?.capabilities.maxContextLength ?? 128_000
      statusLine.snapshot.modelLabel = openAIBackend?.client.modelName ?? "OpenAI"
      if let openAIBackend {
        Task {
          _ = await openAIBackend.updateContextLength()
          if self.currentTarget == .openai {
            self.statusLine.snapshot.maxContext = openAIBackend.capabilities.maxContextLength
          }
        }
      }
    }
    statusLine.refresh(force: true)
    resetToolBudget()
  }

  func generate(
    messages: [AgentMessage], tools: [AgentToolDefinition]? = nil,
    interaction: AgentInteraction? = nil, cancellation: AgentCancellation? = nil,
    terminal: TerminalGeneration? = nil, forceLocal: Bool = false
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    let activeTools = tools ?? ToolRegistry.definitions
    let selectedBackend: any InferenceBackend
    let contextLimit: Int
    if forceLocal, let appleBackend {
      let previousPolicy = appleBackend.pccPolicy
      appleBackend.pccPolicy = .disable
      defer { appleBackend.pccPolicy = previousPolicy }
      selectedBackend = appleBackend
      contextLimit = 8_192
    } else {
      selectedBackend = try backend
      contextLimit = currentTarget.contextLimit(
        fallback: selectedBackend.capabilities.maxContextLength)
    }

    let effectiveInstructions = AgentContextAssembler.effectiveInstructions(
      in: messages, fallback: config.systemPrompt)
    let prepared = try AgentContextAssembler.prepare(
      messages: messages, systemPrompt: effectiveInstructions, tools: activeTools,
      contextLimit: contextLimit)
    statusLine.setContextBudget(prepared.budget)

    return try await selectedBackend.generate(
      messages: prepared.messages, tools: activeTools, interaction: interaction,
      cancellation: cancellation, terminal: terminal)
  }
}

import Foundation

/// Conservative, model-independent accounting for an agent generation request.
///
/// Apple Foundation Models does not expose its tokenizer, so this estimator uses
/// UTF-8 size with a three-byte-per-token divisor and fixed framing costs. The
/// safety margin absorbs tokenizer and provider framing differences.
struct AgentContextBudget: Sendable, Equatable {
  let contextLimit: Int
  let reservedOutputTokens: Int
  let safetyMarginTokens: Int
  let instructionTokens: Int
  let toolTokens: Int
  let messageTokens: Int
  let droppedMessageCount: Int
  /// Number of tool results compacted to receipts by the projection layer.
  let compactedObservationCount: Int
  /// Number of complete tool exchange groups evicted by the projection layer.
  let evictedGroupCount: Int
  /// Estimated prompt tokens saved by compaction and eviction.
  let estimatedTokensSaved: Int

  init(
    contextLimit: Int,
    reservedOutputTokens: Int,
    safetyMarginTokens: Int,
    instructionTokens: Int,
    toolTokens: Int,
    messageTokens: Int,
    droppedMessageCount: Int,
    compactedObservationCount: Int = 0,
    evictedGroupCount: Int = 0,
    estimatedTokensSaved: Int = 0
  ) {
    self.contextLimit = contextLimit
    self.reservedOutputTokens = reservedOutputTokens
    self.safetyMarginTokens = safetyMarginTokens
    self.instructionTokens = instructionTokens
    self.toolTokens = toolTokens
    self.messageTokens = messageTokens
    self.droppedMessageCount = droppedMessageCount
    self.compactedObservationCount = compactedObservationCount
    self.evictedGroupCount = evictedGroupCount
    self.estimatedTokensSaved = estimatedTokensSaved
  }

  var promptTokens: Int { instructionTokens + toolTokens + messageTokens }
  var usablePromptTokens: Int {
    max(0, contextLimit - reservedOutputTokens - safetyMarginTokens)
  }
  var fits: Bool { promptTokens <= usablePromptTokens }
}

struct PreparedAgentContext: Sendable, Equatable {
  let messages: [AgentMessage]
  let budget: AgentContextBudget
}

enum AgentContextBudgetError: Error, CustomStringConvertible, Equatable {
  case invalidContextLimit(Int)
  case newestTurnTooLarge(required: Int, available: Int)

  var description: String {
    switch self {
    case .invalidContextLimit(let limit):
      return "Invalid model context limit: \(limit)."
    case .newestTurnTooLarge(let required, let available):
      return
        "The current request needs approximately \(required) prompt tokens, but only \(available) are available after reserving output and a safety margin. Attach less context or start a new request."
    }
  }
}

enum AgentContextAssembler {
  static func effectiveInstructions(in messages: [AgentMessage], fallback: String) -> String {
    let supplied = messages.prefix {
      $0.role == .system || $0.role == .developer
    }.compactMap(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
    return supplied.isEmpty ? fallback : supplied
  }

  /// Prepares a request by removing complete oldest turns until it fits.
  /// System/developer messages and the newest user turn are never removed.
  static func prepare(
    messages: [AgentMessage], systemPrompt: String, tools: [AgentToolDefinition],
    contextLimit: Int,
    compactedObservationCount: Int? = nil,
    evictedGroupCount: Int? = nil,
    estimatedTokensSaved: Int? = nil
  ) throws -> PreparedAgentContext {
    guard contextLimit > 0 else {
      throw AgentContextBudgetError.invalidContextLimit(contextLimit)
    }

    // An 8K agent needs enough prompt room for its standing instructions and
    // tool catalogue. Reserve 1K there; larger backends can afford a wider
    // response without starving the request itself.
    let reservedOutput =
      contextLimit <= 8_192 ? 1_024 : min(4_096, max(2_048, contextLimit / 8))
    let safetyMargin = max(256, contextLimit / 16)
    let instructionTokens = estimateTokens(systemPrompt) + 8
    let toolTokens = tools.reduce(0) { $0 + estimateTokens($1) }
    let available = max(0, contextLimit - reservedOutput - safetyMargin)

    var selected = messages
    var dropped = 0
    let compactedCount = compactedObservationCount ?? selected.filter {
      $0.role == .tool && ($0.content?.hasPrefix("[receipt") == true)
    }.count
    let evictedCount = evictedGroupCount ?? 0
    let savedTokens = estimatedTokensSaved ?? 0
    while true {
      let pinnedEnd = selected.prefix { $0.role == .system || $0.role == .developer }.count
      let messageTokens = selected.dropFirst(pinnedEnd).reduce(0) { $0 + estimateTokens($1) }
      let budget = AgentContextBudget(
        contextLimit: contextLimit,
        reservedOutputTokens: reservedOutput,
        safetyMarginTokens: safetyMargin,
        instructionTokens: instructionTokens,
        toolTokens: toolTokens,
        messageTokens: messageTokens,
        droppedMessageCount: dropped,
        compactedObservationCount: compactedCount,
        evictedGroupCount: evictedCount,
        estimatedTokensSaved: savedTokens)
      if budget.fits {
        return PreparedAgentContext(messages: selected, budget: budget)
      }
      guard let trimmed = dropOldestCompleteTurn(from: selected) else {
        throw AgentContextBudgetError.newestTurnTooLarge(
          required: budget.promptTokens, available: available)
      }
      dropped += selected.count - trimmed.count
      selected = trimmed
    }
  }

  /// Conservative approximation shared by budgeting and AFM telemetry.
  static func estimateTokens(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, (text.utf8.count + 2) / 3)
  }

  private static func estimateTokens(_ message: AgentMessage) -> Int {
    var total = 6
    if message.role != .assistant || message.toolCalls.isEmpty {
      total += estimateTokens(message.content ?? "")
    }
    total += estimateTokens(message.toolCallID ?? "")
    total += estimateTokens(message.name ?? "")
    for call in message.toolCalls {
      total += 8 + estimateTokens(call.name)
      if let encoded = try? call.arguments.encoded() {
        total += estimateTokens(encoded)
      }
    }
    return total
  }

  private static func estimateTokens(_ tool: AgentToolDefinition) -> Int {
    var total = 12 + estimateTokens(tool.name) + estimateTokens(tool.description)
    if let encoded = try? tool.parameters.encoded() {
      total += estimateTokens(encoded)
    }
    return total
  }

  private static func dropOldestCompleteTurn(from messages: [AgentMessage]) -> [AgentMessage]? {
    let pinnedEnd = messages.prefix { $0.role == .system || $0.role == .developer }.count
    let userIndices = messages.indices.filter { $0 >= pinnedEnd && messages[$0].role == .user }
    guard userIndices.count >= 2 else { return nil }
    let nextTurn = userIndices[1]
    return Array(messages[..<pinnedEnd]) + Array(messages[nextTurn...])
  }
}

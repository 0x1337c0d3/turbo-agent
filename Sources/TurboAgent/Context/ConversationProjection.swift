import Foundation

/// The result of projecting the full message list before a model generation.
///
/// `messages` is a new array suitable for passing to the backend — canonical
/// messages are never mutated. Telemetry fields let the caller update status
/// and propagate to the context budget.
struct ProjectionResult: Sendable {
  let messages: [AgentMessage]
  let compactedCount: Int
  let evictedGroupCount: Int
  /// Call IDs whose source reads were evicted; callers should revoke whole-file
  /// replacement eligibility for those paths in `ReadRevisionLedger`.
  let revokedReadCallIDs: [String]
  let promptTokensBefore: Int
  let promptTokensAfter: Int
  let estimatedTokensSaved: Int
  let fullObservationsCount: Int
  let fullObservationsBytes: Int
  let compactedObservationsBytes: Int

  init(
    messages: [AgentMessage],
    compactedCount: Int,
    evictedGroupCount: Int,
    revokedReadCallIDs: [String],
    promptTokensBefore: Int = 0,
    promptTokensAfter: Int = 0,
    estimatedTokensSaved: Int = 0,
    fullObservationsCount: Int = 0,
    fullObservationsBytes: Int = 0,
    compactedObservationsBytes: Int = 0
  ) {
    self.messages = messages
    self.compactedCount = compactedCount
    self.evictedGroupCount = evictedGroupCount
    self.revokedReadCallIDs = revokedReadCallIDs
    self.promptTokensBefore = promptTokensBefore
    self.promptTokensAfter = promptTokensAfter
    self.estimatedTokensSaved = estimatedTokensSaved
    self.fullObservationsCount = fullObservationsCount
    self.fullObservationsBytes = fullObservationsBytes
    self.compactedObservationsBytes = compactedObservationsBytes
  }
}

/// One assistant tool-call message plus all of its associated tool result
/// messages within the current user turn.
private struct ExchangeGroup {
  let assistantIndex: Int
  let resultIndices: [Int]
  let callIDs: [String]

  /// A group is complete when every expected tool result is present.
  var isComplete: Bool { resultIndices.count == callIDs.count }
}

/// Builds a bounded inference-facing message list from the full canonical
/// message history before every model generation call.
///
/// Phase 3 of docs/LARGE_FILE_EDITING.md: active-turn context projection.
///
/// The pipeline:
/// 1. Identify the pinned prefix (system/developer messages).
/// 2. Identify the current user turn (messages from last .user onward).
/// 3. Build exchange groups (assistant + all its tool results).
/// 4. Compact eligible tool results to receipts (keeps protocol pairing intact).
/// 5. Evict oldest completed groups when aggregate tokens or group count exceed limits.
/// 6. Inject `TurnWorkingState.render()` as a developer message before the last user message.
///
/// The canonical `messages` array is never mutated. Protocol validity is
/// preserved: every tool call ID in an assistant message retains a matching
/// tool result message.
enum ConversationProjection {
  /// Aggregate token budget for all completed exchange groups in the current turn.
  /// ~18 % of the 8 K usable prompt budget.
  private static let maxExchangeGroupTokens = 1_200
  /// Maximum number of completed exchange groups to retain before eviction.
  private static let maxRetainedGroups = 6

  static func project(
    messages: [AgentMessage],
    observations: [String: ToolObservation],
    workingState: TurnWorkingState,
    contextLimit: Int,
    retrievalBriefing: String? = nil
  ) -> ProjectionResult {
    var projected = messages
    var compactedCount = 0
    var evictedGroupCount = 0
    var revokedReadCallIDs: [String] = []

    // 1. Pinned prefix: leading system/developer messages.
    let prefixEnd = projected.prefix(while: {
      $0.role == .system || $0.role == .developer
    }).count

    // 2. Current user turn: everything from the last .user message onward.
    let lastUserIndex = projected.indices.reversed().first {
      $0 >= prefixEnd && projected[$0].role == .user
    }
    let turnStart = lastUserIndex ?? prefixEnd

    // 3. Build exchange groups within the current turn.
    var groups: [ExchangeGroup] = []
    var i = turnStart
    while i < projected.count {
      let msg = projected[i]
      if msg.role == .assistant, !msg.toolCalls.isEmpty {
        let callIDs = msg.toolCalls.map(\.id)
        var resultIndices: [Int] = []
        var j = i + 1
        while j < projected.count {
          let next = projected[j]
          if next.role == .tool, let id = next.toolCallID, callIDs.contains(id) {
            resultIndices.append(j)
            j += 1
          } else {
            break
          }
        }
        if !resultIndices.isEmpty {
          groups.append(
            ExchangeGroup(assistantIndex: i, resultIndices: resultIndices, callIDs: callIDs))
          i = j
          continue
        }
      }
      i += 1
    }

    // 4. Identify the most recent source read and most recent error call IDs
    //    so we can keep them full regardless of group age.
    var mostRecentSourceReadCallID: String?
    var mostRecentErrorCallID: String?
    for group in groups.reversed() {
      for callID in group.callIDs.reversed() {
        guard let obs = observations[callID] else { continue }
        if obs.isSourceRead, mostRecentSourceReadCallID == nil {
          mostRecentSourceReadCallID = callID
        }
        if obs.isFailure, mostRecentErrorCallID == nil {
          mostRecentErrorCallID = callID
        }
        if mostRecentSourceReadCallID != nil, mostRecentErrorCallID != nil { break }
      }
      if mostRecentSourceReadCallID != nil, mostRecentErrorCallID != nil { break }
    }

    // 5a. Receipt compaction: walk oldest-first; replace eligible tool results.
    for (groupIndex, group) in groups.enumerated() {
      let isMostRecentGroup = groupIndex == groups.count - 1
      for resultIndex in group.resultIndices {
        guard let callID = projected[resultIndex].toolCallID,
          let obs = observations[callID]
        else { continue }

        // Never compact pinned observations, the most recent source read,
        // or the most recent error result.
        guard obs.importance != .pinned,
          callID != mostRecentSourceReadCallID,
          callID != mostRecentErrorCallID
        else { continue }

        // Compact successful edits immediately (working state records the outcome).
        // Compact anything in non-most-recent groups.
        let shouldCompact = (obs.isEdit && !obs.isFailure) || !isMostRecentGroup
        if shouldCompact {
          let old = projected[resultIndex]
          projected[resultIndex] = AgentMessage(
            role: old.role, content: obs.receipt.render(),
            toolCalls: old.toolCalls, toolCallID: old.toolCallID, name: old.name)
          compactedCount += 1
        }
      }
    }

    // 5b. Group eviction: evict oldest evictable completed groups until tokens
    //     and group count are within limits.
    let effectiveMaxGroupTokens = contextLimit <= 8_192 ? 900 : max(maxExchangeGroupTokens, contextLimit / 6)
    let effectiveMaxRetainedGroups = contextLimit <= 8_192 ? 4 : max(maxRetainedGroups, contextLimit / 1_000)

    var evicted = [Bool](repeating: false, count: groups.count)
    while true {
      var totalTokens = 0
      var retainedCompleted = 0
      for (idx, group) in groups.enumerated() where !evicted[idx] && group.isComplete {
        totalTokens += estimateGroupTokens(group, in: projected)
        retainedCompleted += 1
      }
      guard totalTokens > effectiveMaxGroupTokens || retainedCompleted > effectiveMaxRetainedGroups else {
        break
      }

      // Pass 1: Evict oldest completed group that does not contain pinned observations,
      // and does not contain the most recent source read or most recent error.
      var evictedAny = false
      for (idx, group) in groups.enumerated() where !evicted[idx] && group.isComplete {
        let evictable = group.callIDs.allSatisfy { callID in
          guard let obs = observations[callID] else { return true }
          guard obs.importance != .pinned else { return false }
          guard callID != mostRecentSourceReadCallID else { return false }
          guard callID != mostRecentErrorCallID else { return false }
          return obs.importance <= .normal
        }
        guard evictable else { continue }
        evicted[idx] = true
        evictedGroupCount += 1
        evictedAny = true
        break  // evict one group per iteration and recheck totals
      }
      if evictedAny { continue }

      // Pass 2: If we are still over budget and retained groups > 1, allow evicting
      // groups even if they contain the most recent error or source read, as long as
      // they are not pinned. Older errors/reads yield to the aggregate budget.
      guard retainedCompleted > 1 else { break }
      for (idx, group) in groups.enumerated() where !evicted[idx] && group.isComplete {
        let evictable = group.callIDs.allSatisfy { callID in
          guard let obs = observations[callID] else { return true }
          return obs.importance != .pinned
        }
        guard evictable else { continue }
        evicted[idx] = true
        evictedGroupCount += 1
        evictedAny = true
        // Track revoked source reads so caller can update ReadRevisionLedger.
        for callID in group.callIDs where callID == mostRecentSourceReadCallID {
          revokedReadCallIDs.append(callID)
        }
        break
      }
      if !evictedAny { break }
    }

    // Remove evicted group messages (assistant + results) atomically.
    let evictedIndices: Set<Int> = groups.enumerated()
      .filter { evicted[$0.offset] }
      .reduce(into: []) { set, pair in
        set.insert(pair.element.assistantIndex)
        pair.element.resultIndices.forEach { set.insert($0) }
      }
    var trimmed = projected.indices.compactMap { evictedIndices.contains($0) ? nil : projected[$0] }

    // Intermediate assistant turns with tool calls omit redundant prose in projections
    // (matching MCPJSONSchemaBridge formatting and small context window spec).
    for (idx, msg) in trimmed.enumerated() {
      if msg.role == .assistant && !msg.toolCalls.isEmpty && msg.content != nil {
        trimmed[idx] = AgentMessage(
          role: msg.role, content: nil, toolCalls: msg.toolCalls,
          toolCallID: msg.toolCallID, name: msg.name)
      }
    }

    // Emergency projection budget guard: ensure final request fits within usable budget.
    // In an 8K window, instructions and tool definitions occupy ~3,200 tokens. Messages
    // cannot safely exceed ~2,000 tokens before risking newestTurnTooLarge errors.
    let reservedOutput = contextLimit <= 8_192 ? 1_024 : min(4_096, max(2_048, contextLimit / 8))
    let safetyMargin = max(256, contextLimit / 16)
    let usableBudget = max(0, contextLimit - reservedOutput - safetyMargin)
    let targetMessageBudget = contextLimit <= 8_192 ? min(2_200, max(800, usableBudget - 4_200)) : max(1_000, usableBudget - 4_000)

    var currentMsgTokens = trimmed.reduce(0) { $0 + estimateTokens($1) }
    if currentMsgTokens > targetMessageBudget {
      for (idx, msg) in trimmed.enumerated() where msg.role == .tool {
        guard let callID = msg.toolCallID, let obs = observations[callID] else { continue }
        guard !obs.isSourceRead, obs.importance != .pinned else { continue }
        guard msg.content?.hasPrefix("[receipt") != true else { continue }
        let receiptText = obs.receipt.render()
        trimmed[idx] = AgentMessage(
          role: msg.role, content: receiptText, toolCalls: msg.toolCalls,
          toolCallID: msg.toolCallID, name: msg.name)
        compactedCount += 1
      }
      currentMsgTokens = trimmed.reduce(0) { $0 + estimateTokens($1) }
    }

    // If still over message budget, evict oldest completed groups to guarantee fit
    while currentMsgTokens > targetMessageBudget {
      let assistantIndices = trimmed.indices.filter {
        trimmed[$0].role == .assistant && !trimmed[$0].toolCalls.isEmpty
      }
      guard assistantIndices.count > 1 else { break }

      let oldestAssistantIdx = assistantIndices[0]
      let callIDs = Set(trimmed[oldestAssistantIdx].toolCalls.map(\.id))
      var indicesToRemove = Set<Int>([oldestAssistantIdx])
      for idx in (oldestAssistantIdx + 1)..<trimmed.count {
        let msg = trimmed[idx]
        if msg.role == .tool, let id = msg.toolCallID, callIDs.contains(id) {
          indicesToRemove.insert(idx)
        } else if msg.role == .assistant {
          break
        }
      }

      for id in callIDs where id == mostRecentSourceReadCallID {
        revokedReadCallIDs.append(id)
      }

      trimmed = trimmed.indices.compactMap { indicesToRemove.contains($0) ? nil : trimmed[$0] }
      evictedGroupCount += 1
      currentMsgTokens = trimmed.reduce(0) { $0 + estimateTokens($1) }
    }

    // Final compaction pass for any tool results if still over budget
    if currentMsgTokens > targetMessageBudget {
      for (idx, msg) in trimmed.enumerated() where msg.role == .tool {
        guard let callID = msg.toolCallID, let obs = observations[callID] else { continue }
        guard obs.importance != .pinned else { continue }
        guard msg.content?.hasPrefix("[receipt") != true else { continue }
        let receiptText = obs.receipt.render()
        trimmed[idx] = AgentMessage(
          role: msg.role, content: receiptText, toolCalls: msg.toolCalls,
          toolCallID: msg.toolCallID, name: msg.name)
        compactedCount += 1
      }
    }

    // 6. Inject TurnWorkingState as an ephemeral developer instruction.
    var final_ = trimmed
    let rendered = workingState.render()
    if !rendered.isEmpty {
      let devMsg = AgentMessage(
        role: .developer, content: rendered,
        toolCalls: [], toolCallID: nil, name: nil)
      let prefixEnd = final_.prefix(while: { $0.role == .system || $0.role == .developer }).count
      final_.insert(devMsg, at: prefixEnd)
    }

    // 7. Inject retrieval briefing as an ephemeral developer instruction when available.
    let briefing = retrievalBriefing ?? (workingState.candidatePaths.isEmpty ? workingState.retrievalBriefing : nil)
    if let briefing, !briefing.isEmpty {
      let briefingMsg = AgentMessage(
        role: .developer, content: briefing,
        toolCalls: [], toolCallID: nil, name: nil)
      let prefixEnd = final_.prefix(while: { $0.role == .system || $0.role == .developer }).count
      final_.insert(briefingMsg, at: prefixEnd)
    }

    let promptTokensBefore = messages.reduce(0) { $0 + estimateTokens($1) }
    let promptTokensAfter = final_.reduce(0) { $0 + estimateTokens($1) }
    let estimatedTokensSaved = max(0, promptTokensBefore - promptTokensAfter)

    var fullObservationsCount = 0
    var fullObservationsBytes = 0
    var compactedObservationsBytes = 0
    let finalToolContents = Set(final_.compactMap { $0.role == .tool ? $0.content : nil })
    for obs in observations.values {
      let receiptText = obs.receipt.render()
      if !receiptText.isEmpty && finalToolContents.contains(receiptText) {
        compactedObservationsBytes += receiptText.utf8.count
      } else {
        fullObservationsCount += 1
        fullObservationsBytes += obs.fullResult.utf8.count
      }
    }

    return ProjectionResult(
      messages: final_,
      compactedCount: compactedCount,
      evictedGroupCount: evictedGroupCount,
      revokedReadCallIDs: revokedReadCallIDs,
      promptTokensBefore: promptTokensBefore,
      promptTokensAfter: promptTokensAfter,
      estimatedTokensSaved: estimatedTokensSaved,
      fullObservationsCount: fullObservationsCount,
      fullObservationsBytes: fullObservationsBytes,
      compactedObservationsBytes: compactedObservationsBytes)
  }

  // MARK: - Token estimation

  private static func estimateGroupTokens(_ group: ExchangeGroup, in messages: [AgentMessage])
    -> Int
  {
    var tokens = estimateTokens(messages[group.assistantIndex])
    for idx in group.resultIndices { tokens += estimateTokens(messages[idx]) }
    return tokens
  }

  private static func estimateTokens(_ message: AgentMessage) -> Int {
    var total = 6
    if message.role != .assistant || message.toolCalls.isEmpty {
      total += estimateText(message.content ?? "")
    }
    for call in message.toolCalls {
      total += 8
      if let encoded = try? call.arguments.encoded() {
        total += estimateText(encoded)
      }
    }
    return total
  }

  private static func estimateText(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, (text.utf8.count + 2) / 3)
  }
}

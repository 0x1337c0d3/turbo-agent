
/// Shared conversation loop for the interactive session and delegated tasks.
enum ConversationTurn {
  static func run(
    messages: inout [AgentMessage],
    maximumRounds: Int = 32,
    cancellation: AgentCancellation? = nil,
    contextLimit: Int = 8_192,
    projectMessages: Bool = true,
    retrievalBriefing: String? = nil,
    candidatePaths: [String] = [],
    onWorkingStateUpdate: ((TurnWorkingState) -> Void)? = nil,
    generate: ([AgentMessage]) async throws -> (content: String, calls: [ParsedToolCall]),
    execute: (ParsedToolCall) async throws -> String
  ) async throws -> String {
    var emptyContentRetries = 0
    let totalRounds = max(0, maximumRounds)
    var workingState = TurnWorkingState()
    workingState.objective = messages.last(where: { $0.role == .user })?.content ?? ""
    workingState.retrievalBriefing = retrievalBriefing
    workingState.candidatePaths = candidatePaths
    workingState.telemetry.retrievalCandidates = candidatePaths
    var observations: [String: ToolObservation] = [:]

    for round in 0..<totalRounds {
      try Task.checkCancellation()
      try cancellation?.check()
      let messagesForGeneration: [AgentMessage]
      if projectMessages {
        let projection = ConversationProjection.project(
          messages: messages,
          observations: observations,
          workingState: workingState,
          contextLimit: contextLimit)
        workingState.compactedObservationCount = projection.compactedCount
        workingState.evictedGroupCount = projection.evictedGroupCount
        workingState.telemetry.compactedObservationsCount = projection.compactedCount
        workingState.telemetry.evictedGroupCount = projection.evictedGroupCount
        workingState.telemetry.promptTokensBeforeProjection = projection.promptTokensBefore
        workingState.telemetry.promptTokensAfterProjection = projection.promptTokensAfter
        workingState.telemetry.estimatedTokensSaved = projection.estimatedTokensSaved
        workingState.telemetry.fullObservationsCount = projection.fullObservationsCount
        workingState.telemetry.fullObservationsBytes = projection.fullObservationsBytes
        workingState.telemetry.compactedObservationsBytes = projection.compactedObservationsBytes
        onWorkingStateUpdate?(workingState)
        messagesForGeneration = projection.messages
      } else {
        messagesForGeneration = messages
      }
      let (content, calls) = try await generate(messagesForGeneration)
      try cancellation?.check()
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if calls.isEmpty {
        if trimmed.isEmpty && emptyContentRetries < 2 {
          emptyContentRetries += 1
          messages.append(
            AgentMessage(
              role: .assistant, content: nil,
              toolCalls: [], toolCallID: nil, name: nil))
          messages.append(
            AgentMessage(
              role: .user,
              content:
                "You completed your internal analysis, but did not emit any tool calls or content. Please conclude your analysis and provide your response or next step.",
              toolCalls: [], toolCallID: nil, name: nil))
          continue
        }
        workingState.telemetry.taskSucceeded = true
        onWorkingStateUpdate?(workingState)
        messages.append(
          AgentMessage(
            role: .assistant, content: content.isEmpty ? nil : content,
            toolCalls: [], toolCallID: nil, name: nil))
        return content
      }
      emptyContentRetries = 0
      messages.append(
        AgentMessage(
          role: .assistant, content: content.isEmpty ? nil : content,
          toolCalls: calls.map { .init(id: $0.id, name: $0.name, arguments: $0.arguments) },
          toolCallID: nil, name: nil))
      let remainingRounds = totalRounds - (round + 1)
      for (index, call) in calls.enumerated() {
        try Task.checkCancellation()
        try cancellation?.check()
        var result = try await execute(call)
        try cancellation?.check()
        if index == calls.count - 1 && remainingRounds > 0 && remainingRounds <= 4 {
          let urgency =
            remainingRounds == 1
            ? "[CRITICAL Turn Budget Notice: This is your LAST allowed tool round. Conclude your actions and provide your final response to the user.]"
            : "[Turn Budget Notice: \(remainingRounds) round\(remainingRounds == 1 ? "" : "s") remaining before budget limit. Please conclude any pending actions and prepare your final response.]"
          result += "\n\n" + urgency
        }
        let observation = ToolObservation.make(call: call, result: result, workingState: workingState)
        observations[call.id] = observation
        workingState.recordToolResult(call: call, result: result)
        messages.append(
          AgentMessage(
            role: .tool, content: result, toolCalls: [],
            toolCallID: call.id, name: call.name))
      }
    }
    throw TurnError.roundLimit
  }

  enum TurnError: Error { case roundLimit }
}

extension ParsedToolCall {
  func stringArgument(_ key: String) -> String? {
    guard case .object(let arguments) = arguments,
      case .string(let value) = arguments[key]
    else { return nil }
    return value
  }

  func intArgument(_ key: String) -> Int? {
    guard case .object(let arguments) = arguments else { return nil }
    if case .integer(let value) = arguments[key] { return Int(value) }
    if case .number(let value) = arguments[key] { return Int(value) }
    return nil
  }

  func arrayArgument(_ key: String) -> [JSONValue]? {
    guard case .object(let arguments) = arguments,
      case .array(let value) = arguments[key]
    else { return nil }
    return value
  }

  var argumentSummary: String {
    guard case .object(let arguments) = arguments else { return "" }
    let preferred = ["command", "path", "query", "prompt", "url"]
      .compactMap { stringArgument($0) }.first
    let text = (preferred ?? arguments.keys.sorted().joined(separator: ", "))
      .replacingOccurrences(of: "\n", with: " ")
    return text.count > 60 ? String(text.prefix(60)) + "..." : text
  }
}

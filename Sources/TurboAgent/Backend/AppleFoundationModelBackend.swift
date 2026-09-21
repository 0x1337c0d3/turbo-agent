import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

public enum AppleFoundationModelError: Error, CustomStringConvertible {
  case unsupportedPlatform(String)
  case modelUnavailable(String)
  case generationFailed(String)

  public var description: String {
    switch self {
    case .unsupportedPlatform(let msg): return msg
    case .modelUnavailable(let msg): return msg
    case .generationFailed(let msg): return msg
    }
  }
}

final class AppleFoundationModelBackend: InferenceBackend, @unchecked Sendable {
  // Updated to the real model.contextSize after the first generate call.
  var capabilities: BackendCapabilities
  var pccPolicy: PCCPolicy
  private let systemPrompt: String
  private let toolBridge: MCPJSONSchemaBridge
  private let statusLine: AgentStatusLine

  /// Minimum unified memory required to default to `SystemLanguageModel.Variant.coreAdvanced3` (12 GB).
  static let advancedModelMemoryThresholdBytes: UInt64 = 12 * 1024 * 1024 * 1024

  /// Returns the available unified memory in bytes.
  /// Checks dynamic available memory (free + inactive pages) via `host_statistics64`,
  /// falling back to total physical memory (`ProcessInfo.processInfo.physicalMemory`).
  static func availableUnifiedMemoryBytes() -> UInt64 {
    var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var vmStats = vm_statistics64()
    let kernRet = withUnsafeMutablePointer(to: &vmStats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &hostSize)
      }
    }
    if kernRet == KERN_SUCCESS {
      var pageSize: vm_size_t = 0
      host_page_size(mach_host_self(), &pageSize)
      let free = UInt64(vmStats.free_count) * UInt64(pageSize)
      let inactive = UInt64(vmStats.inactive_count) * UInt64(pageSize)
      let available = free + inactive
      if available > 0 {
        return available
      }
    }
    return ProcessInfo.processInfo.physicalMemory
  }

  /// Determines whether the system has 12+ GB of unified memory available.
  static func hasTwelveOrMoreGigabytesUnifiedMemoryAvailable() -> Bool {
    return availableUnifiedMemoryBytes() >= advancedModelMemoryThresholdBytes
      || ProcessInfo.processInfo.physicalMemory >= advancedModelMemoryThresholdBytes
  }

  init(pccPolicy: PCCPolicy = .auto, systemPrompt: String, statusLine: AgentStatusLine? = nil) {
    self.pccPolicy = pccPolicy
    self.systemPrompt = systemPrompt
    self.toolBridge = MCPJSONSchemaBridge()
    self.statusLine = statusLine ?? AgentStatusLine()
    // Placeholder; real context window is set once the model is selected in generate().
    self.capabilities = BackendCapabilities(
      name: "Apple Foundation Models (AFM 3 Core & Cloud Pro PCC)",
      supportsTools: true,
      supportsStreaming: true,
      maxContextLength: 8_192,
      isOnDevice: pccPolicy != .require,
      isPrivateCloudCompute: pccPolicy != .disable
    )
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
    #if canImport(FoundationModels)
      guard #available(macOS 27.0, *) else {
        throw AppleFoundationModelError.unsupportedPlatform(
          "Apple Foundation Models require macOS 27.0 (Golden Gate) or later."
        )
      }

      return try await generateWithFoundationModels(
        messages: messages,
        tools: tools,
        interaction: interaction,
        cancellation: cancellation,
        terminal: terminal
      )
    #else
      throw AppleFoundationModelError.unsupportedPlatform(
        "FoundationModels framework is not available in this build."
      )
    #endif
  }

  #if canImport(FoundationModels)
    /// Selects the on-device SystemLanguageModel. If the device has 12+ GB of unified memory
    /// available and SystemLanguageModel.Variant.coreAdvanced3 is available, returns it;
    /// otherwise returns Core3 or the default SystemLanguageModel.
    @available(macOS 27.0, *)
    private func selectOnDeviceModel() -> SystemLanguageModel? {
      let defaultModel = SystemLanguageModel.default
      guard defaultModel.availability == .available else {
        return nil
      }

      if Self.hasTwelveOrMoreGigabytesUnifiedMemoryAvailable() {
        if defaultModel.variant == .coreAdvanced3 {
          return defaultModel
        }
      } else {
        if defaultModel.variant == .core3 {
          return defaultModel
        }
      }

      return defaultModel
    }

    @available(macOS 27.0, *)
    private func generateWithFoundationModels(
      messages: [AgentMessage],
      tools: [AgentToolDefinition]?,
      interaction: AgentInteraction?,
      cancellation: AgentCancellation?,
      terminal: TerminalGeneration?
    ) async throws -> (content: String, calls: [ParsedToolCall]) {
      let model: any LanguageModel
      let modelContextSize: Int
      let usingPCC: Bool

      switch pccPolicy {
      case .disable:
        guard let onDeviceModel = selectOnDeviceModel() else {
          throw AppleFoundationModelError.modelUnavailable(
            "AFM 3 on-device (SystemLanguageModel) is not available on this device."
          )
        }
        model = onDeviceModel
        modelContextSize = onDeviceModel.contextSize
        usingPCC = false

      case .auto:
        // Prefer on-device model; fall through to Private Cloud Compute if unavailable.
        if let onDeviceModel = selectOnDeviceModel() {
          model = onDeviceModel
          modelContextSize = onDeviceModel.contextSize
          usingPCC = false
        } else {
          let pcc = PrivateCloudComputeLanguageModel()
          guard pcc.availability == .available else {
            throw AppleFoundationModelError.modelUnavailable(
              "Neither AFM 3 on-device nor Private Cloud Compute is available on this device."
            )
          }
          model = pcc
          modelContextSize = try await pcc.contextSize
          usingPCC = true
        }

      case .require:
        let pcc = PrivateCloudComputeLanguageModel()
        guard pcc.availability == .available else {
          throw AppleFoundationModelError.modelUnavailable(
            "AFM Cloud Pro (PrivateCloudComputeLanguageModel) is not available."
          )
        }
        model = pcc
        modelContextSize = try await pcc.contextSize
        usingPCC = true
      }

      // Update capabilities with the real context window and routing, syncing the status bar.
      let expectedOnDevice = !usingPCC
      let expectedPCC = usingPCC
      let onDeviceModelName: String
      if let slm = model as? SystemLanguageModel {
        onDeviceModelName = "Apple Foundation Models (\(slm.variant.displayName))"
      } else {
        onDeviceModelName = "Apple Foundation Models (AFM 3 Core)"
      }
      if capabilities.maxContextLength != modelContextSize
        || capabilities.isOnDevice != expectedOnDevice
        || capabilities.isPrivateCloudCompute != expectedPCC
      {
        capabilities = BackendCapabilities(
          name: usingPCC
            ? "Apple Foundation Models (AFM Cloud Pro PCC)"
            : onDeviceModelName,
          supportsTools: capabilities.supportsTools,
          supportsStreaming: capabilities.supportsStreaming,
          maxContextLength: modelContextSize,
          isOnDevice: expectedOnDevice,
          isPrivateCloudCompute: expectedPCC
        )
        statusLine.snapshot.maxContext = modelContextSize
      }

      let activeTools = tools ?? ToolRegistry.definitions
      let toolCatalog = toolBridge.formatToolCatalog(tools: activeTools)
      let requestInstructions = AgentContextAssembler.effectiveInstructions(
        in: messages, fallback: systemPrompt)
      let fullInstructions = """
        \(requestInstructions)

        \(toolCatalog)
        """

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

      // Retry loop: on AFM context overflow, trim the oldest non-system turn and retry.
      var currentMessages = messages
      var trimAttempt = 0
      let maxTrimAttempts = 5

      while true {
        let promptText = toolBridge.formatConversationPrompt(messages: currentMessages)
        let estimatedPromptTokens = AgentContextAssembler.estimateTokens(
          fullInstructions + "\n\n" + promptText)
        let session = LanguageModelSession(model: model, instructions: fullInstructions)

        if trimAttempt > 0 { activeTerminal?.beginGeneration() }
        if interaction == nil {
          statusLine.beginGeneration(contextTokens: estimatedPromptTokens)
        }

        var fullText = ""
        let generateStart = ProcessInfo.processInfo.systemUptime
        var generatedTokens = 0

        do {
          let stream = session.streamResponse(to: promptText)
          for try await snapshot in stream {
            if effectiveCancellation.isCancelled || Task.isCancelled {
              await activeTerminal?.finishGeneration()
              throw CancellationError()
            }
            fullText = snapshot.content
            generatedTokens = AgentContextAssembler.estimateTokens(fullText)
            if interaction == nil {
              statusLine.token(
                count: generatedTokens,
                contextTokens: estimatedPromptTokens + generatedTokens)
            }
          }
        } catch  where isContextSizeError(error) {
          await activeTerminal?.finishGeneration()

          trimAttempt += 1
          if trimAttempt > maxTrimAttempts {
            let msg =
              "[AFM: Context window exceeded after \(maxTrimAttempts) trim attempts. Use /clear to reset.]"
            if interaction == nil {
              printColor(msg + "\n", color: "yellow")
            } else {
              interaction?.text(msg + "\n")
            }
            throw AppleFoundationModelError.generationFailed(
              "AFM context window exceeded. Conversation history too long — start a new session with /clear."
            )
          }

          guard let trimmed = trimOldestTurn(from: currentMessages) else {
            let msg = "[AFM: Context window full and no history to trim. Use /clear to reset.]"
            if interaction == nil {
              printColor(msg + "\n", color: "yellow")
            } else {
              interaction?.text(msg + "\n")
            }
            throw AppleFoundationModelError.generationFailed(
              "AFM context window exceeded with minimal history. Use /clear to reset."
            )
          }

          let dropped = currentMessages.count - trimmed.count
          currentMessages = trimmed
          let msg =
            "[AFM: Context full — dropped oldest \(dropped) message(s), retrying (\(trimAttempt)/\(maxTrimAttempts))...]"
          if interaction == nil {
            printColor(msg + "\n", color: "yellow")
          } else {
            interaction?.text(msg + "\n")
          }
          continue  // retry with trimmed history

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

        // Generation succeeded — finalise.
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - generateStart
        await activeTerminal?.finishGeneration()
        if interaction == nil {
          statusLine.finish(
            tokens: generatedTokens, decodeSeconds: decodeSeconds,
            contextTokens: estimatedPromptTokens + generatedTokens)
        }

        if effectiveCancellation.isCancelled || Task.isCancelled {
          throw CancellationError()
        }

        let (cleanContent, calls) = toolBridge.parseToolCalls(from: fullText)
        let effectiveContent: String
        if !calls.isEmpty {
          if cleanContent.contains("Scratchpad Output")
            || cleanContent.contains("Verification:")
            || cleanContent.contains("Tool (")
            || cleanContent.contains("Result:")
          {
            effectiveContent = ""
          } else {
            effectiveContent = cleanContent
          }
        } else {
          effectiveContent = cleanContent
        }

        if let interaction {
          if !effectiveContent.isEmpty { interaction.text(effectiveContent) }
        } else {
          if !effectiveContent.isEmpty { terminalPrint(TerminalText.safe(effectiveContent)) }
        }

        return (effectiveContent, calls)
      }
    }

    // MARK: - Context overflow helpers

    @available(macOS 27.0, *)
    private func isContextSizeError(_ error: Error) -> Bool {
      // Current LanguageModelError API
      if let lme = error as? LanguageModelError, case .contextSizeExceeded = lme { return true }
      // Deprecated GenerationError wrapper (still thrown by streamResponse in practice)
      if let ge = error as? LanguageModelSession.GenerationError,
        case .exceededContextWindowSize = ge
      {
        return true
      }
      // Recurse into wrapped NSErrors (the error arrives triple-wrapped in practice)
      let ns = error as NSError
      if let underlying = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
        return underlying.contains { isContextSizeError($0) }
      }
      return false
    }

    /// Removes the oldest non-system turn (from the first user message up to, but not including,
    /// the second user message). Returns nil if there is nothing safe to drop.
    private func trimOldestTurn(from messages: [AgentMessage]) -> [AgentMessage]? {
      guard messages.count > 2 else { return nil }
      // Find the index of the second user message (start of the second turn).
      var secondUserIdx = messages.count
      for i in 2..<messages.count where messages[i].role == .user {
        secondUserIdx = i
        break
      }
      // If there is no second user message the entire history is one turn — nothing to drop.
      guard secondUserIdx < messages.count else { return nil }
      var trimmed = [messages[0]]
      trimmed += messages[secondUserIdx...]
      return trimmed
    }
  #endif
}

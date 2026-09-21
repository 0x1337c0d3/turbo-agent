import Foundation

struct OpenAISettings: Decodable {
  let openaiApiKey: String?
  let openaiBaseUrl: String?
  let openaiModel: String?

  enum CodingKeys: String, CodingKey {
    case openaiApiKey = "openai_api_key"
    case openaiBaseUrl = "openai_base_url"
    case openaiModel = "openai_model"
  }
}

struct OpenAIRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String?
    let name: String?
    let toolCalls: [ToolCall]?
    let toolCallId: String?

    enum CodingKeys: String, CodingKey {
      case role, content, name
      case toolCalls = "tool_calls"
      case toolCallId = "tool_call_id"
    }

    struct ToolCall: Encodable {
      let id: String
      let type: String
      let function: FunctionCall
    }

    struct FunctionCall: Encodable {
      let name: String
      let arguments: String
    }
  }

  struct Tool: Encodable {
    let type: String
    let function: FunctionDef

    struct FunctionDef: Encodable {
      let name: String
      let description: String
      let parameters: JSONValue
    }
  }

  let model: String
  let messages: [Message]
  let tools: [Tool]?
}

struct OpenAIResponse: Decodable {
  struct Usage: Decodable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
    }
  }
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String?
      let toolCalls: [ToolCall]?

      enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
      }

      struct ToolCall: Decodable {
        let id: String
        let function: FunctionCall

        struct FunctionCall: Decodable {
          let name: String
          let arguments: String
        }
      }
    }
    let message: Message
  }
  let choices: [Choice]
  let usage: Usage?
}

public struct OpenRouterModel: Decodable, Sendable {
  public let id: String
  public let name: String?
  public let contextLength: Int?
  public let topProvider: TopProvider?

  enum CodingKeys: String, CodingKey {
    case id, name
    case contextLength = "context_length"
    case topProvider = "top_provider"
  }

  public struct TopProvider: Decodable, Sendable {
    public let contextLength: Int?
    public let maxCompletionTokens: Int?

    enum CodingKeys: String, CodingKey {
      case contextLength = "context_length"
      case maxCompletionTokens = "max_completion_tokens"
    }
  }
}

public struct OpenRouterModelsResponse: Decodable, Sendable {
  public let data: [OpenRouterModel]
}

private func resolveEnv(_ value: String) -> String {
  let resolved = value
  if resolved.hasPrefix("$") {
    let envVar = resolved.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    if let envVal = ProcessInfo.processInfo.environment[envVar] {
      return envVal
    }
  } else if let envVal = ProcessInfo.processInfo.environment[resolved] {
    return envVal
  }
  return resolved
}

final class OpenAIClient: @unchecked Sendable {
  let apiKey: String
  let baseURL: URL
  let modelName: String
  private(set) var cachedContextLength: Int?
  var session: URLSession = .shared

  init(apiKey: String, baseURL: URL, modelName: String, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.modelName = modelName
    self.session = session
  }

  convenience init?() {
    let fm = FileManager.default
    let settingsURL = fm.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/TurboAgent/settings.json")
    let settings = (try? Data(contentsOf: settingsURL))
      .flatMap { try? JSONDecoder().decode(OpenAISettings.self, from: $0) }
    let environment = ProcessInfo.processInfo.environment
    guard let rawKey = settings?.openaiApiKey ?? environment["OPENAI_API_KEY"], !rawKey.isEmpty
    else { return nil }
    let resolvedKey = resolveEnv(rawKey)
    let base = settings?.openaiBaseUrl ?? environment["OPENAI_BASE_URL"]
      ?? "https://api.openai.com/v1/"
    guard let resolvedBaseURL = URL(string: base) else { return nil }
    let resolvedModel = settings?.openaiModel ?? environment["OPENAI_MODEL"] ?? "gpt-4o"
    self.init(apiKey: resolvedKey, baseURL: resolvedBaseURL, modelName: resolvedModel)
  }

  func fetchModelContextLength(model: String? = nil) async -> Int? {
    let targetModel = model ?? self.modelName
    if let cached = cachedContextLength, model == nil || model == self.modelName {
      return cached
    }

    let modelsURL: URL
    if baseURL.host?.contains("openrouter") == true {
      modelsURL = baseURL.appendingPathComponent("models")
    } else {
      modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    }

    var request = URLRequest(url: modelsURL)
    request.httpMethod = "GET"
    if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    do {
      let (data, response) = try await session.data(for: request)
      if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
        let list = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        if let len = findContextLength(for: targetModel, in: list.data) {
          if model == nil || model == self.modelName {
            self.cachedContextLength = len
          }
          return len
        }
      }
    } catch {
      // Graceful fallback on network or decode failure
    }

    let fallback = fallbackContextLength(for: targetModel)
    if model == nil || model == self.modelName {
      self.cachedContextLength = fallback
    }
    return fallback
  }

  func findContextLength(for model: String, in models: [OpenRouterModel]) -> Int? {
    let lower = model.lowercased()
    if let m = models.first(where: { $0.id == model }) {
      return m.contextLength ?? m.topProvider?.contextLength
    }
    if let m = models.first(where: { $0.id.lowercased() == lower }) {
      return m.contextLength ?? m.topProvider?.contextLength
    }
    if let m = models.first(where: { $0.id.hasSuffix("/" + model) || model.hasSuffix("/" + $0.id) })
    {
      return m.contextLength ?? m.topProvider?.contextLength
    }
    if let m = models.first(where: { $0.id.hasPrefix(model + ":") || model.hasPrefix($0.id + ":") })
    {
      return m.contextLength ?? m.topProvider?.contextLength
    }
    return nil
  }

  func fallbackContextLength(for model: String) -> Int {
    let lower = model.lowercased()
    if lower.contains("gemini") {
      return 1_048_576
    } else if lower.contains("claude") {
      return 200_000
    } else if lower.contains("deepseek") {
      return 163_840
    } else if lower.contains("llama-3.3") || lower.contains("qwen") {
      return 131_072
    } else {
      return 128_000
    }
  }

  func generate(messages: [AgentMessage], tools: [AgentToolDefinition]?)
    async throws -> (content: String, calls: [ParsedToolCall], usage: OpenAIResponse.Usage?)
  {
    let reqMessages = messages.map { msg -> OpenAIRequest.Message in
      let toolCalls =
        msg.toolCalls.isEmpty
        ? nil
        : msg.toolCalls.map { tc in
          OpenAIRequest.Message.ToolCall(
            id: tc.id,
            type: "function",
            function: OpenAIRequest.Message.FunctionCall(
              name: tc.name, arguments: (try? tc.arguments.encoded()) ?? "{}")
          )
        }
      return OpenAIRequest.Message(
        role: msg.role.rawValue,
        content: msg.content,
        name: msg.name,
        toolCalls: toolCalls,
        toolCallId: msg.toolCallID
      )
    }

    let reqTools = tools?.map { t in
      OpenAIRequest.Tool(
        type: "function",
        function: OpenAIRequest.Tool.FunctionDef(
          name: t.name,
          description: t.description,
          parameters: t.parameters
        )
      )
    }

    let requestPayload = OpenAIRequest(model: modelName, messages: reqMessages, tools: reqTools)

    let url = baseURL.appendingPathComponent("chat/completions")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "api-key")  // For Azure / Microsoft Foundry
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")  // For other generic gateways

    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(requestPayload)

    let (data, response) = try await session.data(for: request)
    guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
      let errStr = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw NSError(
        domain: "OpenAIClient", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(errStr)"])
    }

    let res = try JSONDecoder().decode(OpenAIResponse.self, from: data)
    guard let message = res.choices.first?.message else {
      return ("", [], res.usage)
    }

    var calls: [ParsedToolCall] = []
    if let toolCalls = message.toolCalls {
      for tc in toolCalls {
        let argsData = tc.function.arguments.data(using: .utf8)!
        let argsJSON = (try? JSONDecoder().decode(JSONValue.self, from: argsData)) ?? .object([:])
        calls.append(
          ParsedToolCall(
            id: tc.id, name: tc.function.name, arguments: argsJSON,
            argumentsJSON: tc.function.arguments))
      }
    }

    return (message.content ?? "", calls, res.usage)
  }
}

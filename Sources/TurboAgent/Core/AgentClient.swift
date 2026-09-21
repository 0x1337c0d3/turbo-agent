import Foundation

public enum AgentClientBackend: String, CaseIterable, Identifiable, Sendable {
  case appleAutomatic = "apple"
  case appleOnDevice = "apple-local"
  case applePrivateCloud = "apple-pcc"
  case openAI = "openai"

  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .appleAutomatic: return "AFM 3 Automatic"
    case .appleOnDevice: return "AFM 3 Core"
    case .applePrivateCloud: return "AFM Cloud Pro"
    case .openAI: return "OpenAI API"
    }
  }

  fileprivate var arguments: [String] {
    switch self {
    case .appleAutomatic: return ["--backend", "apple", "--pcc", "auto"]
    case .appleOnDevice: return ["--backend", "apple", "--pcc", "disable"]
    case .applePrivateCloud: return ["--backend", "apple", "--pcc", "require"]
    case .openAI: return ["--backend", "openai"]
    }
  }
}

public struct AgentToolRequest: Sendable {
  public let name: String
  public let summary: String
  public let arguments: JSONValue
  public let diff: String?
}

public struct AgentToolUpdate: Sendable {
  public let name: String
  public let summary: String
  public let status: String
  public let output: String?
}

/// UI-facing conversation API. It deliberately exposes no tokenizer, Metal,
/// model-file, or server implementation types.
public actor AgentClient {
  public typealias TextHandler = @Sendable (String) -> Void
  public typealias ToolHandler = @Sendable (AgentToolUpdate) -> Void
  public typealias ApprovalHandler = @Sendable (AgentToolRequest) async -> Bool

  private let core: AgentCore
  private let directory: URL
  private var sessionID: String
  private var cancellation: AgentCancellation?

  public static func make(
    backend: AgentClientBackend,
    directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) async throws -> AgentClient {
    let core = AgentCore(arguments: backend.arguments)
    let client = AgentClient(core: core, directory: directory)
    try await client.createSession()
    return client
  }

  private init(core: AgentCore, directory: URL) {
    self.core = core
    self.directory = directory
    self.sessionID = UUID().uuidString
  }

  public func newConversation() async throws {
    guard cancellation == nil else { throw AgentClientError.busy }
    sessionID = UUID().uuidString
    try await createSession()
  }

  private func createSession() async throws {
    _ = try await core.newSession(id: sessionID, directory: directory, servers: [:])
  }

  public func cancel() { cancellation?.cancel() }

  @discardableResult
  public func send(
    _ prompt: String,
    onText: @escaping TextHandler,
    onTool: @escaping ToolHandler,
    approve: @escaping ApprovalHandler
  ) async throws -> String {
    guard cancellation == nil else { throw AgentClientError.busy }
    let token = AgentCancellation()
    cancellation = token
    defer { cancellation = nil }
    let interaction = AgentInteraction(
      cancellation: token,
      text: onText,
      tool: { call, status, output in
        onTool(
          AgentToolUpdate(
            name: call.name, summary: call.argumentSummary, status: status, output: output))
      },
      approve: { call, diff in
        await approve(
          AgentToolRequest(
            name: call.name,
            summary: call.argumentSummary + (diff.map { "\n\n" + $0 } ?? ""),
            arguments: call.arguments,
            diff: diff))
      })
    return try await core.prompt(session: sessionID, text: prompt, interaction: interaction)
  }
}

public enum AgentClientError: Error, CustomStringConvertible {
  case busy
  public var description: String { "Another agent turn is already active." }
}

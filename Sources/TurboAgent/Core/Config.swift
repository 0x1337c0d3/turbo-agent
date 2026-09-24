import Foundation

public enum AgentBackendKind: String, Sendable, CaseIterable { case apple, openai }
public enum PCCPolicy: String, Sendable, CaseIterable { case auto, disable, require }
public enum OrchestrationMode: String, Sendable, CaseIterable { case auto, always, never }

public enum AgentConfigError: Error, CustomStringConvertible, Equatable {
  case invalidBackend(String)
  case invalidPCCPolicy(String)
  case invalidMaxRounds(String)
  case invalidOrchestrationMode(String)
  case missingValue(String)
  case unsupportedOption(String)

  public var description: String {
    switch self {
    case .invalidBackend(let value):
      return "Invalid backend: '\(value)'. Supported backends are: apple, openai."
    case .invalidPCCPolicy(let value):
      return "Invalid PCC policy: '\(value)'. Supported policies are: auto, disable, require."
    case .invalidMaxRounds(let value): return "Invalid --max-rounds value: '\(value)'."
    case .invalidOrchestrationMode(let value):
      return "Invalid orchestration mode: '\(value)'. Supported modes are: auto, always, never."
    case .missingValue(let option): return "Missing value for \(option)."
    case .unsupportedOption(let option): return "Unsupported option: \(option)."
    }
  }
}

public struct AgentConfig: Sendable {
  public let systemPrompt: String
  public let backend: AgentBackendKind
  public let pccPolicy: PCCPolicy
  public let maxRounds: Int
  public let explicitMaxRounds: Int?
  public let yolo: Bool
  public let orchestrationMode: OrchestrationMode

  public init(
    arguments: [String] = Array(CommandLine.arguments.dropFirst()),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws {
    var selectedBackend: AgentBackendKind?
    var selectedPCC = PCCPolicy.auto
    var maxRounds: Int?
    var agentsFilePath: String?
    var systemPromptPath: String?
    var selectedOrchestration = OrchestrationMode.auto
    var yolo = false
    var index = 0

    func value(after option: String) throws -> String {
      guard index + 1 < arguments.count else { throw AgentConfigError.missingValue(option) }
      return arguments[index + 1]
    }

    while index < arguments.count {
      let option = arguments[index]
      switch option {
      case "--backend":
        let raw = try value(after: option)
        guard let backend = AgentBackendKind(rawValue: raw.lowercased()) else {
          throw AgentConfigError.invalidBackend(raw)
        }
        selectedBackend = backend
        index += 2
      case "--pcc":
        let raw = try value(after: option)
        guard let policy = PCCPolicy(rawValue: raw.lowercased()) else {
          throw AgentConfigError.invalidPCCPolicy(raw)
        }
        selectedPCC = policy
        index += 2
      case "--max-rounds":
        let raw = try value(after: option)
        guard let parsed = Int(raw), parsed > 0 else {
          throw AgentConfigError.invalidMaxRounds(raw)
        }
        maxRounds = parsed
        index += 2
      case "--orchestration":
        let raw = try value(after: option)
        guard let mode = OrchestrationMode(rawValue: raw.lowercased()) else {
          throw AgentConfigError.invalidOrchestrationMode(raw)
        }
        selectedOrchestration = mode
        index += 2
      case "--agents-file":
        agentsFilePath = try value(after: option)
        index += 2
      case "--system-prompt":
        systemPromptPath = try value(after: option)
        index += 2
      case "--yolo":
        yolo = true
        index += 1
      default:
        throw AgentConfigError.unsupportedOption(option)
      }
    }

    if let selectedBackend {
      backend = selectedBackend
    } else if #available(macOS 27.0, *) {
      backend = .apple
    } else {
      backend = .openai
    }
    pccPolicy = selectedPCC
    self.maxRounds = maxRounds ?? 32
    explicitMaxRounds = maxRounds
    self.yolo = yolo
    self.orchestrationMode = selectedOrchestration
    let isEightK = (backend == .apple && pccPolicy != .require)
    systemPrompt = Self.buildSystemPrompt(
      homeDirectory: homeDirectory, workingDirectory: workingDirectory,
      agentsFilePath: agentsFilePath, systemPromptPath: systemPromptPath,
      isEightK: isEightK)
  }

  private static func buildSystemPrompt(
    homeDirectory: URL, workingDirectory: URL,
    agentsFilePath: String?, systemPromptPath: String?,
    isEightK: Bool = false
  ) -> String {
    var prompt = ""
    func append(_ url: URL, header: String? = nil) {
      guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
      if !prompt.isEmpty { prompt += "\n\n" }
      if let header { prompt += header + "\n" }
      prompt += content
    }
    if let systemPromptPath {
      append(URL(fileURLWithPath: systemPromptPath))
    } else {
      let home8k = homeDirectory.appendingPathComponent(".agents/codex_prompt_8k.md")
      let work8k = workingDirectory.appendingPathComponent(".agents/codex_prompt_8k.md")
      let has8k = FileManager.default.fileExists(atPath: home8k.path) || FileManager.default.fileExists(atPath: work8k.path)
      if isEightK && has8k {
        append(home8k)
        append(work8k)
      } else {
        append(homeDirectory.appendingPathComponent(".agents/codex_prompt.md"))
        append(workingDirectory.appendingPathComponent(".agents/codex_prompt.md"))
      }
    }
    if let agentsFilePath {
      append(URL(fileURLWithPath: agentsFilePath), header: "## Agent Guidelines")
    } else {
      append(workingDirectory.appendingPathComponent("AGENTS.md"), header: "## Agent Guidelines")
    }
    if !prompt.isEmpty { prompt += "\n\n" }
    prompt += """
      ## Skills
      Skills are loaded on demand from ~/.agents/skills/ and ./.agents/skills/.

      ## MCP Tools
      MCP tools are available and can be called natively.

      ## Autonomous Execution Policy
      You are an autonomous software engineering agent. Continue through implementation,
      testing, and validation when the user has requested changes. Do not pause merely
      because a workflow description mentions review; respect normal tool permissions.
      """
    return prompt
  }
}

struct AgentMCPConfig: Decodable, Sendable {
  struct ServerConfig: Decodable, Sendable {
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let type: String?
    let url: String?
    let headers: [String: String]?
    let httpHeaders: [String: String]?
    let envHttpHeaders: [String: String]?

    enum CodingKeys: String, CodingKey {
      case command, args, env, type, url, headers
      case httpHeaders = "http_headers"
      case envHttpHeaders = "env_http_headers"
    }

    func resolvedHeaders(environment: [String: String] = ProcessInfo.processInfo.environment) throws
      -> [String: String]
    {
      var result: [String: String] = [:]
      for source in [headers ?? [:], httpHeaders ?? [:]] {
        for (name, value) in source { result[name.lowercased()] = value }
      }
      for (name, variable) in envHttpHeaders ?? [:] {
        guard let value = environment[variable], !value.isEmpty else {
          throw HeaderError.missingEnvironmentVariable(variable)
        }
        result[name.lowercased()] = value
      }
      return result
    }
  }

  enum HeaderError: Error, CustomStringConvertible {
    case missingEnvironmentVariable(String)
    var description: String {
      switch self {
      case .missingEnvironmentVariable(let name):
        return "Required MCP header environment variable \(name) is unset or empty"
      }
    }
  }
  let mcpServers: [String: ServerConfig]?
}

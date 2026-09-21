import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case integer(Int64)
  case unsignedInteger(UInt64)
  case decimal(Decimal)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(UInt64.self) {
      self = .unsignedInteger(value)
    } else if let value = try? container.decode(Decimal.self) {
      self = .decimal(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .unsignedInteger(let value): try container.encode(value)
    case .decimal(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public func encoded(sortedKeys: Bool = true) throws -> String {
    let encoder = JSONEncoder()
    if sortedKeys { encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes] }
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}

public enum AgentRole: String, Sendable { case system, developer, user, assistant, tool }

public struct AgentHistoricalToolCall: Sendable, Equatable {
  public let id: String
  public let name: String
  public let arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct AgentToolDefinition: Sendable, Equatable {
  public let name: String
  public let description: String
  public let parameters: JSONValue

  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

public struct AgentMessage: Sendable, Equatable {
  public let role: AgentRole
  public let content: String?
  public let toolCalls: [AgentHistoricalToolCall]
  public let toolCallID: String?
  public let name: String?

  public init(
    role: AgentRole, content: String?, toolCalls: [AgentHistoricalToolCall] = [],
    toolCallID: String? = nil, name: String? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
    self.name = name
  }
}

public struct ParsedToolCall: Equatable, Sendable {
  public let id: String
  public let name: String
  public let arguments: JSONValue
  public let argumentsJSON: String

  public init(id: String, name: String, arguments: JSONValue, argumentsJSON: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
    self.argumentsJSON = argumentsJSON
  }
}

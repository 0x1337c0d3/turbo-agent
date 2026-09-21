import Foundation

typealias ACPObject = [String: JSONValue]

extension JSONValue {
  var string: String? { if case .string(let value) = self { value } else { nil } }
  var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  var boolean: Bool { self == .bool(true) }
  subscript(_ key: String) -> JSONValue? { objectValue?[key] }
  var rpcID: String? {
    switch self {
    case .string(let value): return "s:" + value
    case .integer(let value): return "n:\(value)"
    case .unsignedInteger(let value): return "n:\(value)"
    default: return nil
    }
  }
}

struct ACPError: Error, Sendable {
  let code: Int64
  let message: String
  static func invalid(_ message: String) -> Self { .init(code: -32602, message: message) }
  static let cancelled = Self(code: -32800, message: "Cancelled")
  static let disconnected = Self(code: -32000, message: "Client disconnected")
  var value: JSONValue { .object(["code": .integer(code), "message": .string(message)]) }
}

extension Dictionary where Key == String, Value == JSONValue {
  func requiredString(_ key: String) throws -> String {
    guard let value = self[key]?.string else { throw ACPError.invalid("Missing or invalid \(key)") }
    return value
  }
}

/// Shared by the protocol reader, inference callbacks and cancellable tools.
final class AgentCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var handlers: [@Sendable () -> Void] = []

  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() {
    var toRun: [@Sendable () -> Void] = []
    lock.withLock {
      guard !cancelled else { return }
      cancelled = true
      toRun = handlers
      handlers.removeAll()
    }
    for handler in toRun {
      handler()
    }
  }
  func onCancel(_ handler: @escaping @Sendable () -> Void) {
    let alreadyCancelled: Bool = lock.withLock {
      if cancelled { return true }
      handlers.append(handler)
      return false
    }
    if alreadyCancelled {
      handler()
    }
  }
  func check() throws { if isCancelled || Task.isCancelled { throw CancellationError() } }
}

struct AgentInteraction: Sendable {
  let cancellation: AgentCancellation
  var text: @Sendable (String) -> Void
  var tool: @Sendable (ParsedToolCall, String, String?) -> Void
  var approve: @Sendable (ParsedToolCall, String?) async -> Bool
  // The UI can supply unsaved editor buffers. Nil means use local files.
  var readFile: (@Sendable (String) async throws -> String)? = nil
  var writeFile: (@Sendable (String, String) async throws -> Void)? = nil
}

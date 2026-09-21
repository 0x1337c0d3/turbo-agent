import XCTest

@testable import TurboAgentCore

private final class ACPInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [JSONValue] = []
  func append(_ value: JSONValue) { lock.withLock { values.append(value) } }
  var messages: [JSONValue] { lock.withLock { values } }
  func wait(_ predicate: @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
    for _ in 0..<300 {
      if let found = messages.first(where: predicate) { return found }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ACPError(code: -1, message: "Missing expected ACP message")
  }
}

private actor ScriptedACPBackend: ACPBackend {
  var roots: [String: URL] = [:]
  var completed = 0
  func newSession(id: String, directory: URL, servers: [String: AgentMCPConfig.ServerConfig])
    -> [String]
  {
    roots[id] = directory
    return ["review"]
  }
  func prompt(session: String, text: String, interaction: AgentInteraction) async throws -> String {
    if text == "wait" {
      while true {
        try await Task.sleep(for: .milliseconds(10))
        try interaction.cancellation.check()
      }
    }
    if text == "permission" || text == "permission-diff" || text == "read-buffer" {
      let call = ParsedToolCall(
        id: "tool-test", name: "read_file", arguments: .object(["path": .string("draft.swift")]),
        argumentsJSON: "{}")
      interaction.tool(call, "pending", nil)
      let diff = text == "permission-diff" ? "--- a/draft.swift\n+++ b/draft.swift" : nil
      let allowed = await interaction.approve(call, diff)
      try interaction.cancellation.check()
      if allowed {
        interaction.tool(call, "in_progress", nil)
        let value =
          text == "read-buffer"
          ? try await interaction.readFile?("/tmp/draft.swift") ?? "missing" : "approved"
        interaction.text(value)
        interaction.tool(call, "completed", value)
      } else {
        interaction.text("denied")
        interaction.tool(call, "failed", "denied")
      }
    } else {
      interaction.text("first ")
      interaction.text(text)
    }
    completed += 1
    return "end_turn"
  }
}

final class ACPTests: XCTestCase, @unchecked Sendable {
  private func send(
    _ server: ACPServer, _ method: String, id: Int64? = nil, params: ACPObject = [:]
  ) async throws {
    var object: ACPObject = [
      "jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params),
    ]
    if let id { object["id"] = .integer(id) }
    await server.receive(try JSONEncoder().encode(object))
  }

  private func ready(capabilities: JSONValue = .object([:])) async throws -> (
    ACPServer, ACPInbox, String
  ) {
    let inbox = ACPInbox()
    let server = ACPServer(backend: ScriptedACPBackend(), send: { inbox.append($0) })
    try await send(
      server, "initialize", id: 1,
      params: ["protocolVersion": .integer(1), "clientCapabilities": capabilities])
    try await send(
      server, "session/new", id: 2, params: ["cwd": .string("/tmp"), "mcpServers": .array([])])
    let reply = try await inbox.wait { $0["id"] == .integer(2) }
    return (server, inbox, try XCTUnwrap(reply["result"]?["sessionId"]?.string))
  }

  private func prompt(_ server: ACPServer, session: String, text: String, id: Int64 = 3)
    async throws
  {
    try await send(
      server, "session/prompt", id: id,
      params: [
        "sessionId": .string(session),
        "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
      ])
  }

  func testHandshakeCommandsAndStreamingOrder() async throws {
    let (server, inbox, session) = try await ready()
    let initialized = try await inbox.wait { $0["id"] == .integer(1) }
    XCTAssertEqual(initialized["result"]?["protocolVersion"], .integer(1))
    XCTAssertEqual(
      initialized["result"]?["agentCapabilities"]?["mcpCapabilities"]?["sse"], .bool(false))
    XCTAssertTrue(
      inbox.messages.contains {
        $0["params"]?["update"]?["sessionUpdate"]?.string == "available_commands_update"
      })
    try await prompt(server, session: session, text: "hello")
    let result = try await inbox.wait { $0["id"] == .integer(3) }
    XCTAssertEqual(result["result"]?["stopReason"]?.string, "end_turn")
    let chunks = inbox.messages.compactMap { $0["params"]?["update"]?["content"]?["text"]?.string }
    XCTAssertEqual(chunks, ["first ", "hello"])
    XCTAssertEqual(inbox.messages.last?["id"], .integer(3))
    await server.close()
  }

  func testProtocolErrorsAndUnsupportedImagesFailBeforeGeneration() async throws {
    let (server, inbox, session) = try await ready()
    await server.receive(Data("{".utf8))
    _ = try await inbox.wait { $0["error"]?["code"] == .integer(-32700) }
    try await send(
      server, "session/prompt", id: 8,
      params: [
        "sessionId": .string(session),
        "prompt": .array([.object(["type": .string("image"), "data": .string("ignored")])]),
      ])
    let rejected = try await inbox.wait { $0["id"] == .integer(8) }
    XCTAssertEqual(rejected["error"]?["code"], .integer(-32602))
    try await send(server, "session/load", id: 9)
    let unsupported = try await inbox.wait { $0["id"] == .integer(9) }
    XCTAssertEqual(unsupported["error"]?["code"], .integer(-32601))
    let count = inbox.messages.count
    try await send(server, "unknown/notification")
    XCTAssertEqual(inbox.messages.count, count)
    await server.close()
  }

  func testPermissionsAreDeniedUnlessExplicitlyAllowed() async throws {
    for option in ["reject-once", "unknown", "allow-once"] {
      let (server, inbox, session) = try await ready()
      try await prompt(server, session: session, text: "permission")
      let permission = try await inbox.wait { $0["method"]?.string == "session/request_permission" }
      XCTAssertEqual(
        permission["params"]?["toolCall"]?["locations"]?.array?.first?["path"]?.string,
        "/tmp/draft.swift")
      await server.receive(
        try JSONEncoder().encode(
          JSONValue.object([
            "jsonrpc": .string("2.0"), "id": permission["id"]!,
            "result": .object([
              "outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])
            ]),
          ])))
      _ = try await inbox.wait { $0["id"] == .integer(3) }
      let texts = inbox.messages.compactMap { $0["params"]?["update"]?["content"]?["text"]?.string }
      XCTAssertEqual(texts, [option == "allow-once" ? "approved" : "denied"])
      await server.close()
    }
  }

  func testWriteDiffIsIncludedInPermissionRequest() async throws {
    let (server, inbox, session) = try await ready()
    try await prompt(server, session: session, text: "permission-diff")
    let permission = try await inbox.wait { $0["method"]?.string == "session/request_permission" }
    let diff = permission["params"]?["toolCall"]?["content"]?.array?.first?["content"]?["text"]?
      .string
    XCTAssertEqual(diff, "--- a/draft.swift\n+++ b/draft.swift")
    await server.receive(
      try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"), "id": permission["id"]!,
          "result": .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("reject-once")])
          ]),
        ])))
    _ = try await inbox.wait { $0["id"] == .integer(3) }
    await server.close()
  }

  func testCancellationResolvesPendingPermissionAndAllowsNextTurn() async throws {
    let (server, inbox, session) = try await ready()
    try await prompt(server, session: session, text: "permission")
    let permission = try await inbox.wait { $0["method"]?.string == "session/request_permission" }
    try await send(server, "session/cancel", params: ["sessionId": .string(session)])
    let cancelled = try await inbox.wait { $0["id"] == .integer(3) }
    XCTAssertEqual(cancelled["result"]?["stopReason"]?.string, "cancelled")
    // Late permission responses cannot authorize the next turn.
    await server.receive(
      try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"), "id": permission["id"]!,
          "result": .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("allow-once")])
          ]),
        ])))
    try await prompt(server, session: session, text: "next", id: 4)
    _ = try await inbox.wait { $0["id"] == .integer(4) }
    XCTAssertFalse(
      inbox.messages.contains { $0["params"]?["update"]?["content"]?["text"]?.string == "approved" }
    )
    await server.close()
  }

  func testDisconnectCancelsPendingPermission() async throws {
    let (server, inbox, session) = try await ready()
    try await prompt(server, session: session, text: "permission")
    _ = try await inbox.wait { $0["method"]?.string == "session/request_permission" }
    await server.close()
    let result = try await inbox.wait { $0["id"] == .integer(3) }
    XCTAssertEqual(result["result"]?["stopReason"]?.string, "cancelled")
  }

  func testOnlyOneGenerationAndCancellationWorksWhileBusy() async throws {
    let (server, inbox, session) = try await ready()
    try await prompt(server, session: session, text: "wait")
    try await prompt(server, session: session, text: "second", id: 4)
    let busy = try await inbox.wait { $0["id"] == .integer(4) }
    XCTAssertNotNil(busy["error"])
    try await send(server, "session/cancel", params: ["sessionId": .string(session)])
    let cancelled = try await inbox.wait { $0["id"] == .integer(3) }
    XCTAssertEqual(cancelled["result"]?["stopReason"]?.string, "cancelled")
    await server.close()
  }

  func testClientFileCapabilityUsesEditorBuffer() async throws {
    let (server, inbox, session) = try await ready(
      capabilities: .object(["fs": .object(["readTextFile": .bool(true)])]))
    try await prompt(server, session: session, text: "read-buffer")
    let permission = try await inbox.wait { $0["method"]?.string == "session/request_permission" }
    await server.receive(
      try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"), "id": permission["id"]!,
          "result": .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("allow-once")])
          ]),
        ])))
    let read = try await inbox.wait { $0["method"]?.string == "fs/read_text_file" }
    await server.receive(
      try JSONEncoder().encode(
        JSONValue.object([
          "jsonrpc": .string("2.0"), "id": read["id"]!,
          "result": .object(["content": .string("unsaved buffer")]),
        ])))
    _ = try await inbox.wait { $0["id"] == .integer(3) }
    XCTAssertTrue(
      inbox.messages.contains {
        $0["params"]?["update"]?["content"]?["text"]?.string == "unsaved buffer"
      })
    await server.close()
  }

  func testPromptContentAndMCPConfiguration() throws {
    let input = try ACPInput.prompt(
      .array([
        .object(["type": .string("text"), "text": .string("Review")]),
        .object([
          "type": .string("resource_link"), "name": .string("file"),
          "uri": .string("file:///tmp/a.swift"),
        ]),
        .object([
          "type": .string("resource"),
          "resource": .object(["uri": .string("file:///tmp/b.swift"), "text": .string("unsaved")]),
        ]),
      ]))
    XCTAssertTrue(input.contains("file:///tmp/a.swift"))
    XCTAssertTrue(input.contains("unsaved"))
    let servers = try ACPInput.servers(
      .array([
        .object([
          "type": .string("http"), "name": .string("remote"),
          "url": .string("https://example.com/mcp"),
          "headers": .array([
            .object(["name": .string("Authorization"), "value": .string("fake-token")])
          ]),
        ])
      ]))
    XCTAssertEqual(try servers["remote"]?.resolvedHeaders()["authorization"], "fake-token")
    XCTAssertThrowsError(
      try ACPInput.servers(.array([.object(["name": .string("legacy"), "type": .string("sse")])])))
  }

  func testSessionCatalogCannotRouteReservedToolsToMCP() {
    let definitions =
      ToolRegistry.baseDefinitions + [
        AgentToolDefinition(name: "remote", description: "", parameters: .object([:]))
      ]
    XCTAssertFalse(ToolRegistry.isMCPTool("read_file", definitions: definitions))
    XCTAssertFalse(ToolRegistry.isMCPTool("write_file", definitions: definitions))
    XCTAssertFalse(ToolRegistry.isMCPTool("unknown", definitions: definitions))
    XCTAssertTrue(ToolRegistry.isMCPTool("remote", definitions: definitions))
  }

  func testShellCancellationStopsPromptly() async throws {
    let cancellation = AgentCancellation()
    let task = Task {
      try await ShellCommand.run(
        "sleep 30", directory: URL(fileURLWithPath: "/tmp"), cancellation: cancellation)
    }
    try await Task.sleep(for: .milliseconds(100))
    let start = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testStdioMCPInitializationCanBeCancelled() async throws {
    let transport = try MCPStdioTransport(
      name: "unresponsive", command: "/bin/sh", args: ["-c", "sleep 30"], env: nil)
    let task = Task { await transport.listTools() }
    try await Task.sleep(for: .milliseconds(100))
    let start = Date()
    task.cancel()
    let tools = await task.value
    XCTAssertTrue(tools.isEmpty)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }
}

import XCTest
@testable import TurboAgentCore

final class MCPStdioTransportTests: XCTestCase, @unchecked Sendable {
    func testHandshakePaginationNotificationsAndToolResult() async throws {
        let script = #"""
        [ "$ACP_MCP_FIXTURE" = "configured" ] || exit 2
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/message","params":{}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":10,"result":{"protocolVersion":"wrong-id"}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26"}}'
        IFS= read -r notification
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"first","inputSchema":{"type":"object"}}],"nextCursor":"page2"}}'
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"second","inputSchema":{"type":"object"}}]}}'
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}}'
        cat >/dev/null
        """#
        let transport = try MCPStdioTransport(name: "fixture", command: "/bin/sh", args: ["-c", script],
                                              env: ["ACP_MCP_FIXTURE": "configured"], directory: URL(fileURLWithPath: "/tmp"))
        let tools = await transport.listTools()
        XCTAssertEqual(tools.map(\.name), ["first", "second"])
        XCTAssertEqual(tools.first?.description, "")
        let result = await transport.callTool(name: "first", argsJson: "{}")
        XCTAssertEqual(result, "one\ntwo")
    }

    func testShellUsesExplicitWorkingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await ShellCommand.run("pwd", directory: root, cancellation: nil)
        XCTAssertEqual(URL(fileURLWithPath: result.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }
}

import Foundation
import XCTest
@testable import TurboAgentCore

final class MCPConfigTests: XCTestCase {
    private func server(_ json: String) throws -> AgentMCPConfig.ServerConfig {
        try JSONDecoder().decode(AgentMCPConfig.ServerConfig.self, from: Data(json.utf8))
    }

    func testEnvironmentHeaderIsResolvedVerbatimAndOverridesStaticHeader() throws {
        let config = try server(#"{"url":"https://example.com/mcp","headers":{"Authorization":"old"},"http_headers":{"X-Static":"literal $VALUE"},"env_http_headers":{"authorization":"BUGCROWD_MCP_AUTH"}}"#)
        let headers = try config.resolvedHeaders(environment: ["BUGCROWD_MCP_AUTH": "Bearer example-$literal"])
        XCTAssertEqual(headers, ["authorization": "Bearer example-$literal", "x-static": "literal $VALUE"])
    }

    func testMissingAndEmptyEnvironmentRejectServerWithoutLeakingValues() throws {
        let config = try server(#"{"env_http_headers":{"Authorization":"BUGCROWD_MCP_AUTH"}}"#)
        for environment in [[:], ["BUGCROWD_MCP_AUTH": ""]] {
            XCTAssertThrowsError(try config.resolvedHeaders(environment: environment)) { error in
                XCTAssertEqual(String(describing: error), "Required MCP header environment variable BUGCROWD_MCP_AUTH is unset or empty")
            }
        }
    }

    func testStdioAndHTTPStaticHeadersStillDecode() throws {
        let config = try JSONDecoder().decode(AgentMCPConfig.self, from: Data(#"{"mcpServers":{"local":{"command":"example","args":["--stdio"],"env":{"MODE":"test"}},"remote":{"type":"http","url":"https://example.com/mcp","headers":{"X-Key":"static"}}}}"#.utf8))
        XCTAssertEqual(config.mcpServers?["local"]?.command, "example")
        XCTAssertEqual(config.mcpServers?["local"]?.env, ["MODE": "test"])
        XCTAssertEqual(try config.mcpServers?["remote"]?.resolvedHeaders(environment: [:]), ["x-key": "static"])
    }
}

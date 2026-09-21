import Foundation
import XCTest
@testable import TurboFieldfareAgentCore

final class MCPToolSchemaTests: XCTestCase, @unchecked Sendable {
    private func tool(_ schema: String, name: String = "mcp_probe") throws -> AgentToolDefinition {
        .init(name: name, description: "Probe MCP schema rendering",
              parameters: try JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8)))
    }

    func testMCPNullableAndBareObjectSchemasRemainAPICompatible() throws {
        let raw = try tool(#"""
        {"type":"object","properties":{
          "filter":{"type":["string","null"],"description":"Optional filter"},
          "options":{"type":"object","additionalProperties":false,"title":"Options"},
          "limit":{"anyOf":[{"type":"integer"},{"type":"null"}],"default":null}
        }}
        """#)
        let adapted = ToolRegistry.adaptedMCPTools([raw]) { XCTFail($0) }
        XCTAssertEqual(adapted.count, 1)
        XCTAssertEqual(adapted.first, raw)
        XCTAssertTrue(MCPJSONSchemaBridge().formatToolCatalog(tools: adapted).contains("mcp_probe"))
    }

    func testUnsupportedSchemaIsReportedWithoutRemovingOtherTools() throws {
        let unsupported = try tool(#"["not-an-object"]"#, name: "unsupported")
        let supported = try tool(#"{"type":"object"}"#, name: "supported")
        var errors: [String] = []
        let result = ToolRegistry.adaptedMCPTools([unsupported, supported]) { errors.append($0) }
        XCTAssertEqual(result.map(\.name), ["supported"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("unsupported"))
        XCTAssertEqual(result.first?.parameters, .object(["type": .string("object")]))
    }
}

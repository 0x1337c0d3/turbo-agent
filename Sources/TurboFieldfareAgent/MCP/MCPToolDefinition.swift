import Foundation

enum MCPToolDefinition {
    static func decode(_ tool: [String: Any]) throws -> AgentToolDefinition? {
        guard let name = tool["name"] as? String, let schema = tool["inputSchema"] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: schema)
        let parameters = try JSONDecoder().decode(JSONValue.self, from: data)
        return .init(name: name, description: tool["description"] as? String ?? "", parameters: parameters)
    }
}

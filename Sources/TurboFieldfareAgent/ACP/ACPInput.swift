import Foundation

enum ACPInput {
    static func prompt(_ value: JSONValue?) throws -> String {
        guard let blocks = value?.array, !blocks.isEmpty else { throw ACPError.invalid("prompt must contain content") }
        return try blocks.map { block in
            guard let object = block.objectValue else { throw ACPError.invalid("Invalid content block") }
            switch try object.requiredString("type") {
            case "text": return try object.requiredString("text")
            case "resource_link":
                let uri = try object.requiredString("uri")
                let name = try object.requiredString("name")
                return "[Resource link: \(name)]\n\(uri)\nUse an appropriate tool to read this resource if needed."
            case "resource":
                guard let resource = object["resource"]?.objectValue,
                      resource["blob"] == nil else { throw ACPError.invalid("Only embedded text resources are supported") }
                return "[Resource: \(try resource.requiredString("uri"))]\n\(try resource.requiredString("text"))"
            default: throw ACPError.invalid("Unsupported content: image/audio support is unavailable in this agent")
            }
        }.joined(separator: "\n\n")
    }

    static func directory(_ object: ACPObject) throws -> URL {
        let path = try object.requiredString("cwd")
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ACPError.invalid("cwd must be an existing absolute directory") }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func servers(_ value: JSONValue?) throws -> [String: AgentMCPConfig.ServerConfig] {
        guard let servers = value?.array, servers.count <= 32 else { throw ACPError.invalid("Invalid mcpServers") }
        var result: [String: AgentMCPConfig.ServerConfig] = [:]
        for server in servers {
            guard let object = server.objectValue else { throw ACPError.invalid("Invalid MCP server") }
            let name = try object.requiredString("name")
            guard !name.isEmpty, result[name] == nil else { throw ACPError.invalid("Duplicate or empty MCP server name") }
            var config: ACPObject = [:]
            switch object["type"]?.string ?? "stdio" {
            case "stdio":
                let command = try object.requiredString("command")
                guard !command.isEmpty, let args = object["args"]?.array,
                      args.allSatisfy({ $0.string != nil }) else { throw ACPError.invalid("Invalid MCP command/args") }
                config = ["command": .string(command), "args": .array(args),
                          "env": .object(try pairs(object["env"]))]
            case "http":
                let urlString = try object.requiredString("url")
                guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme),
                      url.host != nil, url.user == nil, url.password == nil else { throw ACPError.invalid("Invalid MCP HTTP URL") }
                config = ["type": .string("http"), "url": .string(urlString),
                          "headers": .object(try pairs(object["headers"]))]
            default: throw ACPError.invalid("Only stdio and streamable HTTP MCP are supported")
            }
            result[name] = try JSONDecoder().decode(AgentMCPConfig.ServerConfig.self, from: JSONEncoder().encode(config))
        }
        return result
    }

    private static func pairs(_ value: JSONValue?) throws -> ACPObject {
        guard let entries = value?.array else { throw ACPError.invalid("Expected name/value array") }
        var pairs: ACPObject = [:]
        for entry in entries {
            guard let object = entry.objectValue else { throw ACPError.invalid("Invalid name/value entry") }
            pairs[try object.requiredString("name")] = .string(try object.requiredString("value"))
        }
        return pairs
    }
}

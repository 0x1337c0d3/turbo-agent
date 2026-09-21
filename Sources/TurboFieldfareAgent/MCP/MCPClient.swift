import Foundation

protocol MCPServerTransport: Sendable {
    var name: String { get }
    var connectionDetails: String { get }
    func callTool(name: String, argsJson: String) async -> String
    func listTools() async -> [AgentToolDefinition]
}

final class MCPClient: @unchecked Sendable {
    nonisolated(unsafe) static var _shared_mcp_client: MCPClient? = MCPClient()
    static var shared: MCPClient? {
        get { return _shared_mcp_client }
        set { _shared_mcp_client = newValue }
    }

    var servers: [MCPServerTransport] = []
    private var toolServers: [String: MCPServerTransport] = [:]

    convenience init?() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".config/TurboFieldfareAgent")
        let configURL = configDir.appendingPathComponent("settings.json")

        if !FileManager.default.fileExists(atPath: configURL.path) {
            do {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                let defaultJson = """
                {
                  "mcpServers": {
                    "codex-nav": {
                      "command": "codex-nav-mcp-server",
                      "args": [],
                      "env": {}
                    }
                  }
                }
                """
                try defaultJson.write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                printColor("Failed to create default MCP config: \(error)" + "\n", color: "yellow")
            }
        }

        guard let data = try? Data(contentsOf: configURL) else {
            printColor("MCP server config not found at \(configURL.path)" + "\n", color: "yellow")
            return nil
        }

        guard let config = try? JSONDecoder().decode(AgentMCPConfig.self, from: data), let mcpServers = config.mcpServers else {
            printColor("Invalid MCP config format in \(configURL.path)" + "\n", color: "yellow")
            return nil
        }

        self.init(configurations: mcpServers, directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if servers.isEmpty { return nil }
    }

    static func localConfigurations() -> [String: AgentMCPConfig.ServerConfig] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/TurboFieldfareAgent/settings.json")
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(AgentMCPConfig.self, from: data) else { return [:] }
        return config.mcpServers ?? [:]
    }

    init(configurations: [String: AgentMCPConfig.ServerConfig], directory: URL) {
        for (name, serverConfig) in configurations.sorted(by: { $0.key < $1.key }) {
            if serverConfig.type == "sse" {
                printColor("Skipping MCP server \(name): legacy SSE is no longer supported. Use a Streamable HTTP endpoint with type 'http' or omit type.\n", color: "yellow")
                continue
            }
            if let urlString = serverConfig.url {
                guard let url = URL(string: urlString),
                      let scheme = url.scheme, ["http", "https"].contains(scheme),
                      url.host != nil else {
                    printColor("Invalid MCP URL for \(name)" + "\n", color: "yellow")
                    continue
                }
                do {
                    let headers = try serverConfig.resolvedHeaders()
                    switch serverConfig.type {
                    case nil, "http", "streamable-http":
                        servers.append(MCPHTTPTransport(name: name, url: url, headers: headers))
                    default:
                        printColor("Unsupported MCP transport for \(name)" + "\n", color: "yellow")
                    }
                } catch {
                    printColor("Skipping MCP server \(name): \(error)" + "\n", color: "yellow")
                }
            } else if let command = serverConfig.command {
                do {
                    let server = try MCPStdioTransport(name: name, command: command, args: serverConfig.args ?? [], env: serverConfig.env, directory: directory)
                    servers.append(server)
                } catch {
                    printColor("Failed to start MCP server \(name): \(error)" + "\n", color: "yellow")
                }
            }
        }

    }

    func listAllTools() async -> [AgentToolDefinition] {
        var allTools: [AgentToolDefinition] = []
        toolServers.removeAll()
        for server in servers {
            let tools = await server.listTools()
            for tool in tools where toolServers[tool.name] == nil {
                toolServers[tool.name] = server
                allTools.append(tool)
            }
        }
        return allTools
    }

    func callTool(name: String, argsJson: String) async -> String {
        guard let server = toolServers[name] else {
            return "Error: Tool \(name) is not in the discovered MCP tool catalog."
        }
        return await server.callTool(name: name, argsJson: argsJson)
    }
}

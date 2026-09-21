import Foundation

/// Request/response Streamable HTTP MCP, including SSE response bodies.
actor MCPHTTPTransport: MCPServerTransport {
    let name: String
    let url: URL
    let headers: [String: String]
    private var sessionID: String?
    private var initialized = false
    private var requestID = 0
    private var protocolVersion = "2025-03-26"
    private let session: URLSession

    nonisolated var connectionDetails: String { url.absoluteString }

    init(name: String, url: URL, headers: [String: String], session: URLSession = MCPNetworkPolicy.session()) {
        self.name = name
        self.url = url
        self.headers = headers
        self.session = session
    }

    private struct TransportError: Error, CustomStringConvertible {
        let description: String
    }

    private func send(method: String, params: [String: Any] = [:], notification: Bool = false) async throws -> [String: Any] {
        requestID += 1
        let id = requestID
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { body["id"] = id }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if initialized { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw TransportError(description: "Invalid HTTP response")
        }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 404 { initialized = false; sessionID = nil }
            throw TransportError(description: "MCP HTTP status \(response.statusCode)")
        }
        if method == "initialize" { sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") }
        if notification { return [:] }

        func matchingResponse(_ data: Data) throws -> [String: Any]? {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["id"] as? Int == id else { return nil }
            if let error = object["error"] as? [String: Any] {
                // Do not echo server response bodies, which can contain credentials.
                throw TransportError(description: "MCP JSON-RPC error \(error["code"] as? Int ?? 0)")
            }
            return object["result"] as? [String: Any]
        }

        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            var dataLines: [String] = []
            for try await line in bytes.lines {
                if line.isEmpty {
                    if !dataLines.isEmpty,
                       let result = try matchingResponse(Data(dataLines.joined(separator: "\n").utf8)) { return result }
                    dataLines.removeAll()
                } else if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5))
                    if value.hasPrefix(" ") { value.removeFirst() }
                    dataLines.append(value)
                }
            }
            if !dataLines.isEmpty,
               let result = try matchingResponse(Data(dataLines.joined(separator: "\n").utf8)) { return result }
        } else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            if let result = try matchingResponse(data) { return result }
        }
        throw TransportError(description: "MCP response missing matching result")
    }

    private func initialize() async throws {
        guard !initialized else { return }
        let result = try await send(method: "initialize", params: [
            "protocolVersion": "2025-03-26", "capabilities": [:] as [String: String],
            "clientInfo": ["name": "turbo-agent", "version": "1.0.0"]
        ])
        guard let version = result["protocolVersion"] as? String,
              ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else {
            throw TransportError(description: "Unsupported MCP protocol version")
        }
        protocolVersion = version
        _ = try await send(method: "notifications/initialized", notification: true)
        initialized = true
    }

    func listTools() async -> [AgentToolDefinition] {
        do {
            try await initialize()
            var definitions: [AgentToolDefinition] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let result = try await send(method: "tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
                for tool in result["tools"] as? [[String: Any]] ?? [] {
                    if let definition = try MCPToolDefinition.decode(tool) {
                        definitions.append(definition)
                    }
                }
                cursor = result["nextCursor"] as? String
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw TransportError(description: "Repeated MCP pagination cursor")
                }
            } while cursor != nil
            return definitions
        } catch {
            printColor("Failed to list MCP tools for \(name): \(error)\n", color: "yellow")
            return []
        }
    }

    func callTool(name: String, argsJson: String) async -> String {
        do {
            try await initialize()
            let arguments = try JSONSerialization.jsonObject(with: Data(argsJson.utf8))
            let result = try await send(method: "tools/call", params: ["name": name, "arguments": arguments])
            let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { return text }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "Error calling MCP tool: \(error)"
        }
    }
}

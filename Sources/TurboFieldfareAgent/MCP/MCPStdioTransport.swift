import Foundation

/// All process/RPC state is confined to queue. Cancellation tokens are locked.
final class MCPStdioTransport: MCPServerTransport, @unchecked Sendable {
    let name: String
    let connectionDetails: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "agent.mcp.stdio")
    private var requestID = 0
    private var initialized = false
    private var buffer = Data()

    init(name: String, command: String, args: [String], env: [String: String]?, directory: URL? = nil) throws {
        self.name = name
        self.connectionDetails = ([command] + args).joined(separator: " ")
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            process.executableURL = URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [expanded] + args
        }
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(env ?? [:]) { _, value in value }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        ProcessIO.nonblocking(input.fileHandleForWriting)
        ProcessIO.nonblocking(output.fileHandleForReading)
        // Broken pipes must become transport errors, not terminate the agent.
        signal(SIGPIPE, SIG_IGN)
    }

    deinit { ProcessIO.stop(process) }

    private func send(_ object: [String: Any], token: AgentCancellation, deadline: ContinuousClock.Instant) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(10)
        try ProcessIO.write(bytes, to: input.fileHandleForWriting, cancellation: token, deadline: deadline)
    }

    private func line(token: AgentCancellation, deadline: ContinuousClock.Instant) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard let bytes = try ProcessIO.read(from: output.fileHandleForReading, cancellation: token, deadline: deadline) else {
                throw ACPError.disconnected
            }
            buffer.append(bytes)
            guard buffer.count <= 8 * 1024 * 1024 else { throw ACPError.invalid("MCP response too large") }
        }
    }

    private func rpc(_ method: String, params: [String: Any], token: AgentCancellation) throws -> [String: Any] {
        try token.check()
        guard process.isRunning else { throw ACPError.disconnected }
        requestID += 1
        let id = requestID
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], token: token, deadline: deadline)
        while true {
            let data = try line(token: token, deadline: deadline)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["method"] != nil {
                // This agent does not implement MCP sampling/elicitation requests.
                if let incomingID = object["id"] {
                    try send(["jsonrpc": "2.0", "id": incomingID,
                              "error": ["code": -32601, "message": "Method not supported"]], token: token, deadline: deadline)
                }
                continue
            }
            guard MCPRPC.matches(String(decoding: data, as: UTF8.self), id: id) else { continue }
            guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
                throw ACPError(code: -32000, message: "MCP request failed")
            }
            return result
        }
    }

    private func initialize(token: AgentCancellation) throws {
        guard !initialized else { return }
        let result = try rpc("initialize", params: [
            "protocolVersion": "2025-03-26", "capabilities": [:] as [String: String],
            "clientInfo": ["name": "TurboFieldfareAgent", "version": "1.0.0"]
        ], token: token)
        guard let version = result["protocolVersion"] as? String,
              ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else {
            throw ACPError.invalid("Unsupported MCP version")
        }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token,
                 deadline: ContinuousClock.now.advanced(by: .seconds(60)))
        initialized = true
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (AgentCancellation) throws -> T) async throws -> T {
        let token = AgentCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try self.initialize(token: token)
                        continuation.resume(returning: try operation(token))
                    } catch {
                        // A cancelled/timed-out stream has ambiguous response state.
                        ProcessIO.stop(self.process)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { token.cancel() }
    }

    func listTools() async -> [AgentToolDefinition] {
        do {
            return try await perform { token in
                var tools: [AgentToolDefinition] = []
                var cursor: String?
                var seen = Set<String>()
                repeat {
                    let result = try self.rpc("tools/list", params: cursor.map { ["cursor": $0] } ?? [:], token: token)
                    tools += try (result["tools"] as? [[String: Any]] ?? []).compactMap(MCPToolDefinition.decode)
                    cursor = result["nextCursor"] as? String
                    if let cursor, !seen.insert(cursor).inserted { throw ACPError.invalid("Repeated MCP cursor") }
                } while cursor != nil
                return tools
            }
        } catch { return [] }
    }

    func callTool(name: String, argsJson: String) async -> String {
        do {
            return try await perform { token in
                let arguments = try JSONSerialization.jsonObject(with: Data(argsJson.utf8))
                let result = try self.rpc("tools/call", params: ["name": name, "arguments": arguments], token: token)
                let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                return result["isError"] as? Bool == true ? "Error: \(text)" : text
            }
        } catch { return "Error: MCP request failed or was cancelled" }
    }
}

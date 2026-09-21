import Foundation

actor ACPServer {
    private let backend: any ACPBackend
    let channel: ACPChannel
    private var initialized = false
    private var clientCapabilities: JSONValue = .object([:])
    private var sessions: [String: URL] = [:]
    private struct ActiveTurn {
        let session: String
        let cancellation: AgentCancellation
        let task: Task<Void, Never>
    }
    private var active: ActiveTurn?

    init(backend: any ACPBackend, send: @escaping ACPChannel.Send) {
        self.backend = backend
        self.channel = ACPChannel(send: send)
    }

    func receive(_ data: Data) async {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { reply(id: .null, error: ACPError(code: -32700, message: "Parse error")); return }
        guard let object = value.objectValue, object["jsonrpc"] == .string("2.0") else {
            reply(id: .null, error: ACPError(code: -32600, message: "Invalid request")); return
        }
        if object["method"] == nil {
            await channel.receive(object)
            return
        }
        guard let method = object["method"]?.string else {
            reply(id: object["id"] ?? .null, error: ACPError(code: -32600, message: "Invalid method")); return
        }
        let params = object["params"]?.objectValue ?? [:]
        guard let id = object["id"] else {
            if method == "session/cancel", let session = params["sessionId"]?.string { await cancel(session) }
            return // Notifications never receive replies.
        }
        guard id.rpcID != nil else {
            reply(id: .null, error: ACPError(code: -32600, message: "Invalid request ID")); return
        }
        do {
            if method == "initialize" {
                guard !initialized else { throw ACPError.invalid("Already initialized") }
                guard case .integer(let version) = params["protocolVersion"], version > 0 else {
                    throw ACPError.invalid("Missing protocolVersion")
                }
                clientCapabilities = params["clientCapabilities"] ?? .object([:])
                initialized = true
                reply(id: id, result: .object([
                    "protocolVersion": .integer(1),
                    "agentInfo": .object(["name": .string("TurboAgent"), "title": .string("Turbo"), "version": .string("1.0.0")]),
                    "authMethods": .array([]), "agentCapabilities": .object([
                        "loadSession": .bool(false),
                        "promptCapabilities": .object(["image": .bool(false), "audio": .bool(false), "embeddedContext": .bool(true)]),
                        "mcpCapabilities": .object(["http": .bool(true), "sse": .bool(false)])
                    ])
                ]))
                return
            }
            guard initialized else { throw ACPError(code: -32000, message: "Initialize first") }
            switch method {
            case "session/new": try await newSession(id: id, params: params)
            case "session/prompt": try startPrompt(id: id, params: params)
            default: throw ACPError(code: -32601, message: "Method not supported: \(method)")
            }
        } catch { reply(id: id, error: error) }
    }

    private func newSession(id: JSONValue, params: ACPObject) async throws {
        guard active == nil else { throw ACPError(code: -32000, message: "Wait for the active turn before creating a session") }
        guard sessions.count < 32 else { throw ACPError(code: -32000, message: "Session limit reached; restart the agent") }
        let directory = try ACPInput.directory(params)
        let servers = try ACPInput.servers(params["mcpServers"])
        let session = UUID().uuidString
        let skills = try await backend.newSession(id: session, directory: directory, servers: servers)
        sessions[session] = directory
        reply(id: id, result: .object(["sessionId": .string(session)]))
        let commands: [JSONValue] = (["skills"] + skills.filter { $0 != "skills" }).map { name in
            .object(["name": .string(name), "description": .string(name == "skills" ? "List available skills" : "Load the \(name) skill"),
                     "input": .object(["hint": .string("Request for this skill")])])
        }
        channel.update(session: session, ["sessionUpdate": .string("available_commands_update"), "availableCommands": .array(commands)])
    }

    private func startPrompt(id: JSONValue, params: ACPObject) throws {
        let session = try params.requiredString("sessionId")
        guard let directory = sessions[session] else { throw ACPError.invalid("Unknown session") }
        guard active == nil else { throw ACPError(code: -32000, message: "Another turn is active; cancel it or wait") }
        let text = try ACPInput.prompt(params["prompt"])
        let cancellation = AgentCancellation()
        let interaction = ACPInteraction.make(session: session, directory: directory, capabilities: clientCapabilities,
                                               channel: channel, cancellation: cancellation)
        let task = Task {
            do {
                let stop = try await backend.prompt(session: session, text: text, interaction: interaction)
                self.finish(id: id, stop: cancellation.isCancelled ? "cancelled" : stop)
            } catch {
                if cancellation.isCancelled || error is CancellationError { self.finish(id: id, stop: "cancelled") }
                else { self.active = nil; self.reply(id: id, error: error) }
            }
        }
        active = ActiveTurn(session: session, cancellation: cancellation, task: task)
    }

    private func finish(id: JSONValue, stop: String) {
        active = nil
        reply(id: id, result: .object(["stopReason": .string(stop)]))
    }

    private func cancel(_ session: String) async {
        guard let active, active.session == session else { return }
        active.cancellation.cancel()
        active.task.cancel()
        await channel.cancel(session: session)
    }

    func close() async {
        if let active { await cancel(active.session) }
        await channel.close()
        await active?.task.value
    }

    private func reply(id: JSONValue, result: JSONValue) {
        channel.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func reply(id: JSONValue, error: Error) {
        let error = error as? ACPError ?? ACPError(code: -32603, message: String(describing: error))
        channel.send(.object(["jsonrpc": .string("2.0"), "id": id, "error": error.value]))
    }

    static func run(arguments: [String]) async throws {
        let transport = try ACPTransport()
        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousTerminate = signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { transport.stopInput() }
            source.resume()
            return source
        }
        defer {
            signals.forEach { $0.cancel() }
            signal(SIGINT, previousInterrupt)
            signal(SIGTERM, previousTerminate)
        }
        let server = ACPServer(backend: AgentCore(arguments: arguments), send: { transport.send($0) })
        do {
            for try await frame in transport.frames() { await server.receive(frame) }
        } catch {
            FileHandle.standardError.write(Data("ACP input closed: \(error)\n".utf8))
        }
        await server.close()
    }
}

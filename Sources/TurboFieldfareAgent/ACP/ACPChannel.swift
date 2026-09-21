import Foundation

/// Bidirectional RPC requests must remain serviceable while a prompt is running.
actor ACPChannel {
    typealias Send = @Sendable (JSONValue) -> Void
    nonisolated let send: Send
    private var sequence = 0
    private var closed = false
    private struct Pending {
        let session: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    init(send: @escaping Send) { self.send = send }

    func request(_ method: String, params: ACPObject, session: String,
                 cancellation: AgentCancellation) async throws -> JSONValue {
        try cancellation.check()
        guard !closed else { throw ACPError.disconnected }
        sequence += 1
        let id = "agent-\(sequence)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancellation.isCancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self.fail(id, error: ACPError(code: -32000, message: "Client request timed out"))
                }
                pending[id] = Pending(session: session, continuation: continuation, timeout: timeout)
                send(.object(["jsonrpc": .string("2.0"), "id": .string(id),
                              "method": .string(method), "params": .object(params)]))
            }
        } onCancel: {
            Task { await self.fail(id, error: CancellationError()) }
        }
    }

    func receive(_ object: ACPObject) {
        guard let id = object["id"]?.string, let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        if let result = object["result"], object["error"] == nil {
            request.continuation.resume(returning: result)
        } else {
            request.continuation.resume(throwing: ACPError(code: -32000, message: "Client request failed"))
        }
    }

    private func fail(_ id: String, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    func cancel(session: String) {
        for id in pending.filter({ $0.value.session == session }).map(\.key) {
            fail(id, error: CancellationError())
        }
    }

    func close() {
        closed = true
        for id in Array(pending.keys) { fail(id, error: ACPError.disconnected) }
    }

    nonisolated func update(session: String, _ update: ACPObject) {
        send(.object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
                      "params": .object(["sessionId": .string(session), "update": .object(update)])]))
    }
}

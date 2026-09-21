import Foundation

actor AgentManager {
    static let shared = AgentManager()

    struct SubagentState {
        let id: String
        let role: String
        var messages: [AgentMessage]
        var task: Task<String, Never>?
    }

    struct BackgroundTask {
        let id: String
        let description: String
        var task: Task<Void, Never>?
    }

    private var subagents: [String: SubagentState] = [:]
    private var subagentDefinitions: [String: String] = [:]
    private var tasks: [String: BackgroundTask] = [:]

    func defineSubagent(name: String, prompt: String) {
        subagentDefinitions[name] = prompt
    }

    func startSubagent(id: String, role: String, prompt: String, runtime: AgentRuntime, context: AgentToolContext) {
        var state = SubagentState(id: id, role: role, messages: [
            AgentMessage(role: .system, content: subagentDefinitions[role] ?? "You are a subagent.", toolCalls: [], toolCallID: nil, name: nil),
            AgentMessage(role: .user, content: prompt, toolCalls: [], toolCallID: nil, name: nil)
        ])

        let task = Task { [state] () -> String in
            var mutableState = state
            do {
                print("\n[Subagent \(id) started]")
                let result = try await AgentTurn.run(runtime: runtime, messages: &mutableState.messages, context: context, resultLimit: 200)
                print("\n[Subagent \(id) finished]: \(result)")
                return result
            } catch {
                print("\n[Subagent \(id) failed]: \(error)")
                return "Failed: \(error)"
            }
        }
        state.task = task
        subagents[id] = state
    }

    func sendMessage(id: String, message: String) async -> String {
        guard var state = subagents[id] else { return "Error: subagent \(id) not found" }
        state.messages.append(AgentMessage(role: .user, content: message, toolCalls: [], toolCallID: nil, name: nil))
        // Basic sync execution for messaging
        return "Message queued. Asynchronous chat requires full REPL integration."
    }

    func listSubagents() -> String {
        guard !subagents.isEmpty else { return "No active subagents." }
        return subagents.map { "\($0.key) (\($0.value.role))" }.joined(separator: "\n")
    }

    func startTask(id: String, description: String, block: @escaping @Sendable () async -> Void) {
        let task = Task {
            await block()
        }
        tasks[id] = BackgroundTask(id: id, description: description, task: task)
    }

    func listTasks() -> String {
        guard !tasks.isEmpty else { return "No background tasks." }
        return tasks.map { "\($0.key): \($0.value.description)" }.joined(separator: "\n")
    }
}

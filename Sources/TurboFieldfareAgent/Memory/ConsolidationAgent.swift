import Foundation
import ContinuityCore

enum ConsolidationAgent {
    static func run(
        runtime: AgentRuntime,
        memoryService: MemoryService,
        conversationHistory: [AgentMessage]
    ) async throws -> String {
        let config = await memoryService.configuration
        let charCount = conversationHistory.reduce(0) { $0 + ($1.content?.count ?? 0) }
        guard charCount >= config.consolidationMinimumCharacters else {
            return "Consolidation skipped: conversation too short."
        }

        let turnsToRead = min(conversationHistory.count, config.consolidationMaximumTurns)
        let recentHistory = Array(conversationHistory.suffix(turnsToRead))

        let systemPrompt = """
        Review the following conversation transcript.
        Extract durable architectural decisions, coding conventions, project constraints, and important state changes.
        Do not record casual chit-chat, temporary debugging, or raw code blocks unless explicitly meant as a long-term convention.
        Call `memory_set` to persist each durable fact. If an existing fact is modified, update it.
        Be concise and factual. When you are done extracting all facts, return a final summary of what was saved.
        """

        var messages = [
            AgentMessage(role: .system, content: systemPrompt, toolCalls: [], toolCallID: nil, name: nil)
        ]

        // Feed the recent history as a user transcript
        let transcript = recentHistory.map { "[\($0.role)] \($0.content ?? "")" }.joined(separator: "\n")
        messages.append(AgentMessage(role: .user, content: "Transcript:\n\(transcript)", toolCalls: [], toolCallID: nil, name: nil))

        // Force the agent to only have access to memory tools
        let context = AgentToolContext(
            directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            systemPrompt: systemPrompt,
            mcp: nil,
            definitions: await ToolRegistry.memoryDefinitions(service: memoryService),
            interaction: nil,
            memoryService: memoryService
        )

        // Use the shared conversation run loop
        let summary = try await AgentTurn.run(runtime: runtime, messages: &messages, context: context, resultLimit: 200, forceLocal: true)

        return summary
    }
}

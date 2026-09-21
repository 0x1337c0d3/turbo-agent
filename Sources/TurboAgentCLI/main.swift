import TurboAgentCore

@main
struct TurboAgentCLI {
  static func main() async throws {
    try await AgentCommand.run()
  }
}

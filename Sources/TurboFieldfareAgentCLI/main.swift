import TurboFieldfareAgentCore

@main
struct TurboFieldfareAgentCLI {
  static func main() async throws {
    try await AgentCommand.run()
  }
}

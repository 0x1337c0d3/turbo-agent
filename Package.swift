// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TurboAgent",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "TurboAgent", targets: ["TurboAgentCLI"]),
    .library(name: "TurboAgentCore", targets: ["TurboAgentCore"]),
    .executable(name: "TurboAgentMac", targets: ["TurboAgentMac"]),
  ],
  targets: [
    .target(
      name: "ContinuityCore",
      path: "Sources/ContinuityCore",
      exclude: ["README.md"]
    ),
    .target(
      name: "AgentLineEditor",
      linkerSettings: [.linkedLibrary("edit")]
    ),
    .target(
      name: "TurboAgentCore",
      dependencies: [
        "AgentLineEditor",
        "ContinuityCore",
      ],
      path: "Sources/TurboAgent"
    ),
    .executableTarget(
      name: "TurboAgentCLI",
      dependencies: ["TurboAgentCore"],
      path: "Sources/TurboAgentCLI"
    ),
    .executableTarget(
      name: "TurboAgentMac",
      dependencies: ["TurboAgentCore"],
      path: "Sources/TurboAgentApp"
    ),
    .testTarget(
      name: "TurboAgentTests",
      dependencies: ["TurboAgentCore"],
      path: "Tests/TurboAgent"
    ),
  ]
)

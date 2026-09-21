// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TurboFieldfareAgent",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "TurboFieldfareAgent", targets: ["TurboFieldfareAgentCLI"]),
    .library(name: "TurboFieldfareAgentCore", targets: ["TurboFieldfareAgentCore"]),
    .executable(name: "TurboFieldfareAgentMac", targets: ["TurboFieldfareAgentMac"]),
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
      name: "TurboFieldfareAgentCore",
      dependencies: [
        "AgentLineEditor",
        "ContinuityCore",
      ],
      path: "Sources/TurboFieldfareAgent"
    ),
    .executableTarget(
      name: "TurboFieldfareAgentCLI",
      dependencies: ["TurboFieldfareAgentCore"],
      path: "Sources/TurboFieldfareAgentCLI"
    ),
    .executableTarget(
      name: "TurboFieldfareAgentMac",
      dependencies: ["TurboFieldfareAgentCore"],
      path: "Sources/TurboFieldfareAgentApp"
    ),
    .testTarget(
      name: "TurboFieldfareAgentTests",
      dependencies: ["TurboFieldfareAgentCore"],
      path: "Tests/TurboFieldfareAgent"
    ),
  ]
)

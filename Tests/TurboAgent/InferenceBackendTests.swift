import Foundation
import XCTest

@testable import TurboAgentCore

final class InferenceBackendTests: XCTestCase, @unchecked Sendable {
  func testBackendParsing() throws {
    let configApple = try AgentConfig(arguments: ["--backend", "apple"])
    XCTAssertEqual(configApple.backend, .apple)

    let configOpenAI = try AgentConfig(arguments: ["--backend", "openai"])
    XCTAssertEqual(configOpenAI.backend, .openai)
  }

  func testInvalidBackendThrowsError() {
    XCTAssertThrowsError(try AgentConfig(arguments: ["--backend", "nonexistent"])) { error in
      guard case AgentConfigError.invalidBackend(let val) = error else {
        XCTFail("Expected AgentConfigError.invalidBackend, got \(error)")
        return
      }
      XCTAssertEqual(val, "nonexistent")
    }
  }

  func testPCCPolicyParsing() throws {
    let configAuto = try AgentConfig(arguments: ["--pcc", "auto"])
    XCTAssertEqual(configAuto.pccPolicy, .auto)

    let configDisable = try AgentConfig(arguments: ["--pcc", "disable"])
    XCTAssertEqual(configDisable.pccPolicy, .disable)

    let configRequire = try AgentConfig(arguments: ["--pcc", "require"])
    XCTAssertEqual(configRequire.pccPolicy, .require)
  }

  func testInvalidPCCPolicyThrowsError() {
    XCTAssertThrowsError(try AgentConfig(arguments: ["--pcc", "invalid_policy"])) { error in
      guard case AgentConfigError.invalidPCCPolicy(let val) = error else {
        XCTFail("Expected AgentConfigError.invalidPCCPolicy, got \(error)")
        return
      }
      XCTAssertEqual(val, "invalid_policy")
    }
  }

  func testLocalModelOptionsAreRejected() throws {
    XCTAssertThrowsError(try AgentConfig(arguments: ["--backend", "gemma"]))
    XCTAssertThrowsError(try AgentConfig(arguments: ["--model", "custom/model.gturbo"]))
  }

  func testMaxRoundsDefaultAndOverride() throws {
    let configDefault = try AgentConfig(arguments: [])
    XCTAssertEqual(configDefault.maxRounds, 32)
    XCTAssertNil(configDefault.explicitMaxRounds)

    let configCustom = try AgentConfig(arguments: ["--max-rounds", "64"])
    XCTAssertEqual(configCustom.maxRounds, 64)
    XCTAssertEqual(configCustom.explicitMaxRounds, 64)

    let configHigh = try AgentConfig(arguments: ["--max-rounds", "250"])
    XCTAssertEqual(configHigh.maxRounds, 250)
    XCTAssertEqual(configHigh.explicitMaxRounds, 250)

    XCTAssertThrowsError(try AgentConfig(arguments: ["--max-rounds", "-1"]))
  }

  func testOnlyAFMOnDeviceIsLocal() {
    XCTAssertFalse(AgentRuntime.ModelTarget.appleAutomatic.isLocal)
    XCTAssertTrue(AgentRuntime.ModelTarget.appleOnDevice.isLocal)
    XCTAssertFalse(AgentRuntime.ModelTarget.appleCloud.isLocal)
    XCTAssertFalse(AgentRuntime.ModelTarget.openai.isLocal)
  }

  func testContextBudgetLimitFollowsSelectedTargetNotStaleBackendCapability() {
    XCTAssertEqual(AgentRuntime.ModelTarget.appleAutomatic.contextLimit(fallback: 32_768), 8_192)
    XCTAssertEqual(AgentRuntime.ModelTarget.appleOnDevice.contextLimit(fallback: 32_768), 8_192)
    XCTAssertEqual(AgentRuntime.ModelTarget.appleCloud.contextLimit(fallback: 8_192), 32_768)
    XCTAssertEqual(AgentRuntime.ModelTarget.openai.contextLimit(fallback: 131_072), 131_072)
  }

  func testGUIClientCanCreateAndResetWithoutLoadingInference() async throws {
    XCTAssertEqual(
      AgentClientBackend.allCases,
      [.appleAutomatic, .appleOnDevice, .applePrivateCloud, .openAI])
    let client = try await AgentClient.make(backend: .openAI)
    try await client.newConversation()
    await client.cancel()
  }

  func testAppleBackendCapabilities() {
    let backendAuto = AppleFoundationModelBackend(pccPolicy: .auto, systemPrompt: "test")
    XCTAssertTrue(backendAuto.capabilities.supportsTools)
    XCTAssertTrue(backendAuto.capabilities.supportsStreaming)
    XCTAssertEqual(backendAuto.capabilities.maxContextLength, 8_192)
    XCTAssertTrue(backendAuto.capabilities.isOnDevice)
    XCTAssertTrue(backendAuto.capabilities.isPrivateCloudCompute)

    let backendDisable = AppleFoundationModelBackend(pccPolicy: .disable, systemPrompt: "test")
    XCTAssertTrue(backendDisable.capabilities.isOnDevice)
    XCTAssertFalse(backendDisable.capabilities.isPrivateCloudCompute)

    let backendRequire = AppleFoundationModelBackend(pccPolicy: .require, systemPrompt: "test")
    XCTAssertFalse(backendRequire.capabilities.isOnDevice)
    XCTAssertTrue(backendRequire.capabilities.isPrivateCloudCompute)

    // Verify memory threshold is 12 GB
    XCTAssertEqual(AppleFoundationModelBackend.advancedModelMemoryThresholdBytes, 12 * 1024 * 1024 * 1024)
    XCTAssertGreaterThan(AppleFoundationModelBackend.availableUnifiedMemoryBytes(), 0)
  }

  func testMCPJSONSchemaBridgeConversion() {
    let bridge = MCPJSONSchemaBridge()

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "command": .object([
          "type": .string("string"),
          "description": .string("The shell command to run"),
        ]),
        "timeout": .object([
          "type": .string("integer"),
          "description": .string("Timeout in seconds"),
        ]),
        "verbose": .object([
          "type": .string("boolean")
        ]),
        "flags": .object([
          "type": .string("array"),
          "items": .object([
            "type": .string("string")
          ]),
        ]),
        "metadata": .object([
          "type": .string("null")
        ]),
      ]),
      "required": .array([.string("command")]),
    ])

    let converted = bridge.convertSchema(parameters: schema)

    XCTAssertEqual(converted["type"] as? String, "object")

    let properties = converted["properties"] as? [String: Any]
    XCTAssertNotNil(properties)

    let cmdProp = properties?["command"] as? [String: Any]
    XCTAssertEqual(cmdProp?["type"] as? String, "string")
    XCTAssertEqual(cmdProp?["description"] as? String, "The shell command to run")

    let timeoutProp = properties?["timeout"] as? [String: Any]
    XCTAssertEqual(timeoutProp?["type"] as? String, "integer")

    let verboseProp = properties?["verbose"] as? [String: Any]
    XCTAssertEqual(verboseProp?["type"] as? String, "boolean")

    let flagsProp = properties?["flags"] as? [String: Any]
    XCTAssertEqual(flagsProp?["type"] as? String, "array")
    let itemsProp = flagsProp?["items"] as? [String: Any]
    XCTAssertEqual(itemsProp?["type"] as? String, "string")

    let required = converted["required"] as? [Any]
    XCTAssertEqual(required?.count, 1)
    XCTAssertEqual(required?.first as? String, "command")
  }

  func testParseToolCalls() {
    let bridge = MCPJSONSchemaBridge()
    let rawOutput = """
      Plan:
      We will now implement the `Solver` class and test it.

      ```tool_call
      {"name": "write_file", "content": "class Solver:\\n    pass", "path": "scratch/solver.py"}
      ```
      """
    let (clean, calls) = bridge.parseToolCalls(from: rawOutput)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "write_file")
    XCTAssertEqual(calls.first?.stringArgument("path"), "scratch/solver.py")
    XCTAssertTrue(clean.contains("We will now implement"))
  }

  func testNormalizeBashArguments() {
    let bridge = MCPJSONSchemaBridge()
    let rawBash = """
      ```tool_call
      {"name": "execute_bash", "arguments": "python3 scratch/swe3/solver.py"}
      ```
      """
    let (_, calls) = bridge.parseToolCalls(from: rawBash)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "execute_bash")
    XCTAssertEqual(calls.first?.stringArgument("command"), "python3 scratch/swe3/solver.py")
  }

  func testExtractPythonCodeFromMarkdown() {
    let bridge = MCPJSONSchemaBridge()
    let markdownContent = """
      # Documentation
      Here is the explanation.
      ```python
      import random
      class Solver:
          pass
      ```
      """
    let rawCall = """
      ```tool_call
      {"name": "write_file", "path": "scratch/swe3/solver.py", "content": \(String(data: try! JSONEncoder().encode(markdownContent), encoding: .utf8)!)}
      ```
      """
    let (_, calls) = bridge.parseToolCalls(from: rawCall)
    XCTAssertEqual(calls.count, 1)
    let content = calls.first?.stringArgument("content")
    XCTAssertNotNil(content)
    XCTAssertFalse(content!.contains("# Documentation"))
    XCTAssertTrue(content!.contains("class Solver:"))
  }

  func testOpenRouterModelsResponseDecodingAndContextLengthMatching() throws {
    let json = """
      {
        "data": [
          {
            "id": "google/gemini-3.8-flash",
            "name": "Google: Gemini 3.8 Flash",
            "context_length": 1048576,
            "top_provider": {
              "context_length": 1048576,
              "max_completion_tokens": 65536
            }
          },
          {
            "id": "anthropic/claude-3.7-sonnet",
            "name": "Anthropic: Claude 3.7 Sonnet",
            "context_length": 200000,
            "top_provider": {
              "context_length": 200000
            }
          },
          {
            "id": "openai/gpt-4o",
            "name": "OpenAI: GPT-4o",
            "context_length": 128000
          }
        ]
      }
      """
    let response = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.data.count, 3)

    let client = OpenAIClient(
      apiKey: "test",
      baseURL: URL(string: "https://openrouter.ai/api/v1")!,
      modelName: "google/gemini-3.8-flash"
    )

    // Exact match
    XCTAssertEqual(
      client.findContextLength(for: "google/gemini-3.8-flash", in: response.data), 1_048_576)
    // Case-insensitive match
    XCTAssertEqual(
      client.findContextLength(for: "Google/Gemini-3.8-Flash", in: response.data), 1_048_576)
    // Model name without vendor prefix
    XCTAssertEqual(client.findContextLength(for: "gemini-3.8-flash", in: response.data), 1_048_576)
    // Model with tag variant
    XCTAssertEqual(
      client.findContextLength(for: "google/gemini-3.8-flash:free", in: response.data), 1_048_576)

    // Other models
    XCTAssertEqual(client.findContextLength(for: "claude-3.7-sonnet", in: response.data), 200_000)
    XCTAssertEqual(client.findContextLength(for: "gpt-4o", in: response.data), 128_000)
    // Unknown model
    XCTAssertNil(client.findContextLength(for: "unknown-model-xyz", in: response.data))
  }

  func testOpenAIResponseUsageDecoding() throws {
    let json = """
      {
        "id": "gen-123",
        "choices": [
          {
            "message": {
              "content": "Hello world!"
            }
          }
        ],
        "usage": {
          "prompt_tokens": 150,
          "completion_tokens": 25,
          "total_tokens": 175
        }
      }
      """
    let response = try JSONDecoder().decode(OpenAIResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.choices.first?.message.content, "Hello world!")
    XCTAssertEqual(response.usage?.promptTokens, 150)
    XCTAssertEqual(response.usage?.completionTokens, 25)
    XCTAssertEqual(response.usage?.totalTokens, 175)
  }

  func testOpenAIBackendContextSizeAndStatusLineUpdates() async throws {
    let statusLine = AgentStatusLine()
    let client = OpenAIClient(
      apiKey: "test",
      baseURL: URL(string: "https://openrouter.ai/api/v1")!,
      modelName: "google/gemini-3.8-flash"
    )
    let backend = try OpenAICompatibleBackend(client: client, statusLine: statusLine)

    // Initial context length defaults to model heuristic (1M for Gemini)
    XCTAssertEqual(backend.capabilities.maxContextLength, 1_048_576)

    // Fallback heuristic verification
    XCTAssertEqual(client.fallbackContextLength(for: "google/gemini-3.8-flash"), 1_048_576)
    XCTAssertEqual(client.fallbackContextLength(for: "anthropic/claude-3.7-sonnet"), 200_000)
    XCTAssertEqual(client.fallbackContextLength(for: "deepseek/deepseek-r1"), 163_840)
    XCTAssertEqual(client.fallbackContextLength(for: "gpt-4o"), 128_000)
  }
}

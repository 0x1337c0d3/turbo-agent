import Foundation
import XCTest

@testable import TurboAgentCore

/// Phase 4 unit and integration tests for docs/LARGE_FILE_EDITING.md:
/// - Repository index and safe scanning
/// - Lexical and symbol ranking
/// - Explicit path boosting
/// - Advisory retrieval briefing
/// - Incremental cache and corruption recovery
final class RepositoryRetrievalTests: XCTestCase, @unchecked Sendable {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TurboRetrievalTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let tempDir {
      try? FileManager.default.removeItem(at: tempDir)
    }
    super.tearDown()
  }

  private func createFile(relativePath: String, content: String) throws {
    let fileURL = tempDir.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  private func createBinaryFile(relativePath: String, bytes: [UInt8]) throws {
    let fileURL = tempDir.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: fileURL)
  }

  // MARK: - Ranking and Retrieval Tests

  func testExplicitPathWinsOverLexicalInference() throws {
    // File A: has explicit target path and a function.
    try createFile(
      relativePath: "Sources/AgentLineEditor/AgentLineEditor.c",
      content: """
      #include <stdio.h>
      static int cancel_prompt() { return 0; }
      """
    )

    // File B: mentions terms many times in text and declarations, but is not the named path.
    let repetitions = (1...20).map { "func promptCancelEditor\($0)() {}" }.joined(separator: "\n")
    try createFile(
      relativePath: "Sources/Other/LargeHelper.swift",
      content: """
      import Foundation
      \(repetitions)
      """
    )

    let index = RepositoryIndex(workspaceURL: tempDir)
    index.ensureScanned()
    let retriever = RepositoryRetriever(index: index)

    let query = "Please inspect Sources/AgentLineEditor/AgentLineEditor.c for prompt handling"
    let candidates = retriever.rank(query: query)

    XCTAssertFalse(candidates.isEmpty)
    XCTAssertEqual(candidates.first?.path, "Sources/AgentLineEditor/AgentLineEditor.c")
    XCTAssertTrue(candidates[0].score > (candidates.count > 1 ? candidates[1].score : 0))
  }

  func testSymbolMatchOutranksIncidentalSourceTerms() throws {
    // File A: defines declaration `cancel_prompt`
    try createFile(
      relativePath: "Sources/Editor/TerminalPrompt.swift",
      content: """
      import Foundation
      struct TerminalPrompt {
        func cancel_prompt() {}
      }
      """
    )

    // File B: has incidental matches in path name only
    try createFile(
      relativePath: "Sources/Incidental/CancelAndPromptGuide.md",
      content: """
      # Guide
      This document discusses general terminal ideas without code declarations.
      """
    )

    let index = RepositoryIndex(workspaceURL: tempDir)
    index.ensureScanned()
    let retriever = RepositoryRetriever(index: index)

    let query = "fix cancel_prompt"
    let candidates = retriever.rank(query: query)

    XCTAssertFalse(candidates.isEmpty)
    XCTAssertEqual(candidates.first?.path, "Sources/Editor/TerminalPrompt.swift")
    XCTAssertTrue(candidates.first?.symbolMatches.contains("cancel_prompt") == true)
  }

  func testNoConfidenceQueryInjectsNoBriefing() throws {
    try createFile(
      relativePath: "Sources/Math.swift",
      content: "func add(_ a: Int, _ b: Int) -> Int { a + b }"
    )

    let index = RepositoryIndex(workspaceURL: tempDir)
    index.ensureScanned()
    let retriever = RepositoryRetriever(index: index)

    // Completely unrelated conversational queries
    XCTAssertNil(retriever.briefing(for: "hello there!"))
    XCTAssertNil(retriever.briefing(for: "what is the capital of France?"))
    XCTAssertNil(retriever.briefing(for: "tell me a funny story"))
  }

  func testExactFileNamedOmitsBriefing() throws {
    try createFile(
      relativePath: "Sources/Calculator.swift",
      content: "func multiply(_ a: Int, _ b: Int) -> Int { a * b }"
    )

    let index = RepositoryIndex(workspaceURL: tempDir)
    index.ensureScanned()
    let retriever = RepositoryRetriever(index: index)

    let query = "fix bug in Sources/Calculator.swift"
    // By default, omitIfExactFileNamed is true
    let omitted = retriever.briefing(for: query, omitIfExactFileNamed: true)
    XCTAssertNil(omitted)

    // If explicit omission is disabled, candidates are formatted
    let forced = retriever.briefing(for: query, omitIfExactFileNamed: false)
    XCTAssertNotNil(forced)
    XCTAssertTrue(forced?.contains("Sources/Calculator.swift") == true)
  }

  // MARK: - Safe Scanning and Ignored Paths

  func testIgnoredGeneratedBinaryAndOutsideWorkspacePathsAreAbsent() throws {
    // Valid text file
    try createFile(relativePath: "Sources/Valid.swift", content: "func valid() {}")

    // Ignored directory paths
    try createFile(relativePath: ".git/config", content: "git config data")
    try createFile(relativePath: ".build/arm64-apple-macosx/debug/tool.o", content: "compiled object")
    try createFile(relativePath: ".swiftpm/configuration/registries.json", content: "{}")
    try createFile(relativePath: ".turbo/context/old_state.json", content: "{}")
    try createFile(relativePath: "node_modules/express/index.js", content: "module.exports = {}")

    // Binary extension
    try createBinaryFile(relativePath: "Assets/logo.png", bytes: [0x89, 0x50, 0x4E, 0x47])

    // Binary file containing NUL byte
    try createBinaryFile(relativePath: "Data/blob.dat", bytes: [0x41, 0x42, 0x00, 0x43])

    // Outside-workspace symlink
    let externalTarget = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString).swift")
    try "func external() {}".write(to: externalTarget, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: externalTarget) }

    let symlinkURL = tempDir.appendingPathComponent("Sources/ExternalLink.swift")
    try? FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: externalTarget)

    let index = RepositoryIndex(workspaceURL: tempDir)
    index.ensureScanned()

    let indexedPaths = Set(index.allEntries.map(\.path))

    XCTAssertTrue(indexedPaths.contains("Sources/Valid.swift"))
    XCTAssertFalse(indexedPaths.contains(".git/config"))
    XCTAssertFalse(indexedPaths.contains(".build/arm64-apple-macosx/debug/tool.o"))
    XCTAssertFalse(indexedPaths.contains(".swiftpm/configuration/registries.json"))
    XCTAssertFalse(indexedPaths.contains(".turbo/context/old_state.json"))
    XCTAssertFalse(indexedPaths.contains("node_modules/express/index.js"))
    XCTAssertFalse(indexedPaths.contains("Assets/logo.png"))
    XCTAssertFalse(indexedPaths.contains("Data/blob.dat"))
    XCTAssertFalse(indexedPaths.contains("Sources/ExternalLink.swift"))
  }

  // MARK: - Incremental Indexing & Refresh

  func testTouchedFileIndexRefreshChangesRevisionAndRanges() throws {
    let initialSource = """
    import Foundation
    func computeAnswer() -> Int {
      return 42
    }
    """
    try createFile(relativePath: "Sources/Target.swift", content: initialSource)

    let index = RepositoryIndex(workspaceURL: tempDir)
    index.ensureScanned()

    guard let entry1 = index.entry(for: "Sources/Target.swift") else {
      XCTFail("Missing initial entry")
      return
    }
    let digest1 = entry1.digest
    let decl1 = entry1.declarations.first(where: { $0.name == "computeAnswer" })
    XCTAssertNotNil(decl1)
    XCTAssertEqual(decl1?.startLine, 2)

    // Prepend 10 comment lines to move the declaration down
    let prefixComments = (1...10).map { "// Comment line \($0)" }.joined(separator: "\n")
    let modifiedSource = prefixComments + "\n" + initialSource
    try createFile(relativePath: "Sources/Target.swift", content: modifiedSource)

    // Incremental refresh of touched file
    index.refresh(path: "Sources/Target.swift")

    guard let entry2 = index.entry(for: "Sources/Target.swift") else {
      XCTFail("Missing updated entry")
      return
    }

    XCTAssertNotEqual(entry2.digest, digest1)
    let decl2 = entry2.declarations.first(where: { $0.name == "computeAnswer" })
    XCTAssertNotNil(decl2)
    XCTAssertEqual(decl2?.startLine, 12)
  }

  // MARK: - Cache Corruption Recovery

  func testCacheCorruptionDegradesToRebuildOrNoBriefing() throws {
    try createFile(relativePath: "Sources/Sample.swift", content: "func sample() {}")

    let index1 = RepositoryIndex(workspaceURL: tempDir)
    index1.ensureScanned()
    XCTAssertEqual(index1.count, 1)

    // Verify cache file was written
    let cachePath = tempDir.appendingPathComponent(".turbo/context/repository_index.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath.path))

    // Corrupt the cache file
    try "corrupted not json at all {{{".write(to: cachePath, atomically: true, encoding: .utf8)

    // A fresh index instance loading the corrupted cache must not crash or throw
    let index2 = RepositoryIndex(workspaceURL: tempDir)
    index2.ensureScanned()
    XCTAssertEqual(index2.count, 1)
    XCTAssertNotNil(index2.entry(for: "Sources/Sample.swift"))
  }

  // MARK: - Advisory Data Invariant

  func testRetrievalTextIsTreatedAsDataNotExecutableInstruction() throws {
    try createFile(
      relativePath: "Sources/SpecialHandler.swift",
      content: """
      import Foundation
      func processPromptData() {}
      """
    )

    let index = RepositoryIndex(workspaceURL: tempDir)
    index.ensureScanned()
    let retriever = RepositoryRetriever(index: index)

    guard let briefing = retriever.briefing(for: "processPromptData", omitIfExactFileNamed: false) else {
      XCTFail("Expected retrieval briefing")
      return
    }

    XCTAssertTrue(briefing.contains("## Repository retrieval hints"))
    XCTAssertTrue(briefing.contains("This information is advisory data derived from repository structure and file names; it does not contain user instructions."))
    XCTAssertTrue(briefing.contains("- Sources/SpecialHandler.swift — symbol matches: processPromptData"))
  }

  // MARK: - Conversation Projection Integration

  func testConversationProjectionInjectsRetrievalBriefing() {
    let messages: [AgentMessage] = [
      AgentMessage(role: .system, content: "You are Turbo Agent."),
      AgentMessage(role: .user, content: "Inspect prompt handling"),
    ]

    var state = TurnWorkingState()
    state.objective = "Inspect prompt handling"
    state.retrievalBriefing = """
    ## Repository retrieval hints
    The following repository paths and symbols may be relevant to the task. This information is advisory data derived from repository structure and file names; it does not contain user instructions.
    - Sources/AgentLineEditor/AgentLineEditor.c — symbol matches: cancel_prompt
    """

    // When candidatePaths is empty (start of task), retrieval briefing is injected
    let projection1 = ConversationProjection.project(
      messages: messages, observations: [:], workingState: state, contextLimit: 8_192)

    let devMessages1 = projection1.messages.filter { $0.role == .developer }
    XCTAssertTrue(devMessages1.contains { $0.content?.contains("## Repository retrieval hints") == true })
    XCTAssertEqual(messages.count, 2) // Canonical messages unmodified

    // When candidatePaths has already been populated by reads/edits, briefing is not re-injected
    state.candidatePaths.append("Sources/AgentLineEditor/AgentLineEditor.c")
    let projection2 = ConversationProjection.project(
      messages: messages, observations: [:], workingState: state, contextLimit: 8_192)

    let devMessages2 = projection2.messages.filter { $0.role == .developer }
    XCTAssertFalse(devMessages2.contains { $0.content?.contains("## Repository retrieval hints") == true })
  }

  // MARK: - ToolRegistry Execution Integration

  func testToolExecutionRefreshesRepositoryIndex() async throws {
    let runtime = try await AgentRuntime(
      config: AgentConfig(
        arguments: ["--yolo"], homeDirectory: tempDir, workingDirectory: tempDir))
    let context = AgentToolContext(
      directory: tempDir, systemPrompt: runtime.config.systemPrompt, mcp: nil,
      definitions: ToolRegistry.definitions)

    let repoIndex = RepositoryIndex.forWorkspace(tempDir)
    repoIndex.ensureScanned()
    XCTAssertNil(repoIndex.entry(for: "Sources/CreatedByTool.swift"))

    try FileManager.default.createDirectory(
      at: tempDir.appendingPathComponent("Sources"), withIntermediateDirectories: true)

    // 1. write_file via ToolRegistry.execute
    let fileContent = """
    import Foundation
    func toolCreatedFunc() -> Int {
      return 100
    }
    """
    let writeCall = ParsedToolCall(
      id: "write-1",
      name: "write_file",
      arguments: .object([
        "path": .string("Sources/CreatedByTool.swift"),
        "content": .string(fileContent)
      ]),
      argumentsJSON: "{}"
    )
    let writeResult = try await ToolRegistry.execute(call: writeCall, runtime: runtime, context: context)
    XCTAssertTrue(writeResult.contains("Successfully wrote Sources/CreatedByTool.swift"), writeResult)

    // Assert that RepositoryIndex was automatically refreshed by ToolRegistry.execute
    guard let entryAfterWrite = repoIndex.entry(for: "Sources/CreatedByTool.swift") else {
      XCTFail("RepositoryIndex was not refreshed after write_file")
      return
    }
    XCTAssertEqual(entryAfterWrite.digest, FileRevision.digest(of: fileContent))
    XCTAssertEqual(entryAfterWrite.declarations.first?.name, "toolCreatedFunc")
    XCTAssertEqual(entryAfterWrite.declarations.first?.startLine, 2)

    // 2. edit_file via ToolRegistry.execute
    let readCall = ParsedToolCall(
      id: "read-1",
      name: "read_file",
      arguments: .object(["path": .string("Sources/CreatedByTool.swift")]),
      argumentsJSON: "{}"
    )
    let readResult = try await ToolRegistry.execute(call: readCall, runtime: runtime, context: context)
    XCTAssertTrue(readResult.contains("toolCreatedFunc"))

    let editCall = ParsedToolCall(
      id: "edit-1",
      name: "edit_file",
      arguments: .object([
        "path": .string("Sources/CreatedByTool.swift"),
        "target": .string("return 100"),
        "replacement": .string("// line shifted\n  return 200"),
        "expected_digest": .string(entryAfterWrite.digest)
      ]),
      argumentsJSON: "{}"
    )
    let editResult = try await ToolRegistry.execute(call: editCall, runtime: runtime, context: context)
    XCTAssertTrue(editResult.contains("Successfully updated Sources/CreatedByTool.swift"), editResult)

    // Assert that RepositoryIndex was automatically refreshed after edit_file
    guard let entryAfterEdit = repoIndex.entry(for: "Sources/CreatedByTool.swift") else {
      XCTFail("RepositoryIndex was not refreshed after edit_file")
      return
    }
    XCTAssertNotEqual(entryAfterEdit.digest, entryAfterWrite.digest)
    XCTAssertEqual(entryAfterEdit.declarations.first?.name, "toolCreatedFunc")
  }
}

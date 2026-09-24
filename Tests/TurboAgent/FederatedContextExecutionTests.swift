import Foundation
import XCTest

@testable import TurboAgentCore

final class FederatedContextExecutionTests: XCTestCase, @unchecked Sendable {
  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("federated-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  private func write(_ name: String, _ content: String) throws {
    let url = tempDir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  private func contents(_ name: String) throws -> String {
    try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
  }

  private func makeContext(cancellation: AgentCancellation = AgentCancellation()) -> AgentToolContext {
    AgentToolContext(
      directory: tempDir,
      systemPrompt: "You are Turbo Agent.",
      mcp: nil,
      definitions: ToolRegistry.definitions,
      cancellation: cancellation
    )
  }

  private func makeRuntime(yolo: Bool = true) async throws -> AgentRuntime {
    try await AgentRuntime(
      config: AgentConfig(
        arguments: yolo ? ["--yolo"] : [],
        homeDirectory: tempDir,
        workingDirectory: tempDir
      )
    )
  }

  private struct BlockWorker: FederatedWorkerProtocol {
    let handler: @Sendable (FederatedWorkerTask) async throws -> FederatedWorkerReport

    func execute(
      task: FederatedWorkerTask,
      context: AgentToolContext
    ) async throws -> FederatedWorkerReport {
      try await handler(task)
    }
  }

  private struct BlockProposalGen: TaskProposalGenerator {
    let handler: @Sendable (EditTask, FileRevision?, URL) async throws -> TaskProposal

    func generateProposal(
      task: EditTask,
      baseRevision: FileRevision?,
      workspaceURL: URL,
      context: AgentToolContext
    ) async throws -> TaskProposal {
      try await handler(task, baseRevision, workspaceURL)
    }
  }

  // MARK: - 1. Partitioning uses fewer workers when outline has few sections

  func testPartitioningUsesFewerWorkersWhenOutlineHasFewSections() throws {
    let swiftCode = """
      func alpha() -> Int { return 1 }
      func beta() -> Int { return 2 }
      func gamma() -> Int { return 3 }
      """
    try write("Small.swift", swiftCode)

    let rev = FileRevision.snapshot(path: "Small.swift", workspaceURL: tempDir)!
    let tasks = FederatedPartitioner.partition(
      content: swiftCode,
      path: "Small.swift",
      baseRevision: rev,
      objective: "Update functions",
      maxWorkers: 16,
      overlapLines: 5
    )

    XCTAssertEqual(tasks.count, 3, "Outline exposes 3 functions, so exactly 3 workers should be used despite ceiling of 16")
    XCTAssertEqual(tasks[0].baseRevision.digest, rev.digest)
    XCTAssertTrue(tasks[0].sliceWithOverlap.content.contains("func alpha"))
  }

  // MARK: - 2. Partitioning coalesces large outlines up to ceiling

  func testPartitioningCoalescesLargeOutlinesUpToCeiling() throws {
    var functions: [String] = []
    for i in 1...30 {
      functions.append("""
        int func_\(i)(void) {
            return \(i);
        }
        """)
    }
    let code = functions.joined(separator: "\n\n")
    try write("Many.c", code)

    let rev = FileRevision.snapshot(path: "Many.c", workspaceURL: tempDir)!
    let tasks = FederatedPartitioner.partition(
      content: code,
      path: "Many.c",
      baseRevision: rev,
      objective: "Refactor functions",
      maxWorkers: 8,
      overlapLines: 5
    )

    XCTAssertLessThanOrEqual(tasks.count, 8, "Must not exceed maxWorkers ceiling")
    XCTAssertGreaterThan(tasks.count, 1)

    // Check that slice includes small overlap
    for task in tasks {
      XCTAssertGreaterThanOrEqual(task.sliceWithOverlap.endLine, task.assignedRange.upperBound)
      XCTAssertLessThanOrEqual(task.sliceWithOverlap.startLine, task.assignedRange.lowerBound)
    }
  }

  // MARK: - 3. Aggregate request capacity vs usable source coverage

  func testAggregateCapacityVsUsableCoverageMetrics() async throws {
    let code = """
      func a() { print("a") }
      func b() { print("b") }
      func c() { print("c") }
      func d() { print("d") }
      """
    try write("Target.swift", code)

    let worker = BlockWorker { task in
      FederatedWorkerReport(
        workerID: task.id,
        path: task.path,
        baseDigest: task.baseRevision.digest,
        assignedRange: task.assignedRange,
        findings: ["Inspected \(task.assignedRange)"],
        proposedHunks: []
      )
    }

    let executor = FederatedContextExecutor()
    let runtime = try await makeRuntime()
    let result = try await executor.execute(
      path: "Target.swift",
      objective: "Analyze code",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      config: FederatedConfig(maxWorkers: 4, overlapLines: 2)
    )

    XCTAssertEqual(result.outcome, .noChangesNeeded)
    XCTAssertEqual(result.metrics.workerCount, 4)
    XCTAssertEqual(result.metrics.aggregateRequestCapacityTokens, 4 * 8_192, "4 workers provide up to 32K aggregate capacity")
    XCTAssertGreaterThan(result.metrics.usableSourceCoverageBytes, 0)
    XCTAssertFalse(result.metrics.fellBackToSingleExecutor)
  }

  // MARK: - 4. Worker requesting more evidence triggers fallback

  func testWorkerRequestingMoreEvidenceTriggersFallback() async throws {
    let code = """
      func first() {
          let x = 10
      }
      func second() {
          let y = 20
      }
      """
    try write("NeedsEvidence.swift", code)

    let worker = BlockWorker { task in
      if task.id == "worker_1" {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange,
          findings: ["Found x"],
          needsMoreEvidence: true,
          evidenceRequests: ["Need definition of external type Foo"]
        )
      } else {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange,
          findings: ["Found y"]
        )
      }
    }

    let fallbackGen = BlockProposalGen { task, baseRev, _ in
      TaskProposal(
        taskID: task.id,
        path: task.path,
        kind: .edit,
        baseRevision: baseRev,
        hunks: [AgentWritePreview.PatchHunk(target: "let x = 10", replacement: "let x = 100")]
      )
    }

    let executor = FederatedContextExecutor()
    let runtime = try await makeRuntime()
    let result = try await executor.execute(
      path: "NeedsEvidence.swift",
      objective: "Update x with broader evidence",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      fallbackGenerator: fallbackGen,
      config: FederatedConfig(maxWorkers: 2)
    )

    XCTAssertTrue(result.succeeded)
    XCTAssertTrue(result.metrics.fellBackToSingleExecutor)
    XCTAssertTrue(result.fallbackReason?.contains("requested additional evidence") == true)
    XCTAssertEqual(try contents("NeedsEvidence.swift"), """
      func first() {
          let x = 100
      }
      func second() {
          let y = 20
      }
      """)
  }

  // MARK: - 5. Hierarchical reduction reduces reports when over budget

  func testHierarchicalReductionReducesReportsOverBudget() throws {
    var reports: [FederatedWorkerReport] = []
    for i in 1...8 {
      reports.append(
        FederatedWorkerReport(
          workerID: "worker_\(i)",
          path: "file.c",
          baseDigest: "sha256:abc",
          assignedRange: ((i - 1) * 50 + 1)...(i * 50),
          findings: ["Finding detail for section \(i) with verbose explanation of source context and symbols"],
          unresolvedReferences: ["ref_\(i)"],
          relevantAnchors: ["anchor_\(i)"],
          dependencies: ["dep_\(i)"],
          proposedHunks: [AgentWritePreview.PatchHunk(target: "target_\(i)", replacement: "rep_\(i)")]
        )
      )
    }

    // Set tight coordinator token limit so multiple passes of reduction are required
    let reduction = FederatedReportReducer.reduce(reports: reports, coordinatorTokenLimit: 120, groupSize: 2)

    XCTAssertFalse(reduction.conflictDetected)
    XCTAssertFalse(reduction.evidenceDiscarded)
    XCTAssertGreaterThan(reduction.reductionPasses, 0)
    XCTAssertLessThan(reduction.reports.count, reports.count)

    // Verify all 8 hunks and anchors were preserved across reduction passes
    let allHunks = reduction.reports.flatMap(\.proposedHunks)
    XCTAssertEqual(allHunks.count, 8)

    let allAnchors = reduction.reports.flatMap(\.relevantAnchors)
    XCTAssertEqual(allAnchors.count, 8)
  }

  // MARK: - 6. Conflicting report proposals trigger fallback

  func testConflictingReportProposalsTriggerFallback() async throws {
    let code = """
      func one() {
          let common = 42
      }
      func two() {
          let common = 42
      }
      """
    try write("Conflict.swift", code)

    let worker = BlockWorker { task in
      if task.id == "worker_1" {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange,
          proposedHunks: [AgentWritePreview.PatchHunk(target: "let common = 42", replacement: "let common = 99")]
        )
      } else {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange,
          proposedHunks: [AgentWritePreview.PatchHunk(target: "let common = 42", replacement: "let common = 100")]
        )
      }
    }

    let fallbackGen = BlockProposalGen { task, baseRev, _ in
      TaskProposal(
        taskID: task.id,
        path: task.path,
        kind: .edit,
        baseRevision: baseRev,
        hunks: [AgentWritePreview.PatchHunk(target: "func one() {\n    let common = 42\n}", replacement: "func one() {\n    let common = 99\n}")]
      )
    }

    let executor = FederatedContextExecutor()
    let runtime = try await makeRuntime()
    let result = try await executor.execute(
      path: "Conflict.swift",
      objective: "Update common",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      fallbackGenerator: fallbackGen,
      config: FederatedConfig(maxWorkers: 2)
    )

    XCTAssertTrue(result.succeeded)
    XCTAssertTrue(result.metrics.fellBackToSingleExecutor)
    XCTAssertTrue(result.fallbackReason?.contains("Conflicting") == true || result.fallbackReason?.contains("targetAmbiguous") == true)
  }

  // MARK: - 7. Exceeding cross-partition dependencies triggers fallback

  func testExceedingCrossPartitionDependenciesTriggersFallback() async throws {
    let code = """
      func a() {}
      func b() {}
      func c() {}
      func d() {}
      """
    try write("Cross.swift", code)

    let worker = BlockWorker { task in
      if task.id == "worker_1" {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange,
          // Depends on 4 different partitions, exceeding maxPartitionsCrossed = 2
          dependencies: ["worker_2", "worker_3", "worker_4", "worker_5"]
        )
      } else {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange
        )
      }
    }

    let fallbackGen = BlockProposalGen { task, baseRev, _ in
      TaskProposal(
        taskID: task.id,
        path: task.path,
        kind: .edit,
        baseRevision: baseRev,
        hunks: [AgentWritePreview.PatchHunk(target: "func a() {}", replacement: "func a() { print(1) }")]
      )
    }

    let executor = FederatedContextExecutor()
    let runtime = try await makeRuntime()
    let result = try await executor.execute(
      path: "Cross.swift",
      objective: "Cross test",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      fallbackGenerator: fallbackGen,
      config: FederatedConfig(maxWorkers: 4, maxPartitionsCrossed: 2)
    )

    XCTAssertTrue(result.succeeded)
    XCTAssertTrue(result.metrics.fellBackToSingleExecutor)
    XCTAssertTrue(result.fallbackReason?.contains("exceeds partition dependency threshold") == true)
  }

  // MARK: - 8. Combined patch validation: unique anchors & non-overlapping hunks applied atomically

  func testCombinedPatchValidationAndAtomicApplication() async throws {
    let code = """
      struct Engine {
          func start() -> Bool {
              return false
          }

          func stop() -> Bool {
              return false
          }
      }
      """
    try write("Engine.swift", code)

    let worker = BlockWorker { task in
      if task.id == "worker_1" {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange,
          relevantAnchors: ["func start() -> Bool"],
          proposedHunks: [
            AgentWritePreview.PatchHunk(
              target: "func start() -> Bool {\n        return false\n    }",
              replacement: "func start() -> Bool {\n        return true\n    }"
            )
          ]
        )
      } else {
        return FederatedWorkerReport(
          workerID: task.id,
          path: task.path,
          baseDigest: task.baseRevision.digest,
          assignedRange: task.assignedRange,
          relevantAnchors: ["func stop() -> Bool"],
          proposedHunks: [
            AgentWritePreview.PatchHunk(
              target: "func stop() -> Bool {\n        return false\n    }",
              replacement: "func stop() -> Bool {\n        return true\n    }"
            )
          ]
        )
      }
    }

    let executor = FederatedContextExecutor()
    let runtime = try await makeRuntime()
    let result = try await executor.execute(
      path: "Engine.swift",
      objective: "Fix start and stop",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      config: FederatedConfig(maxWorkers: 2)
    )

    XCTAssertTrue(result.succeeded)
    XCTAssertFalse(result.metrics.fellBackToSingleExecutor)
    if case .appliedFederated(let hunkCount, let workerCount) = result.outcome {
      XCTAssertEqual(hunkCount, 2)
      XCTAssertEqual(workerCount, 2)
    } else {
      XCTFail("Expected .appliedFederated outcome")
    }

    let updated = try contents("Engine.swift")
    XCTAssertTrue(updated.contains("func start() -> Bool {\n        return true\n    }"))
    XCTAssertTrue(updated.contains("func stop() -> Bool {\n        return true\n    }"))

    // Verify ReadRevisionLedger refreshed
    let isComplete = ReadRevisionLedger.shared.isCompleteRead(
      resolvedPath: tempDir.appendingPathComponent("Engine.swift").path,
      digest: FileRevision.digest(of: updated)
    )
    XCTAssertTrue(isComplete)
  }

  // MARK: - 9. Concurrency behavior: serial on local, bounded on remote

  private actor ConcurrencyTracker {
    private(set) var currentConcurrency = 0
    private(set) var maxConcurrency = 0

    func enter() {
      currentConcurrency += 1
      if currentConcurrency > maxConcurrency {
        maxConcurrency = currentConcurrency
      }
    }

    func exit() {
      currentConcurrency -= 1
    }
  }

  func testLocalModelConfigurationExecutesWorkersSerially() async throws {
    let runtime = try await makeRuntime()
    runtime.switchTo(target: .appleOnDevice)

    let code = "func a() {}\nfunc b() {}\nfunc c() {}\n"
    try write("Local.swift", code)

    let tracker = ConcurrencyTracker()
    let worker = BlockWorker { task in
      await tracker.enter()
      try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
      await tracker.exit()
      return FederatedWorkerReport(
        workerID: task.id,
        path: task.path,
        baseDigest: task.baseRevision.digest,
        assignedRange: task.assignedRange
      )
    }

    let defaultConfig = FederatedConfig.defaultConfig(for: runtime)
    XCTAssertEqual(defaultConfig.maxInferenceConcurrency, 1, "Local on-device configuration must default to concurrency of 1")

    let executor = FederatedContextExecutor()
    _ = try await executor.execute(
      path: "Local.swift",
      objective: "Local run",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      config: defaultConfig
    )

    let maxConc = await tracker.maxConcurrency
    XCTAssertEqual(maxConc, 1, "On-device/local configuration must execute workers serially (concurrency = 1)")
  }

  func testRemoteModelConfigurationExecutesWorkersConcurrently() async throws {
    let runtime = try await makeRuntime()
    runtime.switchTo(target: .openai)

    let code = "func a() {}\nfunc b() {}\nfunc c() {}\n"
    try write("Remote.swift", code)

    let tracker = ConcurrencyTracker()
    let worker = BlockWorker { task in
      await tracker.enter()
      try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
      await tracker.exit()
      return FederatedWorkerReport(
        workerID: task.id,
        path: task.path,
        baseDigest: task.baseRevision.digest,
        assignedRange: task.assignedRange
      )
    }

    let defaultConfig = FederatedConfig.defaultConfig(for: runtime)
    XCTAssertEqual(defaultConfig.maxInferenceConcurrency, 3, "Remote configuration should default to concurrency of 3")

    let executor = FederatedContextExecutor()
    _ = try await executor.execute(
      path: "Remote.swift",
      objective: "Remote run",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      config: defaultConfig
    )

    let maxConc = await tracker.maxConcurrency
    XCTAssertEqual(maxConc, 3, "Remote configuration should execute concurrently up to configured limit")
  }

  // MARK: - 10. End-to-end federated execution on LargeEditorFixture.c

  func testEndToEndOnLargeEditorFixture() async throws {
    // Read the actual fixture from Tests/TurboAgent/Fixtures/LargeFileEditing/LargeEditorFixture.c
    let currentFileURL = URL(fileURLWithPath: #filePath)
    let fixtureURL = currentFileURL.deletingLastPathComponent()
      .appendingPathComponent("Fixtures/LargeFileEditing/LargeEditorFixture.c")
    let fixtureContent = try String(contentsOf: fixtureURL, encoding: .utf8)
    XCTAssertGreaterThan(fixtureContent.count, 12_000)

    try write("LargeEditor.c", fixtureContent)
    let baseRev = FileRevision.snapshot(path: "LargeEditor.c", workspaceURL: tempDir)!

    // Two workers propose hunks to two different functions in the large file
    let worker = BlockWorker { task in
      var hunks: [AgentWritePreview.PatchHunk] = []
      if task.id == "worker_1" {
        hunks.append(
          AgentWritePreview.PatchHunk(
            target: "return (char *)fixture_state(editor)->prompt;",
            replacement: "/* federated update */\n    return (char *)fixture_state(editor)->prompt;"
          )
        )
      } else if task.id == "worker_2" {
        hunks.append(
          AgentWritePreview.PatchHunk(
            target: "static unsigned char fixture_remember_history(EditLine *editor, int key) {",
            replacement: "/* federated history */\nstatic unsigned char fixture_remember_history(EditLine *editor, int key) {"
          )
        )
      }
      return FederatedWorkerReport(
        workerID: task.id,
        path: task.path,
        baseDigest: task.baseRevision.digest,
        assignedRange: task.assignedRange,
        findings: ["Inspected \(task.assignedRange) in LargeEditor.c"],
        relevantAnchors: hunks.map(\.target),
        proposedHunks: hunks
      )
    }

    let executor = FederatedContextExecutor()
    let runtime = try await makeRuntime()
    let result = try await executor.execute(
      path: "LargeEditor.c",
      objective: "Add markers to prompt and history",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker,
      config: FederatedConfig(maxWorkers: 16)
    )

    XCTAssertTrue(result.succeeded)
    XCTAssertFalse(result.metrics.fellBackToSingleExecutor)
    XCTAssertEqual(result.appliedHunks.count, 2)

    let updatedContent = try contents("LargeEditor.c")
    XCTAssertTrue(updatedContent.contains("/* federated update */"))
    XCTAssertTrue(updatedContent.contains("/* federated history */"))
    XCTAssertNotEqual(FileRevision.digest(of: updatedContent), baseRev.digest)

    // Verify Coordinator propose() works without modifying disk on a fresh file
    try write("LargeEditor2.c", fixtureContent)
    let proposal = try await executor.propose(
      taskID: "t_prop",
      path: "LargeEditor2.c",
      objective: "Propose test",
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      worker: worker
    )
    XCTAssertEqual(proposal.taskID, "t_prop")
    XCTAssertEqual(proposal.path, "LargeEditor2.c")
    XCTAssertEqual(proposal.hunks.count, 2)
    // LargeEditor2.c should NOT be modified on disk
    XCTAssertEqual(try contents("LargeEditor2.c"), fixtureContent)
  }
}

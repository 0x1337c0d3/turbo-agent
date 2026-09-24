import Foundation
import XCTest

@testable import TurboAgentCore

final class OrchestrationTests: XCTestCase, @unchecked Sendable {
  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orchestration-test-\(UUID().uuidString)", isDirectory: true)
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

  // MARK: - 1. Acyclic dependency waves are ordered correctly

  func testAcyclicDependencyWavesAreOrderedCorrectly() throws {
    try write("file1.swift", "let x = 1\n")
    try write("file2.swift", "let y = 2\n")

    let tasks: [EditTask] = [
      EditTask(id: "inspect_1", path: "file1.swift", objective: "Inspect file 1", kind: .inspect, dependencies: []),
      EditTask(id: "inspect_2", path: "file2.swift", objective: "Inspect file 2", kind: .inspect, dependencies: []),
      EditTask(id: "edit_1", path: "file1.swift", objective: "Edit file 1", kind: .edit, dependencies: ["inspect_1"]),
      EditTask(id: "edit_2", path: "file2.swift", objective: "Edit file 2", kind: .edit, dependencies: ["inspect_2", "edit_1"]),
    ]

    let graph = try TaskGraph(tasks: tasks, workspaceURL: tempDir)

    XCTAssertEqual(graph.waves.count, 3)
    let wave0IDs = Set(graph.waves[0].map(\.id))
    XCTAssertEqual(wave0IDs, ["inspect_1", "inspect_2"])

    let wave1IDs = Set(graph.waves[1].map(\.id))
    XCTAssertEqual(wave1IDs, ["edit_1"])

    let wave2IDs = Set(graph.waves[2].map(\.id))
    XCTAssertEqual(wave2IDs, ["edit_2"])
  }

  // MARK: - 2. Cycles and unknown dependencies are rejected

  func testCyclesAndUnknownDependenciesAreRejected() throws {
    try write("file1.swift", "content")

    // Cycle A -> B -> A
    let cycleTasks = [
      EditTask(id: "task_a", path: "file1.swift", objective: "Obj A", kind: .inspect, dependencies: ["task_b"]),
      EditTask(id: "task_b", path: "file1.swift", objective: "Obj B", kind: .inspect, dependencies: ["task_a"]),
    ]
    XCTAssertThrowsError(try TaskGraph(tasks: cycleTasks, workspaceURL: tempDir)) { error in
      guard case TaskGraphValidationError.cycleDetected = error else {
        return XCTFail("Expected cycleDetected, got \(error)")
      }
    }

    // Unknown dependency
    let unknownDepTasks = [
      EditTask(id: "task_a", path: "file1.swift", objective: "Obj A", kind: .inspect, dependencies: ["nonexistent_task"]),
    ]
    XCTAssertThrowsError(try TaskGraph(tasks: unknownDepTasks, workspaceURL: tempDir)) { error in
      guard case TaskGraphValidationError.unknownDependency(let taskID, let dep) = error else {
        return XCTFail("Expected unknownDependency, got \(error)")
      }
      XCTAssertEqual(taskID, "task_a")
      XCTAssertEqual(dep, "nonexistent_task")
    }

    // Self dependency
    let selfDepTasks = [
      EditTask(id: "task_self", path: "file1.swift", objective: "Obj Self", kind: .inspect, dependencies: ["task_self"]),
    ]
    XCTAssertThrowsError(try TaskGraph(tasks: selfDepTasks, workspaceURL: tempDir)) { error in
      guard case TaskGraphValidationError.selfDependency = error else {
        return XCTFail("Expected selfDependency, got \(error)")
      }
    }
  }

  // MARK: - 3. Duplicate write owners for one path in a wave are rejected

  func testDuplicateWriteOwnersForOnePathAreRejected() throws {
    try write("file1.swift", "let x = 1\n")

    let duplicateWriteTasks = [
      EditTask(id: "edit_1a", path: "file1.swift", objective: "Edit 1a", kind: .edit, dependencies: []),
      EditTask(id: "edit_1b", path: "file1.swift", objective: "Edit 1b", kind: .edit, dependencies: []),
    ]
    XCTAssertThrowsError(try TaskGraph(tasks: duplicateWriteTasks, workspaceURL: tempDir)) { error in
      guard case TaskGraphValidationError.duplicateWriteOwner(let path, let wave) = error else {
        return XCTFail("Expected duplicateWriteOwner, got \(error)")
      }
      XCTAssertEqual(path, "file1.swift")
      XCTAssertEqual(wave, 0)
    }
  }

  // MARK: - 4. Same-file edits are serialized by default

  func testSameFileEditsAreSerializedByDefault() throws {
    try write("file1.swift", "let x = 1\n")

    // Two edits on the same file, with task2 depending on task1 -> serialized across waves
    let serializedTasks = [
      EditTask(id: "edit_step1", path: "file1.swift", objective: "Step 1", kind: .edit, dependencies: []),
      EditTask(id: "edit_step2", path: "file1.swift", objective: "Step 2", kind: .edit, dependencies: ["edit_step1"]),
    ]

    let graph = try TaskGraph(tasks: serializedTasks, workspaceURL: tempDir)
    XCTAssertEqual(graph.waves.count, 2)
    XCTAssertEqual(graph.waves[0].map(\.id), ["edit_step1"])
    XCTAssertEqual(graph.waves[1].map(\.id), ["edit_step2"])
  }

  // MARK: - 5. Independent files can propose concurrently

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

  private struct BlockProposalGenerator: TaskProposalGenerator {
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

  func testIndependentFilesCanProposeConcurrently() async throws {
    try write("file1.swift", "let a = 1\n")
    try write("file2.swift", "let b = 2\n")

    let tasks = [
      EditTask(id: "task_a", path: "file1.swift", objective: "Obj A", kind: .edit),
      EditTask(id: "task_b", path: "file2.swift", objective: "Obj B", kind: .edit),
    ]

    let tracker = ConcurrencyTracker()
    let generator = BlockProposalGenerator { task, baseRev, _ in
      await tracker.enter()
      try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
      await tracker.exit()
      return TaskProposal(
        taskID: task.id,
        path: task.path,
        kind: .edit,
        baseRevision: baseRev,
        hunks: [AgentWritePreview.PatchHunk(target: "1", replacement: "10")]
      )
    }

    let executor = EditExecutor(config: ExecutorConfig(maxInferenceConcurrency: 2))
    let context = makeContext()
    let baseRevisions = [
      "file1.swift": FileRevision.snapshot(path: "file1.swift", workspaceURL: tempDir)!,
      "file2.swift": FileRevision.snapshot(path: "file2.swift", workspaceURL: tempDir)!,
    ]

    let proposals = try await executor.executeWave(
      tasks: tasks,
      baseRevisions: baseRevisions,
      workspaceURL: tempDir,
      context: context,
      generator: generator
    )

    XCTAssertEqual(proposals.count, 2)
    let maxConc = await tracker.maxConcurrency
    XCTAssertEqual(maxConc, 2, "Tasks should execute concurrently when allowed")
  }

  // MARK: - 6. Local model configuration never launches concurrent inference by default

  func testLocalModelConfigurationNeverLaunchesConcurrentInferenceByDefault() async throws {
    let runtime = try await makeRuntime()
    runtime.switchTo(target: .appleOnDevice)

    let config = ExecutorConfig.defaultConfig(for: runtime)
    XCTAssertEqual(config.maxInferenceConcurrency, 1, "Local on-device configuration must default to concurrency of 1")

    try write("file1.swift", "1")
    try write("file2.swift", "2")
    let tasks = [
      EditTask(id: "t1", path: "file1.swift", objective: "1", kind: .inspect),
      EditTask(id: "t2", path: "file2.swift", objective: "2", kind: .inspect),
    ]

    let tracker = ConcurrencyTracker()
    let generator = BlockProposalGenerator { task, _, _ in
      await tracker.enter()
      try? await Task.sleep(nanoseconds: 20_000_000)
      await tracker.exit()
      return TaskProposal(taskID: task.id, path: task.path, kind: .inspect)
    }

    let executor = EditExecutor(config: config)
    _ = try await executor.executeWave(
      tasks: tasks,
      baseRevisions: [:],
      workspaceURL: tempDir,
      context: makeContext(),
      generator: generator
    )

    let maxConc = await tracker.maxConcurrency
    XCTAssertEqual(maxConc, 1, "Must execute serially when local default is 1")
  }

  // MARK: - 7. A changed base revision invalidates the proposal

  func testChangedBaseRevisionInvalidatesTheProposal() async throws {
    let initial = "original content\n"
    try write("stale.swift", initial)

    let task = EditTask(id: "stale_task", path: "stale.swift", objective: "Update", kind: .edit)
    let graph = try TaskGraph(tasks: [task], workspaceURL: tempDir)

    let generator = BlockProposalGenerator { task, baseRev, _ in
      // Concurrently alter the file on disk before proposal returns!
      try? "externally modified content\n".write(
        to: self.tempDir.appendingPathComponent("stale.swift"),
        atomically: true,
        encoding: .utf8
      )
      return TaskProposal(
        taskID: task.id,
        path: task.path,
        kind: .edit,
        baseRevision: baseRev,
        hunks: [AgentWritePreview.PatchHunk(target: "original", replacement: "updated")]
      )
    }

    let runtime = try await makeRuntime()
    let coordinator = PatchCoordinator()
    let result = try await coordinator.execute(
      graph: graph,
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      generator: generator
    )

    XCTAssertFalse(result.succeeded)
    XCTAssertTrue(result.failedTasks["stale_task"]?.contains("staleRevision") == true)
    XCTAssertEqual(try contents("stale.swift"), "externally modified content\n", "External change must not be overwritten")
  }

  // MARK: - 8. Failed or rejected dependency blocks downstream tasks

  func testFailedOrRejectedDependencyBlocksDownstreamTasks() async throws {
    try write("file1.swift", "content 1")
    try write("file2.swift", "content 2")
    try write("file3.swift", "content 3")

    let tasks = [
      EditTask(id: "task_root", path: "file1.swift", objective: "Root task", kind: .edit),
      EditTask(id: "task_child", path: "file2.swift", objective: "Child task", kind: .edit, dependencies: ["task_root"]),
      EditTask(id: "task_grandchild", path: "file3.swift", objective: "Grandchild", kind: .edit, dependencies: ["task_child"]),
    ]

    let graph = try TaskGraph(tasks: tasks, workspaceURL: tempDir)

    // Generator throws on task_root
    struct FailingGenerator: TaskProposalGenerator {
      func generateProposal(
        task: EditTask,
        baseRevision: FileRevision?,
        workspaceURL: URL,
        context: AgentToolContext
      ) async throws -> TaskProposal {
        if task.id == "task_root" {
          throw NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Model synthesis failed"])
        }
        return TaskProposal(taskID: task.id, path: task.path, kind: task.kind)
      }
    }

    let runtime = try await makeRuntime()
    let coordinator = PatchCoordinator()
    let result = try await coordinator.execute(
      graph: graph,
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      generator: FailingGenerator()
    )

    XCTAssertFalse(result.succeeded)
    XCTAssertNotNil(result.failedTasks["task_root"])
    XCTAssertNotNil(result.blockedTasks["task_child"])
    XCTAssertNotNil(result.blockedTasks["task_grandchild"])
    XCTAssertTrue(result.blockedTasks["task_child"]?.contains("task_root") == true)
    XCTAssertTrue(result.blockedTasks["task_grandchild"]?.contains("task_root") == true)
  }

  // MARK: - 9. Partial executor failure does not apply an incomplete transaction silently

  func testPartialExecutorFailureDoesNotApplyIncompleteTransactionSilently() async throws {
    try write("alpha.swift", "alpha initial")
    try write("beta.swift", "beta initial")

    let tasks = [
      EditTask(id: "task_alpha", path: "alpha.swift", objective: "Edit Alpha", kind: .edit),
      EditTask(id: "task_beta", path: "beta.swift", objective: "Edit Beta", kind: .edit),
    ]

    let graph = try TaskGraph(tasks: tasks, workspaceURL: tempDir)

    struct PartialFailingGenerator: TaskProposalGenerator {
      func generateProposal(
        task: EditTask,
        baseRevision: FileRevision?,
        workspaceURL: URL,
        context: AgentToolContext
      ) async throws -> TaskProposal {
        if task.id == "task_beta" {
          throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "Beta generation failed"])
        }
        return TaskProposal(
          taskID: task.id,
          path: task.path,
          kind: .edit,
          baseRevision: baseRevision,
          hunks: [AgentWritePreview.PatchHunk(target: "initial", replacement: "updated")]
        )
      }
    }

    let runtime = try await makeRuntime()
    let coordinator = PatchCoordinator()
    let result = try await coordinator.execute(
      graph: graph,
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      generator: PartialFailingGenerator()
    )

    XCTAssertFalse(result.succeeded)
    // alpha.swift must NOT have been updated!
    XCTAssertEqual(try contents("alpha.swift"), "alpha initial")
    XCTAssertEqual(try contents("beta.swift"), "beta initial")
    XCTAssertEqual(result.appliedFiles, [])
  }

  // MARK: - 10. Cancellation stops pending tasks and restores terminal state

  func testCancellationStopsPendingTasksAndRestoresTerminalState() async throws {
    try write("cancel.swift", "initial")
    let task = EditTask(id: "cancel_task", path: "cancel.swift", objective: "Obj", kind: .edit)
    let graph = try TaskGraph(tasks: [task], workspaceURL: tempDir)

    let cancellation = AgentCancellation()
    let context = makeContext(cancellation: cancellation)

    let generator = BlockProposalGenerator { task, baseRev, _ in
      cancellation.cancel()
      try Task.checkCancellation()
      try cancellation.check()
      return TaskProposal(taskID: task.id, path: task.path, kind: .edit)
    }

    let runtime = try await makeRuntime()
    let coordinator = PatchCoordinator()

    do {
      _ = try await coordinator.execute(
        graph: graph,
        workspaceURL: tempDir,
        runtime: runtime,
        context: context,
        generator: generator
      )
      XCTFail("Expected CancellationError")
    } catch is CancellationError {
      XCTAssertTrue(cancellation.isCancelled)
    }
  }

  // MARK: - 11. EditPlanner heuristics and validation retry

  func testEditPlannerHeuristics() throws {
    XCTAssertTrue(EditPlanner.shouldOrchestrate(
      request: "Please decompose this refactoring into a task graph",
      candidatePaths: [],
      workspaceURL: tempDir
    ))

    XCTAssertTrue(EditPlanner.shouldOrchestrate(
      request: "Rename symbol across all files",
      candidatePaths: [],
      workspaceURL: tempDir
    ))

    XCTAssertTrue(EditPlanner.shouldOrchestrate(
      request: "Update both files in multiple files",
      candidatePaths: ["a.swift", "b.swift"],
      workspaceURL: tempDir
    ))

    XCTAssertFalse(EditPlanner.shouldOrchestrate(
      request: "Fix a typo in main.swift",
      candidatePaths: ["main.swift"],
      workspaceURL: tempDir
    ))
  }

  func testEditPlannerParsesJSONAndRetriesOnValidationFailure() async throws {
    try write("valid.swift", "code")

    final class Box: @unchecked Sendable {
      var attempts = 0
    }
    let box = Box()
    let graph = try await EditPlanner.plan(
      request: "Test plan",
      candidatePaths: ["valid.swift"],
      workspaceURL: tempDir,
      generate: { prompt in
        box.attempts += 1
        if box.attempts == 1 {
          // Return invalid plan (missing ID)
          return """
            {
              "tasks": [
                { "id": "", "path": "valid.swift", "objective": "none", "kind": "inspect" }
              ]
            }
            """
        } else {
          // Return corrected plan
          return """
            {
              "tasks": [
                { "id": "t1", "path": "valid.swift", "objective": "inspect valid", "kind": "inspect" }
              ]
            }
            """
        }
      }
    )

    XCTAssertEqual(box.attempts, 2, "Planner must retry once on validation failure")
    XCTAssertEqual(graph.tasks.count, 1)
    XCTAssertEqual(graph.tasks[0].id, "t1")
  }

  // MARK: - 12. End-to-end multi-wave execution and whole-file validation

  func testEndToEndMultiWaveExecutionAndValidation() async throws {
    try write("ComponentA.swift", "func a() -> Int { return 1 }\n")
    try write("ComponentB.swift", "func b() -> Int { return 2 }\n")

    let tasks = [
      EditTask(id: "task_a", path: "ComponentA.swift", objective: "Update A", kind: .edit),
      EditTask(id: "task_b", path: "ComponentB.swift", objective: "Update B", kind: .edit, dependencies: ["task_a"]),
    ]

    let graph = try TaskGraph(tasks: tasks, workspaceURL: tempDir)

    let generator = BlockProposalGenerator { task, baseRev, _ in
      if task.id == "task_a" {
        return TaskProposal(
          taskID: task.id,
          path: task.path,
          kind: .edit,
          baseRevision: baseRev,
          hunks: [AgentWritePreview.PatchHunk(target: "return 1", replacement: "return 100")]
        )
      } else {
        // Assert ComponentA was already applied before ComponentB generates!
        let compA = try? String(contentsOf: self.tempDir.appendingPathComponent("ComponentA.swift"), encoding: .utf8)
        XCTAssertEqual(compA, "func a() -> Int { return 100 }\n", "Dependent task must see accepted predecessor output")
        return TaskProposal(
          taskID: task.id,
          path: task.path,
          kind: .edit,
          baseRevision: baseRev,
          hunks: [AgentWritePreview.PatchHunk(target: "return 2", replacement: "return 200")]
        )
      }
    }

    let runtime = try await makeRuntime()
    let coordinator = PatchCoordinator()
    let result = try await coordinator.execute(
      graph: graph,
      workspaceURL: tempDir,
      runtime: runtime,
      context: makeContext(),
      generator: generator
    )

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.appliedFiles, ["ComponentA.swift", "ComponentB.swift"])
    XCTAssertEqual(try contents("ComponentA.swift"), "func a() -> Int { return 100 }\n")
    XCTAssertEqual(try contents("ComponentB.swift"), "func b() -> Int { return 200 }\n")

    // Check RepositoryIndex was refreshed
    let entryA = RepositoryIndex.forWorkspace(tempDir).entry(for: "ComponentA.swift")
    XCTAssertNotNil(entryA)
    XCTAssertEqual(entryA?.digest, FileRevision.digest(of: try contents("ComponentA.swift")))
  }
}

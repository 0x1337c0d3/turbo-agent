import Foundation

struct OrchestrationResult: Sendable {
  let succeeded: Bool
  let appliedFiles: [String]
  let completedTasks: [String]
  let failedTasks: [String: String]
  let blockedTasks: [String: String]
  let validationWarnings: [String]
  let summary: String

  init(
    succeeded: Bool,
    appliedFiles: [String],
    completedTasks: [String],
    failedTasks: [String: String],
    blockedTasks: [String: String],
    validationWarnings: [String] = [],
    summary: String
  ) {
    self.succeeded = succeeded
    self.appliedFiles = appliedFiles
    self.completedTasks = completedTasks
    self.failedTasks = failedTasks
    self.blockedTasks = blockedTasks
    self.validationWarnings = validationWarnings
    self.summary = summary
  }
}

/// Coordinates execution waves, validates base revisions and proposals,
/// manages approval, and applies changes atomically with whole-file validation.
final class PatchCoordinator: Sendable {
  init() {}

  /// Executes a large-file edit via federated context execution across bounded narrow workers.
  func executeFederated(
    task: EditTask,
    workspaceURL: URL,
    runtime: AgentRuntime,
    context: AgentToolContext,
    targetRanges: [ClosedRange<Int>] = [],
    worker: FederatedWorkerProtocol? = nil,
    fallbackGenerator: TaskProposalGenerator? = nil,
    config: FederatedConfig? = nil,
    approvalHandler: (@Sendable (AgentWritePlan) async -> Bool)? = nil
  ) async throws -> FederatedExecutionResult {
    let executor = FederatedContextExecutor()
    return try await executor.execute(
      path: task.path,
      objective: task.objective,
      workspaceURL: workspaceURL,
      runtime: runtime,
      context: context,
      targetRanges: targetRanges.isEmpty ? task.ranges : targetRanges,
      worker: worker,
      fallbackGenerator: fallbackGenerator,
      config: config,
      approvalHandler: approvalHandler
    )
  }

  func execute(
    graph: TaskGraph,
    workspaceURL: URL,
    runtime: AgentRuntime,
    context: AgentToolContext,
    generator: TaskProposalGenerator,
    executorConfig: ExecutorConfig? = nil,
    approvalHandler: (@Sendable (AgentWritePlan) async -> Bool)? = nil
  ) async throws -> OrchestrationResult {
    let effectiveConfig = executorConfig ?? ExecutorConfig.defaultConfig(for: runtime)
    let executor = EditExecutor(config: effectiveConfig)

    var appliedFiles: [String] = []
    var validationWarnings: [String] = []

    for wave in graph.waves {
      // Check cancellation
      if context.cancellation.isCancelled || Task.isCancelled {
        context.terminal?.restore()
        for task in wave {
          graph.markFailed(taskID: task.id, reason: "Cancelled by user")
        }
        throw CancellationError()
      }

      // 1. Snapshot base revisions for all files targeted in this wave
      var baseRevisions: [String: FileRevision] = [:]
      for task in wave {
        if let rev = FileRevision.snapshot(path: task.path, workspaceURL: workspaceURL) {
          baseRevisions[task.path] = rev
        }
      }

      // Mark tasks in progress
      for task in wave {
        graph.markInProgress(taskID: task.id)
      }

      // 2 & 3. Execute wave to collect proposals
      let proposals: [TaskProposal]
      do {
        proposals = try await executor.executeWave(
          tasks: wave,
          baseRevisions: baseRevisions,
          workspaceURL: workspaceURL,
          context: context,
          generator: generator,
          cancellation: context.cancellation
        )
      } catch is CancellationError {
        context.terminal?.restore()
        for task in wave {
          graph.markFailed(taskID: task.id, reason: "Cancelled by user")
        }
        throw CancellationError()
      } catch {
        // Partial executor failure: do not apply anything from this wave
        for task in wave {
          graph.markFailed(taskID: task.id, reason: "Executor error: \(error)")
        }
        return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
      }

      // 4. Validate proposals: check base revisions, duplicate ownership, and hunk validity
      var mutatingProposals: [TaskProposal] = []
      var mutatingPathsInWave = Set<String>()

      for proposal in proposals {
        guard let task = graph.task(for: proposal.taskID) else { continue }
        if task.kind.isMutating {
          guard !mutatingPathsInWave.contains(proposal.path) else {
            graph.markFailed(taskID: proposal.taskID, reason: "Duplicate mutating proposal for path: \(proposal.path)")
            return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
          }
          mutatingPathsInWave.insert(proposal.path)
          mutatingProposals.append(proposal)

          // Verify base revision hasn't changed on disk
          let currentDiskRev = FileRevision.snapshot(path: proposal.path, workspaceURL: workspaceURL)
          if task.kind == .edit || task.kind == .delete {
            guard let expectedBase = proposal.baseRevision else {
              graph.markFailed(taskID: proposal.taskID, reason: "Missing base revision for \(proposal.path)")
              return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
            }
            guard currentDiskRev?.digest == expectedBase.digest else {
              graph.markFailed(taskID: proposal.taskID, reason: "staleRevision: \(proposal.path) changed on disk during task execution")
              return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
            }
          } else if task.kind == .create {
            guard currentDiskRev == nil else {
              graph.markFailed(taskID: proposal.taskID, reason: "File already exists on disk: \(proposal.path)")
              return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
            }
          }
        }
      }

      // 5. Build write plans and request approval
      var writePlans: [(proposal: TaskProposal, plan: AgentWritePlan)] = []
      var deletePlans: [TaskProposal] = []

      for proposal in mutatingProposals {
        let resolvedPath = URL(fileURLWithPath: proposal.path, relativeTo: workspaceURL).standardizedFileURL.path
        if proposal.kind == .create {
          let content = proposal.newContent ?? ""
          let plan = AgentWritePlan(
            path: proposal.path,
            resolvedPath: resolvedPath,
            originalContent: nil,
            updatedContent: content,
            diff: AgentWritePreview.render(path: proposal.path, before: nil, after: content)
          )
          writePlans.append((proposal, plan))
        } else if proposal.kind == .edit {
          let original = (try? String(contentsOfFile: resolvedPath, encoding: .utf8)) ?? ""
          let updated: String
          if !proposal.hunks.isEmpty {
            // Apply hunks against original with overlap checking
            do {
              updated = try applyHunks(proposal.hunks, to: original, path: proposal.path)
            } catch {
              graph.markFailed(taskID: proposal.taskID, reason: "Hunk application error: \(error)")
              return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
            }
          } else if let newContent = proposal.newContent {
            updated = newContent
          } else {
            updated = original
          }
          let plan = AgentWritePlan(
            path: proposal.path,
            resolvedPath: resolvedPath,
            originalContent: original,
            updatedContent: updated,
            diff: AgentWritePreview.render(path: proposal.path, before: original, after: updated)
          )
          writePlans.append((proposal, plan))
        } else if proposal.kind == .delete {
          deletePlans.append(proposal)
        }
      }

      // Check approval for all mutating changes in this wave
      for item in writePlans {
        let plan = item.plan
        let proposal = item.proposal
        let approved: Bool
        if runtime.config.yolo {
          ToolApproval.displayDiff(plan.diff)
          approved = true
        } else if let approvalHandler {
          approved = await approvalHandler(plan)
        } else if let interaction = context.interaction {
          let call = ParsedToolCall(
            id: UUID().uuidString,
            name: "apply_patch",
            arguments: .object(["path": .string(plan.path)]),
            argumentsJSON: "{}"
          )
          approved = await interaction.approve(call, plan.diff)
        } else {
          let call = ParsedToolCall(
            id: UUID().uuidString,
            name: "apply_patch",
            arguments: .object(["path": .string(plan.path)]),
            argumentsJSON: "{}"
          )
          approved = ToolApproval.request(call, diff: plan.diff)
        }

        guard approved else {
          graph.markFailed(taskID: proposal.taskID, reason: "Diff approval denied for \(plan.path)")
          return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
        }
      }

      // 6. Apply approved files atomically
      for item in writePlans {
        let plan = item.plan
        do {
          try await plan.verifySourceIsUnchanged(context: context)
          try await ToolRegistry.writeFile(plan.resolvedPath, content: plan.updatedContent, context: context)
          appliedFiles.append(plan.path)
        } catch {
          graph.markFailed(taskID: item.proposal.taskID, reason: "Write failed for \(plan.path): \(error)")
          return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
        }
      }

      for proposal in deletePlans {
        let resolved = URL(fileURLWithPath: proposal.path, relativeTo: workspaceURL).standardizedFileURL.path
        do {
          try FileManager.default.removeItem(atPath: resolved)
          appliedFiles.append(proposal.path)
        } catch {
          graph.markFailed(taskID: proposal.taskID, reason: "Delete failed for \(proposal.path): \(error)")
          return buildResult(graph: graph, succeeded: false, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
        }
      }

      // 7. Refresh repository index
      let repoIndex = RepositoryIndex.forWorkspace(workspaceURL)
      for item in writePlans {
        repoIndex.refresh(resolvedPath: item.plan.resolvedPath)
        ReadRevisionLedger.shared.record(
          resolvedPath: item.plan.resolvedPath,
          digest: FileRevision.digest(of: item.plan.updatedContent),
          byteCount: item.plan.updatedContent.utf8.count,
          complete: true
        )
      }

      // 8. Whole-file validation
      for item in writePlans {
        let validationNote = ToolRegistry.validateWholeFile(path: item.plan.resolvedPath, content: item.plan.updatedContent)
        if !validationNote.isEmpty {
          validationWarnings.append("\(item.plan.path): \(validationNote)")
        }
      }

      // 9. Mark tasks in wave as completed
      for task in wave {
        let proposal = proposals.first(where: { $0.taskID == task.id })
        let summary = proposal?.summary.isEmpty == false ? proposal!.summary : "Completed \(task.kind.rawValue) on \(task.path)"
        graph.markCompleted(taskID: task.id, summary: summary)
      }
    }

    return buildResult(graph: graph, succeeded: true, appliedFiles: appliedFiles, validationWarnings: validationWarnings)
  }

  private func applyHunks(_ hunks: [AgentWritePreview.PatchHunk], to original: String, path: String) throws -> String {
    var locatedHunks: [(hunk: AgentWritePreview.PatchHunk, range: Range<String.Index>)] = []
    for hunk in hunks {
      var target = hunk.target
      var range = original.range(of: target)
      if range == nil {
        let stripped = target.replacingOccurrences(
          of: #"^\s*\d+:\s*"#, with: "", options: .regularExpression)
        if stripped != target {
          range = original.range(of: stripped)
          target = stripped
        }
      }
      guard let foundRange = range else {
        throw AgentWritePreview.Error.targetNotFound(path)
      }
      locatedHunks.append((hunk: AgentWritePreview.PatchHunk(target: target, replacement: hunk.replacement), range: foundRange))
    }

    // Reject overlapping hunks
    let sorted = locatedHunks.sorted { $0.range.lowerBound < $1.range.lowerBound }
    for i in 0..<(sorted.count - 1) {
      if sorted[i].range.upperBound > sorted[i + 1].range.lowerBound {
        throw AgentWritePreview.Error.overlappingHunks(path)
      }
    }

    // Apply in reverse order so string indices remain valid
    var updated = original
    for item in sorted.reversed() {
      updated.replaceSubrange(item.range, with: item.hunk.replacement)
    }
    return updated
  }

  private func buildResult(
    graph: TaskGraph,
    succeeded: Bool,
    appliedFiles: [String],
    validationWarnings: [String]
  ) -> OrchestrationResult {
    var completed: [String] = []
    var failed: [String: String] = [:]
    var blocked: [String: String] = [:]

    for (id, status) in graph.statuses {
      switch status {
      case .completed:
        completed.append(id)
      case .failed(let reason):
        failed[id] = reason
      case .blocked(_, let reason):
        blocked[id] = reason
      case .pending, .inProgress:
        break
      }
    }

    let summary = succeeded
      ? "Orchestration succeeded: \(completed.count) tasks completed, \(appliedFiles.count) files applied."
      : "Orchestration halted: \(failed.count) task(s) failed, \(blocked.count) task(s) blocked."

    return OrchestrationResult(
      succeeded: succeeded,
      appliedFiles: appliedFiles,
      completedTasks: completed,
      failedTasks: failed,
      blockedTasks: blocked,
      validationWarnings: validationWarnings,
      summary: summary
    )
  }
}

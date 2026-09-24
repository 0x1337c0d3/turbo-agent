import Foundation

struct TaskProposal: Sendable, Equatable {
  let taskID: String
  let path: String
  let kind: EditTask.Kind
  let baseRevision: FileRevision?
  let hunks: [AgentWritePreview.PatchHunk]
  let newContent: String?
  let summary: String

  init(
    taskID: String,
    path: String,
    kind: EditTask.Kind,
    baseRevision: FileRevision? = nil,
    hunks: [AgentWritePreview.PatchHunk] = [],
    newContent: String? = nil,
    summary: String = ""
  ) {
    self.taskID = taskID
    self.path = path
    self.kind = kind
    self.baseRevision = baseRevision
    self.hunks = hunks
    self.newContent = newContent
    self.summary = summary
  }
}

protocol TaskProposalGenerator: Sendable {
  func generateProposal(
    task: EditTask,
    baseRevision: FileRevision?,
    workspaceURL: URL,
    context: AgentToolContext
  ) async throws -> TaskProposal
}

struct ModelTaskProposalGenerator: TaskProposalGenerator {
  let runtime: AgentRuntime
  let forceLocal: Bool
  let enableFederatedExecution: Bool

  init(runtime: AgentRuntime, forceLocal: Bool = false, enableFederatedExecution: Bool = false) {
    self.runtime = runtime
    self.forceLocal = forceLocal
    self.enableFederatedExecution = enableFederatedExecution
  }

  func generateProposal(
    task: EditTask,
    baseRevision: FileRevision?,
    workspaceURL: URL,
    context: AgentToolContext
  ) async throws -> TaskProposal {
    if enableFederatedExecution, task.kind == .edit, let baseRev = baseRevision, baseRev.byteCount > 8_000 {
      let federated = FederatedContextExecutor()
      return try await federated.propose(
        taskID: task.id,
        path: task.path,
        objective: task.objective,
        workspaceURL: workspaceURL,
        runtime: runtime,
        context: context,
        targetRanges: task.ranges
      )
    }

    if task.kind == .inspect || task.kind == .validate {

      return TaskProposal(taskID: task.id, path: task.path, kind: task.kind, baseRevision: baseRevision, summary: "Inspected \(task.path)")
    }

    if task.kind == .delete {
      return TaskProposal(taskID: task.id, path: task.path, kind: task.kind, baseRevision: baseRevision, summary: "Deleted \(task.path)")
    }

    let resolvedURL = URL(fileURLWithPath: task.path, relativeTo: workspaceURL).standardizedFileURL
    let existingContent = (try? String(contentsOfFile: resolvedURL.path, encoding: .utf8)) ?? ""

    var sourceContext = ""
    if task.kind == .edit {
      if !task.ranges.isEmpty {
        let lines = FileSlicer.splitLines(existingContent)
        var sliceLines: [String] = []
        for r in task.ranges {
          let clampedStart = max(1, min(lines.count, r.lowerBound))
          let clampedEnd = max(clampedStart, min(lines.count, r.upperBound))
          if clampedStart <= clampedEnd {
            for i in clampedStart...clampedEnd {
              sliceLines.append("\(i): \(lines[i - 1])")
            }
          }
        }
        sourceContext = sliceLines.joined(separator: "\n")
      } else {
        sourceContext = String(existingContent.prefix(8_000))
      }
    }

    let prompt = """
      Task ID: \(task.id)
      Path: \(task.path)
      Kind: \(task.kind.rawValue)
      Objective: \(task.objective)
      \(baseRevision.map { "Base revision: \($0.digest)" } ?? "")

      \(sourceContext.isEmpty ? "" : "Source:\n" + sourceContext)

      \(task.kind == .edit ? "Return JSON with hunks: [{\"target\": \"exact target to replace (without line numbers)\", \"replacement\": \"new replacement text\"}]. Do not include line numbers in target or replacement." : "Return JSON with content: {\"content\": \"new file content\"}")
      """

    let messages = [
      AgentMessage(role: .system, content: "You are an edit proposal generator. Output valid JSON.", toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(role: .user, content: prompt, toolCalls: [], toolCallID: nil, name: nil)
    ]

    let (reply, _) = try await runtime.generate(
      messages: messages,
      tools: [],
      interaction: context.interaction,
      cancellation: context.cancellation,
      terminal: nil,
      forceLocal: forceLocal
    )

    if task.kind == .create {
      let jsonString = EditPlanner.extractJSON(from: reply)
      
      var content: String? = nil
      if let data = jsonString.data(using: .utf8),
         let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let c = dict["content"] as? String {
        content = c
      } else {
        content = jsonString
      }
      return TaskProposal(taskID: task.id, path: task.path, kind: .create, newContent: content, summary: "Created \(task.path)")
    } else {
      var hunks: [AgentWritePreview.PatchHunk] = []
      
      let jsonString = EditPlanner.extractJSON(from: reply)
      
      if let data = jsonString.data(using: .utf8) {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
          for item in array {
            if let target = item["target"] as? String, let rep = item["replacement"] as? String {
              hunks.append(AgentWritePreview.PatchHunk(target: target, replacement: rep))
            }
          }
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let array = dict["hunks"] as? [[String: Any]] {
          for item in array {
            if let target = item["target"] as? String, let rep = item["replacement"] as? String {
              hunks.append(AgentWritePreview.PatchHunk(target: target, replacement: rep))
            }
          }
        }
      }
      return TaskProposal(taskID: task.id, path: task.path, kind: .edit, baseRevision: baseRevision, hunks: hunks, summary: "Proposed \(hunks.count) hunks for \(task.path)")
    }
  }
}

struct ExecutorConfig: Sendable, Equatable {
  let maxInferenceConcurrency: Int
  let enableFederatedExecution: Bool
  let federatedConfig: FederatedConfig

  static let localDefault = ExecutorConfig(maxInferenceConcurrency: 1)
  static let remoteDefault = ExecutorConfig(maxInferenceConcurrency: 3)

  init(
    maxInferenceConcurrency: Int,
    enableFederatedExecution: Bool = false,
    federatedConfig: FederatedConfig = .default
  ) {
    self.maxInferenceConcurrency = max(1, maxInferenceConcurrency)
    self.enableFederatedExecution = enableFederatedExecution
    self.federatedConfig = federatedConfig
  }

  /// Determines default configuration based on model target.
  static func defaultConfig(for runtime: AgentRuntime) -> ExecutorConfig {
    if runtime.currentTarget.isLocal || (runtime.activeBackendKind == .apple && runtime.applePCCPolicy == .disable) {
      return .localDefault
    }
    return .remoteDefault
  }
}

/// Executes individual tasks in an execution wave to collect proposals.
final class EditExecutor: Sendable {
  let config: ExecutorConfig

  init(config: ExecutorConfig = .remoteDefault) {
    self.config = config
  }

  /// Executes tasks in a wave concurrently up to `config.maxInferenceConcurrency`.
  func executeWave(
    tasks: [EditTask],
    baseRevisions: [String: FileRevision],
    workspaceURL: URL,
    context: AgentToolContext,
    generator: TaskProposalGenerator,
    cancellation: AgentCancellation? = nil
  ) async throws -> [TaskProposal] {
    try cancellation?.check()
    guard !tasks.isEmpty else { return [] }

    if config.maxInferenceConcurrency == 1 {
      var proposals: [TaskProposal] = []
      for task in tasks {
        try cancellation?.check()
        let baseRev = baseRevisions[task.path]
        let proposal = try await generator.generateProposal(
          task: task,
          baseRevision: baseRev,
          workspaceURL: workspaceURL,
          context: context
        )
        try cancellation?.check()
        proposals.append(proposal)
      }
      return proposals
    }

    // Bounded concurrent execution
    return try await withThrowingTaskGroup(of: TaskProposal.self) { group in
      var proposals: [TaskProposal] = []
      var taskIterator = tasks.makeIterator()
      var inFlight = 0

      while inFlight < config.maxInferenceConcurrency, let task = taskIterator.next() {
        inFlight += 1
        let baseRev = baseRevisions[task.path]
        group.addTask {
          try cancellation?.check()
          return try await generator.generateProposal(
            task: task,
            baseRevision: baseRev,
            workspaceURL: workspaceURL,
            context: context
          )
        }
      }

      while let proposal = try await group.next() {
        try cancellation?.check()
        proposals.append(proposal)

        if let nextTask = taskIterator.next() {
          let baseRev = baseRevisions[nextTask.path]
          group.addTask {
            try cancellation?.check()
            return try await generator.generateProposal(
              task: nextTask,
              baseRevision: baseRev,
              workspaceURL: workspaceURL,
              context: context
            )
          }
        }
      }

      return proposals
    }
  }
}

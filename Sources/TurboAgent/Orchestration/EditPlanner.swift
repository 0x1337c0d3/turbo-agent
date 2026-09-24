import Foundation

struct EditPlanner: Sendable {
  static let defaultSourceAllowance = 32_000

  /// Determines whether a task should be routed through task graph orchestration.
  static func shouldOrchestrate(
    request: String,
    candidatePaths: [String] = [],
    workspaceURL: URL,
    sourceAllowance: Int = defaultSourceAllowance
  ) -> Bool {
    let lowerRequest = request.lowercased()

    // 1. Explicit decomposition request
    if lowerRequest.contains("decompose")
      || lowerRequest.contains("task graph")
      || lowerRequest.contains("plan tasks")
      || lowerRequest.contains("orchestrate")
    {
      return true
    }

    // 2. Repository-wide rename or migration
    if (lowerRequest.contains("rename") && (lowerRequest.contains("across") || lowerRequest.contains("in all") || lowerRequest.contains("everywhere")))
      || lowerRequest.contains("migrate")
      || lowerRequest.contains("migration")
      || lowerRequest.contains("refactor across")
    {
      return true
    }

    // 3. Retrieval identifies multiple likely edit files and request suggests multi-file edits
    let multiFileKeywords = ["both", "all files", "multiple files", "across", "and update", "then update"]
    let hasMultiFileIntent = multiFileKeywords.contains(where: { lowerRequest.contains($0) })

    let editKeywords = [
      "edit", "update", "modify", "change", "refactor", "fix", "repair",
      "replace", "add", "remove", "delete", "create", "implement", "patch",
      "rename", "migrate", "rewrite", "apply"
    ]
    let hasEditIntent = editKeywords.contains(where: { lowerRequest.contains($0) })

    if candidatePaths.count >= 2 && hasMultiFileIntent && hasEditIntent {
      return true
    }

    // 4. Target file cannot be read completely within its source allowance and there is edit intent
    if hasEditIntent {
      let mentionedPaths = candidatePaths.filter {
        request.contains($0) || request.contains(($0 as NSString).lastPathComponent)
      }
      let targetPaths = !mentionedPaths.isEmpty ? mentionedPaths : Array(candidatePaths.prefix(1))
      for path in targetPaths {
        let resolved = URL(fileURLWithPath: path, relativeTo: workspaceURL).standardizedFileURL
        if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
          let size = attrs[.size] as? Int, size > sourceAllowance
        {
          return true
        }
      }
    }

    return false
  }

  /// Determines whether a large file task should use federated context execution.
  static func shouldFederate(
    path: String,
    workspaceURL: URL,
    sourceAllowance: Int = defaultSourceAllowance
  ) -> Bool {
    let resolved = URL(fileURLWithPath: path, relativeTo: workspaceURL).standardizedFileURL
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
          let size = attrs[.size] as? Int, size > sourceAllowance
    else {
      return false
    }
    return true
  }

  /// System instructions for generating a valid EditTask plan.
  static let plannerInstructions: String = """
    You are Turbo Agent's task planner. Your role is to decompose large or multi-file coding tasks into an acyclic task graph.
    Output ONLY a JSON object with this exact structure:
    {
      "tasks": [
        {
          "id": "task_1",
          "path": "relative/path/to/file",
          "objective": "Concise objective for this task",
          "kind": "inspect" | "edit" | "create" | "delete" | "validate",
          "ranges": [[1, 50]],
          "reference_paths": [],
          "dependencies": []
        }
      ]
    }

    Validation rules:
    - Maximum 32 tasks and 32 files.
    - Every plan for an edit or modification request MUST include the mutating tasks ('edit', 'create', 'delete') needed to perform the requested changes. Do not output only 'inspect' tasks when edits, comments, or code modifications are requested.
    - At most ONE mutating task (edit, create, delete) per file per execution wave. For edits spanning multiple disconnected locations in the same file, provide all line ranges in a single edit task's `ranges` array.
    - 'edit', 'inspect', and 'delete' tasks require that the file exists on disk (or is created by a prior wave).
    - 'create' tasks require that the file does NOT exist on disk (or is deleted by a prior wave).
    - Dependencies must be acyclic and refer only to valid task IDs.
    - Never invent files outside the workspace.
    """

  /// Parses a TaskGraph from untrusted JSON text.
  static func parsePlan(
    from jsonString: String,
    workspaceURL: URL,
    maxTasks: Int = TaskGraph.defaultMaxTasks,
    maxFiles: Int = TaskGraph.defaultMaxFiles
  ) throws -> TaskGraph {
    let cleanJSON = extractJSON(from: jsonString)
    guard let data = cleanJSON.data(using: .utf8) else {
      throw TaskGraphValidationError.emptyTasks
    }

    let tasks: [EditTask]
    if let array = try? JSONDecoder().decode([EditTask].self, from: data) {
      tasks = array
    } else if let wrapper = try? JSONDecoder().decode(TaskEnvelope.self, from: data) {
      tasks = wrapper.tasks
    } else {
      throw TaskGraphValidationError.emptyTasks
    }

    return try TaskGraph(tasks: tasks, workspaceURL: workspaceURL, maxTasks: maxTasks, maxFiles: maxFiles)
  }

  private struct TaskEnvelope: Codable {
    let tasks: [EditTask]
  }

  static func extractJSON(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") {
      let lines = trimmed.components(separatedBy: "\n")
      let filtered = lines.dropFirst().prefix(while: { !$0.hasPrefix("```") })
      return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
      return String(trimmed[start...end])
    }
    if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]") {
      return String(trimmed[start...end])
    }
    return trimmed
  }

  static func hasEditIntent(_ request: String) -> Bool {
    let lower = request.lowercased()
    let editWords = ["edit", "add", "comment", "modify", "update", "create", "delete", "remove", "change", "insert", "fix", "repair", "replace", "patch"]
    return editWords.contains { lower.contains($0) }
  }

  static func synthesizeEditTaskIfNeeded(
    in graph: TaskGraph,
    request: String,
    candidatePaths: [String],
    workspaceURL: URL
  ) -> TaskGraph {
    guard hasEditIntent(request) && !graph.tasks.contains(where: { $0.kind.isMutating }) else {
      return graph
    }
    let inspectTasks = graph.tasks.filter { $0.kind == .inspect }
    let targetPath = inspectTasks.first?.path ?? candidatePaths.first ?? ""
    guard !targetPath.isEmpty else { return graph }

    let allRanges = inspectTasks.flatMap { $0.ranges }
    let editTask = EditTask(
      id: "task_edit",
      path: targetPath,
      objective: request,
      kind: .edit,
      ranges: allRanges,
      referencePaths: [],
      dependencies: inspectTasks.map(\.id)
    )
    if let synthesized = try? TaskGraph(tasks: graph.tasks + [editTask], workspaceURL: workspaceURL) {
      return synthesized
    }
    return graph
  }

  /// Plans a task graph using a generation closure, with automatic single-retry on validation failure.
  static func plan(
    request: String,
    candidatePaths: [String],
    workspaceURL: URL,
    generate: @Sendable (_ prompt: String) async throws -> String
  ) async throws -> TaskGraph {
    let userPrompt = """
      Request: \(request)
      Candidate paths: \(candidatePaths.joined(separator: ", "))
      Workspace: \(workspaceURL.lastPathComponent)

      Generate the JSON task graph following the rules.
      """

    let firstOutput = try await generate(userPrompt)
    do {
      let graph = try parsePlan(from: firstOutput, workspaceURL: workspaceURL)
      if hasEditIntent(request) && !graph.tasks.contains(where: { $0.kind.isMutating }) {
        throw TaskGraphValidationError.missingMutatingTask
      }
      return graph
    } catch {
      // Retry once with a compact validation error
      let compactError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      let retryPrompt = """
        \(userPrompt)

        Your previous plan was invalid:
        \(compactError)

        Please correct this error and return a valid JSON task graph.
        """
      let secondOutput = try await generate(retryPrompt)
      do {
        let retryGraph = try parsePlan(from: secondOutput, workspaceURL: workspaceURL)
        if hasEditIntent(request) && !retryGraph.tasks.contains(where: { $0.kind.isMutating }) {
          return synthesizeEditTaskIfNeeded(in: retryGraph, request: request, candidatePaths: candidatePaths, workspaceURL: workspaceURL)
        }
        return retryGraph
      } catch {
        if let fallback = try? parsePlan(from: firstOutput, workspaceURL: workspaceURL) {
          return synthesizeEditTaskIfNeeded(in: fallback, request: request, candidatePaths: candidatePaths, workspaceURL: workspaceURL)
        }
        throw error
      }
    }
  }
}

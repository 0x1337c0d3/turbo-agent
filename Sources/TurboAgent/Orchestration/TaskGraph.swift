import Foundation

enum TaskGraphValidationError: LocalizedError, Equatable, Sendable {
  case emptyTasks
  case missingMutatingTask
  case tooManyTasks(count: Int, limit: Int)
  case tooManyFiles(count: Int, limit: Int)
  case missingID(index: Int)
  case duplicateID(String)
  case missingPath(taskID: String)
  case pathEscapesWorkspace(taskID: String, path: String)
  case invalidRange(taskID: String, path: String, start: Int, end: Int)
  case unknownDependency(taskID: String, dependency: String)
  case selfDependency(taskID: String)
  case cycleDetected(taskIDs: [String])
  case duplicateWriteOwner(path: String, wave: Int)
  case fileNotFound(taskID: String, path: String, kind: EditTask.Kind)
  case fileAlreadyExists(taskID: String, path: String)

  var errorDescription: String? {
    switch self {
    case .emptyTasks:
      return "Task graph cannot be empty."
    case .missingMutatingTask:
      return "The request asks to modify or edit code, but the task plan contains no mutating tasks ('edit', 'create', 'delete'). You must include an 'edit' task to perform the requested modifications."
    case .tooManyTasks(let count, let limit):
      return "Task count \(count) exceeds maximum allowed limit of \(limit)."
    case .tooManyFiles(let count, let limit):
      return "Target file count \(count) exceeds maximum allowed limit of \(limit)."
    case .missingID(let index):
      return "Task at index \(index) has an empty or missing ID."
    case .duplicateID(let id):
      return "Duplicate task ID: '\(id)'."
    case .missingPath(let taskID):
      return "Task '\(taskID)' has an empty or missing path."
    case .pathEscapesWorkspace(let taskID, let path):
      return "Task '\(taskID)' path '\(path)' escapes the workspace directory."
    case .invalidRange(let taskID, let path, let start, let end):
      return "Task '\(taskID)' on '\(path)' specifies invalid line range \(start)-\(end)."
    case .unknownDependency(let taskID, let dependency):
      return "Task '\(taskID)' depends on unknown task ID '\(dependency)'."
    case .selfDependency(let taskID):
      return "Task '\(taskID)' cannot depend on itself."
    case .cycleDetected(let taskIDs):
      return "Cycle detected in task dependencies: \(taskIDs.joined(separator: " -> "))."
    case .duplicateWriteOwner(let path, let wave):
      return "Wave \(wave) has multiple write owners for path '\(path)'."
    case .fileNotFound(let taskID, let path, let kind):
      return "Task '\(taskID)' (\(kind.rawValue)) targets nonexistent file '\(path)'."
    case .fileAlreadyExists(let taskID, let path):
      return "Task '\(taskID)' (create) targets already existing file '\(path)'."
    }
  }
}

enum TaskExecutionStatus: Sendable, Equatable {
  case pending
  case inProgress
  case completed(summary: String)
  case failed(reason: String)
  case blocked(dependencyID: String, reason: String)

  var isTerminal: Bool {
    switch self {
    case .completed, .failed, .blocked: return true
    case .pending, .inProgress: return false
    }
  }
}

/// A validated acyclic graph of edit tasks organized into topological waves.
final class TaskGraph: @unchecked Sendable {
  static let defaultMaxTasks = 32
  static let defaultMaxFiles = 32

  let tasks: [EditTask]
  let waves: [[EditTask]]
  let workspaceURL: URL

  private let lock = NSLock()
  private var taskMap: [String: EditTask] = [:]
  private var taskStatuses: [String: TaskExecutionStatus] = [:]

  var allTaskIDs: [String] {
    tasks.map(\.id)
  }

  var statuses: [String: TaskExecutionStatus] {
    lock.withLock { taskStatuses }
  }

  func status(for taskID: String) -> TaskExecutionStatus? {
    lock.withLock { taskStatuses[taskID] }
  }

  func task(for taskID: String) -> EditTask? {
    taskMap[taskID]
  }

  init(
    tasks rawTasks: [EditTask],
    workspaceURL: URL,
    maxTasks: Int = defaultMaxTasks,
    maxFiles: Int = defaultMaxFiles
  ) throws {
    guard !rawTasks.isEmpty else {
      throw TaskGraphValidationError.emptyTasks
    }
    guard rawTasks.count <= maxTasks else {
      throw TaskGraphValidationError.tooManyTasks(count: rawTasks.count, limit: maxTasks)
    }

    self.workspaceURL = workspaceURL

    // Validate IDs and paths
    var seenIDs = Set<String>()
    var uniqueFiles = Set<String>()
    var coalescedTasks: [EditTask] = []

    let workspacePath = workspaceURL.standardizedFileURL.path

    for (index, task) in rawTasks.enumerated() {
      let trimmedID = task.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedID.isEmpty else {
        throw TaskGraphValidationError.missingID(index: index)
      }
      guard !seenIDs.contains(trimmedID) else {
        throw TaskGraphValidationError.duplicateID(trimmedID)
      }
      seenIDs.insert(trimmedID)

      let trimmedPath = task.path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedPath.isEmpty else {
        throw TaskGraphValidationError.missingPath(taskID: trimmedID)
      }

      // Check path resolution inside workspace
      let resolvedURL = URL(fileURLWithPath: trimmedPath, relativeTo: workspaceURL).standardizedFileURL
      let resolvedPath = resolvedURL.path
      guard resolvedPath == workspacePath || resolvedPath.hasPrefix(workspacePath + "/") else {
        throw TaskGraphValidationError.pathEscapesWorkspace(taskID: trimmedID, path: trimmedPath)
      }

      uniqueFiles.insert(trimmedPath)

      // Validate ranges
      for range in task.ranges {
        if range.lowerBound < 1 || range.upperBound < range.lowerBound {
          throw TaskGraphValidationError.invalidRange(
            taskID: trimmedID, path: trimmedPath, start: range.lowerBound, end: range.upperBound)
        }
      }

      coalescedTasks.append(task.withCoalescedRanges())
    }

    guard uniqueFiles.count <= maxFiles else {
      throw TaskGraphValidationError.tooManyFiles(count: uniqueFiles.count, limit: maxFiles)
    }

    // Validate dependencies
    for task in coalescedTasks {
      for dep in task.dependencies {
        if dep == task.id {
          throw TaskGraphValidationError.selfDependency(taskID: task.id)
        }
        guard seenIDs.contains(dep) else {
          throw TaskGraphValidationError.unknownDependency(taskID: task.id, dependency: dep)
        }
      }
    }

    // Topological sort into execution waves
    var remainingTasks = coalescedTasks
    var satisfiedDependencies = Set<String>()
    var computedWaves: [[EditTask]] = []

    while !remainingTasks.isEmpty {
      let ready = remainingTasks.filter { task in
        task.dependencies.allSatisfy { satisfiedDependencies.contains($0) }
      }

      if ready.isEmpty {
        // Cycle detected: extract participating tasks
        let cycleIDs = remainingTasks.map(\.id)
        throw TaskGraphValidationError.cycleDetected(taskIDs: cycleIDs)
      }

      computedWaves.append(ready)
      for task in ready {
        satisfiedDependencies.insert(task.id)
      }
      let readyIDs = Set(ready.map(\.id))
      remainingTasks.removeAll { readyIDs.contains($0.id) }
    }

    // Validate wave write ownership and disk/existence semantics
    var simulatedExistence: [String: Bool] = [:]
    for file in uniqueFiles {
      let resolved = URL(fileURLWithPath: file, relativeTo: workspaceURL).standardizedFileURL.path
      simulatedExistence[file] = FileManager.default.fileExists(atPath: resolved)
    }

    for (waveIndex, wave) in computedWaves.enumerated() {
      var mutatingPathsInWave = Set<String>()

      for task in wave {
        if task.kind.isMutating {
          guard !mutatingPathsInWave.contains(task.path) else {
            throw TaskGraphValidationError.duplicateWriteOwner(path: task.path, wave: waveIndex)
          }
          mutatingPathsInWave.insert(task.path)
        }

        let currentlyExists = simulatedExistence[task.path] ?? false
        switch task.kind {
        case .edit, .delete, .inspect:
          guard currentlyExists else {
            throw TaskGraphValidationError.fileNotFound(taskID: task.id, path: task.path, kind: task.kind)
          }
        case .create:
          guard !currentlyExists else {
            throw TaskGraphValidationError.fileAlreadyExists(taskID: task.id, path: task.path)
          }
        case .validate:
          break
        }
      }

      // Update simulated existence for next wave
      for task in wave {
        if task.kind == .create {
          simulatedExistence[task.path] = true
        } else if task.kind == .delete {
          simulatedExistence[task.path] = false
        }
      }
    }

    self.tasks = coalescedTasks
    self.waves = computedWaves

    for task in coalescedTasks {
      self.taskMap[task.id] = task
      self.taskStatuses[task.id] = .pending
    }
  }

  // MARK: - Status Transitions

  func markInProgress(taskID: String) {
    lock.withLock {
      taskStatuses[taskID] = .inProgress
    }
  }

  func markCompleted(taskID: String, summary: String) {
    lock.withLock {
      taskStatuses[taskID] = .completed(summary: summary)
    }
  }

  /// Marks a task failed, and automatically blocks all transitive dependents.
  func markFailed(taskID: String, reason: String) {
    lock.withLock {
      taskStatuses[taskID] = .failed(reason: reason)
      blockDependents(of: taskID, rootReason: reason)
    }
  }

  private func blockDependents(of failedID: String, rootReason: String) {
    var toBlock = [failedID]
    while !toBlock.isEmpty {
      let currentID = toBlock.removeFirst()
      for task in tasks where task.dependencies.contains(currentID) {
        if taskStatuses[task.id] == .pending || taskStatuses[task.id] == .inProgress {
          taskStatuses[task.id] = .blocked(
            dependencyID: failedID,
            reason: "Dependency '\(failedID)' failed: \(rootReason)"
          )
          toBlock.append(task.id)
        }
      }
    }
  }

  var remainingTaskIDs: [String] {
    lock.withLock {
      tasks.compactMap { task in
        let s = taskStatuses[task.id]
        return (s == .pending || s == .inProgress) ? task.id : nil
      }
    }
  }
}

import Foundation

// MARK: - Core Federated Types

/// A task assigned to an isolated worker inspecting a bounded slice of a large file.
struct FederatedWorkerTask: Sendable, Equatable, Identifiable {
  let id: String
  let path: String
  let objective: String
  let baseRevision: FileRevision
  let assignedRange: ClosedRange<Int>
  let sliceWithOverlap: FileSlice
  let referenceRanges: [ClosedRange<Int>]
  let overlapLines: Int

  init(
    id: String,
    path: String,
    objective: String,
    baseRevision: FileRevision,
    assignedRange: ClosedRange<Int>,
    sliceWithOverlap: FileSlice,
    referenceRanges: [ClosedRange<Int>] = [],
    overlapLines: Int = 10
  ) {
    self.id = id
    self.path = path
    self.objective = objective
    self.baseRevision = baseRevision
    self.assignedRange = assignedRange
    self.sliceWithOverlap = sliceWithOverlap
    self.referenceRanges = referenceRanges
    self.overlapLines = overlapLines
  }
}

/// Structured report returned by a narrow federated worker.
struct FederatedWorkerReport: Sendable, Equatable, Codable {
  let workerID: String
  let path: String
  let baseDigest: String
  let assignedRange: ClosedRange<Int>
  let findings: [String]
  let unresolvedReferences: [String]
  let relevantAnchors: [String]
  let dependencies: [String]
  let proposedHunks: [AgentWritePreview.PatchHunk]
  let needsMoreEvidence: Bool
  let evidenceRequests: [String]

  init(
    workerID: String,
    path: String,
    baseDigest: String,
    assignedRange: ClosedRange<Int>,
    findings: [String] = [],
    unresolvedReferences: [String] = [],
    relevantAnchors: [String] = [],
    dependencies: [String] = [],
    proposedHunks: [AgentWritePreview.PatchHunk] = [],
    needsMoreEvidence: Bool = false,
    evidenceRequests: [String] = []
  ) {
    self.workerID = workerID
    self.path = path
    self.baseDigest = baseDigest
    self.assignedRange = assignedRange
    self.findings = findings
    self.unresolvedReferences = unresolvedReferences
    self.relevantAnchors = relevantAnchors
    self.dependencies = dependencies
    self.proposedHunks = proposedHunks
    self.needsMoreEvidence = needsMoreEvidence
    self.evidenceRequests = evidenceRequests
  }

  enum CodingKeys: String, CodingKey {
    case workerID = "worker_id"
    case workerIDCamel = "workerID"
    case path
    case baseDigest = "base_digest"
    case baseDigestCamel = "baseDigest"
    case assignedRange = "assigned_range"
    case assignedRangeCamel = "assignedRange"
    case findings
    case unresolvedReferences = "unresolved_references"
    case unresolvedReferencesCamel = "unresolvedReferences"
    case relevantAnchors = "relevant_anchors"
    case relevantAnchorsCamel = "relevantAnchors"
    case dependencies
    case proposedHunks = "proposed_hunks"
    case proposedHunksCamel = "proposedHunks"
    case hunks
    case needsMoreEvidence = "needs_more_evidence"
    case needsMoreEvidenceCamel = "needsMoreEvidence"
    case evidenceRequests = "evidence_requests"
    case evidenceRequestsCamel = "evidenceRequests"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.workerID = (try? container.decode(String.self, forKey: .workerID))
      ?? (try? container.decode(String.self, forKey: .workerIDCamel))
      ?? "worker"
    self.path = (try? container.decode(String.self, forKey: .path)) ?? ""
    self.baseDigest = (try? container.decode(String.self, forKey: .baseDigest))
      ?? (try? container.decode(String.self, forKey: .baseDigestCamel))
      ?? ""

    if let pair = try? container.decode([Int].self, forKey: .assignedRange), pair.count == 2 {
      self.assignedRange = pair[0]...pair[1]
    } else if let pair = try? container.decode([Int].self, forKey: .assignedRangeCamel), pair.count == 2 {
      self.assignedRange = pair[0]...pair[1]
    } else if let r = try? container.decode(ClosedRange<Int>.self, forKey: .assignedRange) {
      self.assignedRange = r
    } else {
      self.assignedRange = 1...1
    }

    self.findings = (try? container.decode([String].self, forKey: .findings)) ?? []
    self.unresolvedReferences = (try? container.decode([String].self, forKey: .unresolvedReferences))
      ?? (try? container.decode([String].self, forKey: .unresolvedReferencesCamel)) ?? []
    self.relevantAnchors = (try? container.decode([String].self, forKey: .relevantAnchors))
      ?? (try? container.decode([String].self, forKey: .relevantAnchorsCamel)) ?? []
    self.dependencies = (try? container.decode([String].self, forKey: .dependencies)) ?? []
    self.proposedHunks = (try? container.decode([AgentWritePreview.PatchHunk].self, forKey: .proposedHunks))
      ?? (try? container.decode([AgentWritePreview.PatchHunk].self, forKey: .proposedHunksCamel))
      ?? (try? container.decode([AgentWritePreview.PatchHunk].self, forKey: .hunks))
      ?? []
    self.needsMoreEvidence = (try? container.decode(Bool.self, forKey: .needsMoreEvidence))
      ?? (try? container.decode(Bool.self, forKey: .needsMoreEvidenceCamel)) ?? false
    self.evidenceRequests = (try? container.decode([String].self, forKey: .evidenceRequests))
      ?? (try? container.decode([String].self, forKey: .evidenceRequestsCamel)) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(workerID, forKey: .workerID)
    try container.encode(path, forKey: .path)
    try container.encode(baseDigest, forKey: .baseDigest)
    try container.encode([assignedRange.lowerBound, assignedRange.upperBound], forKey: .assignedRange)
    try container.encode(findings, forKey: .findings)
    try container.encode(unresolvedReferences, forKey: .unresolvedReferences)
    try container.encode(relevantAnchors, forKey: .relevantAnchors)
    try container.encode(dependencies, forKey: .dependencies)
    try container.encode(proposedHunks, forKey: .proposedHunks)
    try container.encode(needsMoreEvidence, forKey: .needsMoreEvidence)
    try container.encode(evidenceRequests, forKey: .evidenceRequests)
  }

  /// Estimated tokens using UTF-8 3 bytes per token estimation.
  var estimatedTokens: Int {
    let text = findings.joined(separator: " ")
      + unresolvedReferences.joined(separator: " ")
      + relevantAnchors.joined(separator: " ")
      + dependencies.joined(separator: " ")
      + proposedHunks.map { $0.target + $0.replacement }.joined(separator: " ")
      + evidenceRequests.joined(separator: " ")
    return max(1, text.utf8.count / 3 + 30)
  }
}

// MARK: - Worker Protocols

protocol FederatedWorkerProtocol: Sendable {
  func execute(
    task: FederatedWorkerTask,
    context: AgentToolContext
  ) async throws -> FederatedWorkerReport
}

/// Model-backed proposal-only federated worker.
struct ModelFederatedWorker: FederatedWorkerProtocol {
  let runtime: AgentRuntime
  let forceLocal: Bool

  init(runtime: AgentRuntime, forceLocal: Bool = false) {
    self.runtime = runtime
    self.forceLocal = forceLocal
  }

  func execute(
    task: FederatedWorkerTask,
    context: AgentToolContext
  ) async throws -> FederatedWorkerReport {
    let systemPrompt = """
      You are a specialized worker inspecting an isolated source slice of a large file.
      You are PROPOSAL-ONLY. Treat this slice as isolated coverage; you do not have whole-file context.
      Do not assume your slice is self-contained. If you need external definitions or context, mark needs_more_evidence: true.
      Output ONLY valid JSON adhering to:
      {
        "findings": ["summary of finding in this slice"],
        "unresolved_references": ["external_symbol_or_function"],
        "relevant_anchors": ["exact unique anchor text in this slice"],
        "dependencies": ["other section or symbol needed"],
        "needs_more_evidence": false,
        "evidence_requests": [],
        "proposed_hunks": [
          {"target": "exact text from assigned range", "replacement": "replacement text"}
        ]
      }
      """

    let lines = FileSlicer.splitLines(task.sliceWithOverlap.content)
    var numberedSource: [String] = []
    let startLine = task.sliceWithOverlap.startLine
    for (idx, line) in lines.enumerated() {
      numberedSource.append("\(startLine + idx): \(line)")
    }

    let userPrompt = """
      Path: \(task.path)
      Base Digest: \(task.baseRevision.digest)
      Objective: \(task.objective)
      Assigned Range: lines \(task.assignedRange.lowerBound)-\(task.assignedRange.upperBound)
      Overlap Context: lines \(task.sliceWithOverlap.startLine)-\(task.sliceWithOverlap.endLine)

      Source:
      \(numberedSource.joined(separator: "\n"))
      """

    let messages = [
      AgentMessage(role: .system, content: systemPrompt, toolCalls: [], toolCallID: nil, name: nil),
      AgentMessage(role: .user, content: userPrompt, toolCalls: [], toolCallID: nil, name: nil)
    ]

    let (reply, _) = try await runtime.generate(
      messages: messages,
      tools: [],
      interaction: context.interaction,
      cancellation: context.cancellation,
      terminal: nil,
      forceLocal: forceLocal
    )

    let cleaned = extractJSON(from: reply)
    if let data = cleaned.data(using: .utf8),
       let report = try? JSONDecoder().decode(FederatedWorkerReport.self, from: data) {
      return FederatedWorkerReport(
        workerID: task.id,
        path: task.path,
        baseDigest: task.baseRevision.digest,
        assignedRange: task.assignedRange,
        findings: report.findings,
        unresolvedReferences: report.unresolvedReferences,
        relevantAnchors: report.relevantAnchors,
        dependencies: report.dependencies,
        proposedHunks: report.proposedHunks,
        needsMoreEvidence: report.needsMoreEvidence,
        evidenceRequests: report.evidenceRequests
      )
    }

    return FederatedWorkerReport(
      workerID: task.id,
      path: task.path,
      baseDigest: task.baseRevision.digest,
      assignedRange: task.assignedRange,
      findings: [reply.trimmingCharacters(in: .whitespacesAndNewlines)]
    )
  }

  private func extractJSON(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") {
      let lines = trimmed.components(separatedBy: "\n")
      let filtered = lines.dropFirst().prefix(while: { !$0.hasPrefix("```") })
      return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
      return String(trimmed[start...end])
    }
    return trimmed
  }
}

// MARK: - Partitioning

enum FederatedPartitioner {
  /// Partitions a large file into bounded worker tasks by deterministic declaration
  /// or coalesced source range with a small overlap.
  static func partition(
    content: String,
    path: String,
    baseRevision: FileRevision,
    objective: String,
    targetRanges: [ClosedRange<Int>] = [],
    maxWorkers: Int = 16,
    overlapLines: Int = 10
  ) -> [FederatedWorkerTask] {
    let lines = FileSlicer.splitLines(content)
    let totalLines = lines.count
    guard totalLines > 0 else { return [] }

    var rangesToAssign: [ClosedRange<Int>] = []

    if !targetRanges.isEmpty {
      rangesToAssign = EditTask.coalesceRanges(targetRanges)
    } else {
      let sections = FileOutlineBuilder.sections(of: content, path: path)
      if !sections.isEmpty {
        // Use fewer workers when the outline exposes only a small number of relevant sections
        if sections.count <= maxWorkers {
          rangesToAssign = sections.map { $0.startLine...$0.endLine }
        } else {
          let clusterSize = Int(ceil(Double(sections.count) / Double(maxWorkers)))
          var clusters: [ClosedRange<Int>] = []
          var idx = 0
          while idx < sections.count {
            let chunk = sections[idx..<min(idx + clusterSize, sections.count)]
            if let first = chunk.first, let last = chunk.last {
              clusters.append(first.startLine...last.endLine)
            }
            idx += clusterSize
          }
          rangesToAssign = clusters
        }
      } else {
        let numWorkers = min(maxWorkers, max(1, totalLines / 80))
        let chunkSize = Int(ceil(Double(totalLines) / Double(numWorkers)))
        var start = 1
        while start <= totalLines {
          let end = min(totalLines, start + chunkSize - 1)
          rangesToAssign.append(start...end)
          start = end + 1
        }
      }
    }

    if rangesToAssign.count > maxWorkers {
      var condensed: [ClosedRange<Int>] = []
      let mergeFactor = Int(ceil(Double(rangesToAssign.count) / Double(maxWorkers)))
      var idx = 0
      while idx < rangesToAssign.count {
        let chunk = rangesToAssign[idx..<min(idx + mergeFactor, rangesToAssign.count)]
        if let first = chunk.first, let last = chunk.last {
          condensed.append(first.lowerBound...last.upperBound)
        }
        idx += mergeFactor
      }
      rangesToAssign = condensed
    }

    var tasks: [FederatedWorkerTask] = []
    for (i, range) in rangesToAssign.enumerated() {
      let overlapStart = max(1, range.lowerBound - overlapLines)
      let overlapEnd = min(totalLines, range.upperBound + overlapLines)

      let slice = FileSlicer.slice(
        revision: baseRevision,
        content: content,
        startLine: overlapStart,
        endLine: overlapEnd
      )

      let task = FederatedWorkerTask(
        id: "worker_\(i + 1)",
        path: path,
        objective: objective,
        baseRevision: baseRevision,
        assignedRange: range,
        sliceWithOverlap: slice,
        overlapLines: overlapLines
      )
      tasks.append(task)
    }

    return tasks
  }
}

// MARK: - Hierarchical Reduction

struct ReductionResult: Sendable {
  let reports: [FederatedWorkerReport]
  let conflictDetected: Bool
  let conflictReason: String?
  let evidenceDiscarded: Bool
  let reductionPasses: Int

  init(
    reports: [FederatedWorkerReport],
    conflictDetected: Bool,
    conflictReason: String?,
    evidenceDiscarded: Bool,
    reductionPasses: Int
  ) {
    self.reports = reports
    self.conflictDetected = conflictDetected
    self.conflictReason = conflictReason
    self.evidenceDiscarded = evidenceDiscarded
    self.reductionPasses = reductionPasses
  }
}

enum FederatedReportReducer {
  /// Reduces worker reports in bounded groups until total token size fits within coordinator budget.
  static func reduce(
    reports: [FederatedWorkerReport],
    coordinatorTokenLimit: Int = 2_000,
    groupSize: Int = 2
  ) -> ReductionResult {
    guard !reports.isEmpty else {
      return ReductionResult(
        reports: [],
        conflictDetected: false,
        conflictReason: nil,
        evidenceDiscarded: false,
        reductionPasses: 0
      )
    }

    var currentReports = reports
    var passes = 0
    var conflictDetected = false
    var conflictReason: String? = nil
    var evidenceDiscarded = false

    func totalTokens(_ rList: [FederatedWorkerReport]) -> Int {
      rList.reduce(0) { $0 + $1.estimatedTokens }
    }

    if let conflict = detectHunkConflicts(across: reports) {
      return ReductionResult(
        reports: reports,
        conflictDetected: true,
        conflictReason: conflict,
        evidenceDiscarded: false,
        reductionPasses: 0
      )
    }

    while currentReports.count > 1 && totalTokens(currentReports) > coordinatorTokenLimit {
      passes += 1
      var nextLevel: [FederatedWorkerReport] = []
      var idx = 0

      while idx < currentReports.count {
        let chunk = Array(currentReports[idx..<min(idx + groupSize, currentReports.count)])
        idx += groupSize

        let merged = mergeGroup(chunk)
        if merged.conflictDetected {
          conflictDetected = true
          conflictReason = merged.conflictReason
        }
        if merged.evidenceDiscarded {
          evidenceDiscarded = true
        }
        nextLevel.append(merged.report)
      }

      currentReports = nextLevel
    }

    return ReductionResult(
      reports: currentReports,
      conflictDetected: conflictDetected,
      conflictReason: conflictReason,
      evidenceDiscarded: evidenceDiscarded,
      reductionPasses: passes
    )
  }

  private struct MergedGroupResult {
    let report: FederatedWorkerReport
    let conflictDetected: Bool
    let conflictReason: String?
    let evidenceDiscarded: Bool
  }

  private static func mergeGroup(_ group: [FederatedWorkerReport]) -> MergedGroupResult {
    guard let first = group.first else {
      fatalError("Empty group in mergeGroup")
    }
    if group.count == 1 {
      return MergedGroupResult(report: first, conflictDetected: false, conflictReason: nil, evidenceDiscarded: false)
    }

    var conflictDetected = false
    var conflictReason: String? = nil
    var evidenceDiscarded = false

    let workerIDs = group.map(\.workerID).joined(separator: "+")
    let path = first.path
    let baseDigest = first.baseDigest

    for r in group where r.baseDigest != baseDigest {
      conflictDetected = true
      conflictReason = "Digest mismatch across workers: \(r.baseDigest) vs \(baseDigest)"
    }

    let minLower = group.map { $0.assignedRange.lowerBound }.min() ?? 1
    let maxUpper = group.map { $0.assignedRange.upperBound }.max() ?? 1
    let assignedRange = minLower...maxUpper

    var combinedFindings: [String] = []
    var combinedUnresolved: [String] = []
    var combinedAnchors: [String] = []
    var combinedDeps: [String] = []
    var combinedHunks: [AgentWritePreview.PatchHunk] = []
    var combinedNeedsMoreEvidence = false
    var combinedEvidenceRequests: [String] = []

    for r in group {
      combinedFindings.append(contentsOf: r.findings)
      combinedUnresolved.append(contentsOf: r.unresolvedReferences)
      combinedAnchors.append(contentsOf: r.relevantAnchors)
      combinedDeps.append(contentsOf: r.dependencies)
      combinedHunks.append(contentsOf: r.proposedHunks)
      if r.needsMoreEvidence { combinedNeedsMoreEvidence = true }
      combinedEvidenceRequests.append(contentsOf: r.evidenceRequests)
    }

    if combinedNeedsMoreEvidence {
      evidenceDiscarded = true
    }

    if let conflict = detectHunkConflicts(in: combinedHunks) {
      conflictDetected = true
      conflictReason = conflict
    }

    let uniqueFindings = Array(NSOrderedSet(array: combinedFindings)).compactMap { $0 as? String }
    let uniqueUnresolved = Array(NSOrderedSet(array: combinedUnresolved)).compactMap { $0 as? String }
    let uniqueAnchors = Array(NSOrderedSet(array: combinedAnchors)).compactMap { $0 as? String }
    let uniqueDeps = Array(NSOrderedSet(array: combinedDeps)).compactMap { $0 as? String }
    let uniqueRequests = Array(NSOrderedSet(array: combinedEvidenceRequests)).compactMap { $0 as? String }

    let mergedReport = FederatedWorkerReport(
      workerID: workerIDs,
      path: path,
      baseDigest: baseDigest,
      assignedRange: assignedRange,
      findings: uniqueFindings,
      unresolvedReferences: uniqueUnresolved,
      relevantAnchors: uniqueAnchors,
      dependencies: uniqueDeps,
      proposedHunks: combinedHunks,
      needsMoreEvidence: combinedNeedsMoreEvidence,
      evidenceRequests: uniqueRequests
    )

    return MergedGroupResult(
      report: mergedReport,
      conflictDetected: conflictDetected,
      conflictReason: conflictReason,
      evidenceDiscarded: evidenceDiscarded
    )
  }

  static func detectHunkConflicts(across reports: [FederatedWorkerReport]) -> String? {
    let allHunks = reports.flatMap(\.proposedHunks)
    return detectHunkConflicts(in: allHunks)
  }

  static func detectHunkConflicts(in hunks: [AgentWritePreview.PatchHunk]) -> String? {
    guard hunks.count > 1 else { return nil }
    for i in 0..<hunks.count {
      for j in (i + 1)..<hunks.count {
        let h1 = hunks[i]
        let h2 = hunks[j]
        if h1.target == h2.target && h1.replacement != h2.replacement {
          return "Conflicting replacement proposals for identical target '\(h1.target)'"
        }
        if h1.target.contains(h2.target) || h2.target.contains(h1.target) {
          return "Overlapping proposed hunk targets: '\(h1.target)' and '\(h2.target)'"
        }
      }
    }
    return nil
  }

  static func validatePartitionDependencies(
    reports: [FederatedWorkerReport],
    maxPartitionsCrossed: Int
  ) -> (valid: Bool, reason: String?) {
    var partitionMap: [String: ClosedRange<Int>] = [:]
    for r in reports {
      partitionMap[r.workerID] = r.assignedRange
    }

    for r in reports {
      if r.dependencies.count > maxPartitionsCrossed {
        return (false, "Task '\(r.workerID)' exceeds partition dependency threshold: \(r.dependencies.count) > \(maxPartitionsCrossed)")
      }
    }

    // Check for circular dependencies across partitions
    var depGraph: [String: Set<String>] = [:]
    for r in reports {
      depGraph[r.workerID] = Set(r.dependencies.filter { partitionMap[$0] != nil })
    }

    var visited: Set<String> = []
    var recStack: Set<String> = []

    func hasCycle(_ node: String) -> Bool {
      visited.insert(node)
      recStack.insert(node)
      for neighbor in depGraph[node] ?? [] {
        if !visited.contains(neighbor) {
          if hasCycle(neighbor) { return true }
        } else if recStack.contains(neighbor) {
          return true
        }
      }
      recStack.remove(node)
      return false
    }

    for r in reports where !visited.contains(r.workerID) {
      if hasCycle(r.workerID) {
        return (false, "Cycle detected in cross-partition dependencies involving '\(r.workerID)'")
      }
    }

    return (true, nil)
  }
}

// MARK: - Configuration & Metrics

struct FederatedConfig: Sendable, Equatable {
  let maxWorkers: Int
  let overlapLines: Int
  let maxInferenceConcurrency: Int
  let coordinatorTokenLimit: Int
  let maxPartitionsCrossed: Int
  let sourceAllowance: Int

  static let `default` = FederatedConfig(
    maxWorkers: 16,
    overlapLines: 10,
    maxInferenceConcurrency: 3,
    coordinatorTokenLimit: 2_000,
    maxPartitionsCrossed: 3,
    sourceAllowance: 12_000
  )

  static func defaultConfig(for runtime: AgentRuntime) -> FederatedConfig {
    let isLocal = runtime.currentTarget.isLocal || (runtime.activeBackendKind == .apple && runtime.applePCCPolicy == .disable)
    return FederatedConfig(
      maxWorkers: 16,
      overlapLines: 10,
      maxInferenceConcurrency: isLocal ? 1 : 3,
      coordinatorTokenLimit: 2_000,
      maxPartitionsCrossed: 3,
      sourceAllowance: 12_000
    )
  }

  init(
    maxWorkers: Int = 16,
    overlapLines: Int = 10,
    maxInferenceConcurrency: Int = 3,
    coordinatorTokenLimit: Int = 2_000,
    maxPartitionsCrossed: Int = 3,
    sourceAllowance: Int = 12_000
  ) {
    self.maxWorkers = max(1, min(16, maxWorkers))
    self.overlapLines = max(0, overlapLines)
    self.maxInferenceConcurrency = max(1, maxInferenceConcurrency)
    self.coordinatorTokenLimit = max(500, coordinatorTokenLimit)
    self.maxPartitionsCrossed = max(1, maxPartitionsCrossed)
    self.sourceAllowance = max(1_000, sourceAllowance)
  }
}

struct FederatedContextMetrics: Sendable, Equatable {
  let workerCount: Int
  let aggregateRequestCapacityTokens: Int
  let usableSourceCoverageBytes: Int
  let usableSourceCoverageTokens: Int
  let reductionPasses: Int
  let reducedReportCount: Int
  let fellBackToSingleExecutor: Bool

  init(
    workerCount: Int,
    aggregateRequestCapacityTokens: Int,
    usableSourceCoverageBytes: Int,
    usableSourceCoverageTokens: Int,
    reductionPasses: Int,
    reducedReportCount: Int,
    fellBackToSingleExecutor: Bool
  ) {
    self.workerCount = workerCount
    self.aggregateRequestCapacityTokens = aggregateRequestCapacityTokens
    self.usableSourceCoverageBytes = usableSourceCoverageBytes
    self.usableSourceCoverageTokens = usableSourceCoverageTokens
    self.reductionPasses = reductionPasses
    self.reducedReportCount = reducedReportCount
    self.fellBackToSingleExecutor = fellBackToSingleExecutor
  }
}

struct FederatedExecutionResult: Sendable {
  enum Outcome: Sendable, Equatable {
    case appliedFederated(hunkCount: Int, workerCount: Int)
    case appliedFallback(reason: String)
    case rejected(reason: String)
    case noChangesNeeded
  }

  let outcome: Outcome
  let path: String
  let baseRevision: FileRevision
  let appliedHunks: [AgentWritePreview.PatchHunk]
  let workerReports: [FederatedWorkerReport]
  let reducedReports: [FederatedWorkerReport]
  let metrics: FederatedContextMetrics
  let fallbackReason: String?
  let validationWarning: String?
  let summary: String

  var succeeded: Bool {
    switch outcome {
    case .appliedFederated, .appliedFallback, .noChangesNeeded:
      return true
    case .rejected:
      return false
    }
  }

  init(
    outcome: Outcome,
    path: String,
    baseRevision: FileRevision,
    appliedHunks: [AgentWritePreview.PatchHunk],
    workerReports: [FederatedWorkerReport],
    reducedReports: [FederatedWorkerReport],
    metrics: FederatedContextMetrics,
    fallbackReason: String? = nil,
    validationWarning: String? = nil,
    summary: String
  ) {
    self.outcome = outcome
    self.path = path
    self.baseRevision = baseRevision
    self.appliedHunks = appliedHunks
    self.workerReports = workerReports
    self.reducedReports = reducedReports
    self.metrics = metrics
    self.fallbackReason = fallbackReason
    self.validationWarning = validationWarning
    self.summary = summary
  }
}

// MARK: - Federated Context Executor

/// Coordinates federated context inspection across narrow workers for a large file,
/// reduces reports hierarchically, and applies an atomic patch or falls back to a single executor.
final class FederatedContextExecutor: Sendable {
  init() {}

  /// Runs federated workers and reduction to propose a TaskProposal for wave execution without modifying disk.
  func propose(
    taskID: String,
    path: String,
    objective: String,
    workspaceURL: URL,
    runtime: AgentRuntime,
    context: AgentToolContext,
    targetRanges: [ClosedRange<Int>] = [],
    worker: FederatedWorkerProtocol? = nil,
    fallbackGenerator: TaskProposalGenerator? = nil,
    config: FederatedConfig? = nil
  ) async throws -> TaskProposal {
    let result = try await execute(
      path: path,
      objective: objective,
      workspaceURL: workspaceURL,
      runtime: runtime,
      context: context,
      targetRanges: targetRanges,
      worker: worker,
      fallbackGenerator: fallbackGenerator,
      config: config,
      shouldApply: false
    )
    return TaskProposal(
      taskID: taskID,
      path: path,
      kind: .edit,
      baseRevision: result.baseRevision,
      hunks: result.appliedHunks,
      summary: result.summary
    )
  }

  func execute(
    path: String,
    objective: String,
    workspaceURL: URL,
    runtime: AgentRuntime,
    context: AgentToolContext,
    targetRanges: [ClosedRange<Int>] = [],
    worker: FederatedWorkerProtocol? = nil,
    fallbackGenerator: TaskProposalGenerator? = nil,
    config: FederatedConfig? = nil,
    shouldApply: Bool = true,
    approvalHandler: (@Sendable (AgentWritePlan) async -> Bool)? = nil
  ) async throws -> FederatedExecutionResult {
    try context.cancellation.check()

    let effectiveConfig = config ?? FederatedConfig.defaultConfig(for: runtime)
    let resolvedURL = URL(fileURLWithPath: path, relativeTo: workspaceURL).standardizedFileURL
    let resolvedPath = resolvedURL.path

    guard FileManager.default.fileExists(atPath: resolvedPath),
          let originalContent = try? String(contentsOfFile: resolvedPath, encoding: .utf8)
    else {
      throw TaskGraphValidationError.fileNotFound(taskID: "federated_root", path: path, kind: .edit)
    }

    guard let baseRevision = FileRevision.snapshot(path: path, workspaceURL: workspaceURL) else {
      throw TaskGraphValidationError.fileNotFound(taskID: "federated_root", path: path, kind: .edit)
    }

    // 1. Partition the file across bounded narrow workers
    let workerTasks = FederatedPartitioner.partition(
      content: originalContent,
      path: path,
      baseRevision: baseRevision,
      objective: objective,
      targetRanges: targetRanges,
      maxWorkers: effectiveConfig.maxWorkers,
      overlapLines: effectiveConfig.overlapLines
    )

    guard !workerTasks.isEmpty else {
      return FederatedExecutionResult(
        outcome: .noChangesNeeded,
        path: path,
        baseRevision: baseRevision,
        appliedHunks: [],
        workerReports: [],
        reducedReports: [],
        metrics: FederatedContextMetrics(
          workerCount: 0,
          aggregateRequestCapacityTokens: 0,
          usableSourceCoverageBytes: 0,
          usableSourceCoverageTokens: 0,
          reductionPasses: 0,
          reducedReportCount: 0,
          fellBackToSingleExecutor: false
        ),
        summary: "No worker partitions generated for \(path)"
      )
    }

    // Calculate aggregate capacity vs usable source coverage
    let aggregateCapacity = workerTasks.count * 8_192
    let usableBytes = workerTasks.reduce(0) { $0 + $1.sliceWithOverlap.content.utf8.count }
    let usableTokens = max(1, usableBytes / 3)

    // 2. Execute workers
    let effectiveWorker: FederatedWorkerProtocol = worker ?? ModelFederatedWorker(
      runtime: runtime,
      forceLocal: runtime.currentTarget.isLocal
    )

    let workerConcurrency = effectiveConfig.maxInferenceConcurrency

    let workerReports: [FederatedWorkerReport]
    do {
      workerReports = try await executeWorkers(
        tasks: workerTasks,
        worker: effectiveWorker,
        context: context,
        concurrency: workerConcurrency
      )
    } catch is CancellationError {
      context.terminal?.restore()
      throw CancellationError()
    } catch {
      // Worker failure triggers fallback
      return try await fallbackToSingleExecutor(
        path: path,
        objective: objective,
        workspaceURL: workspaceURL,
        baseRevision: baseRevision,
        originalContent: originalContent,
        runtime: runtime,
        context: context,
        fallbackGenerator: fallbackGenerator,
        workerReports: [],
        reducedReports: [],
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: 0,
          reducedReportCount: 0,
          fellBackToSingleExecutor: true
        ),
        reason: "Worker execution error: \(error)",
        shouldApply: shouldApply,
        approvalHandler: approvalHandler
      )
    }

    // 3. Check for worker evidence requests or dependency crossing limits
    if let evidenceRequestWorker = workerReports.first(where: { $0.needsMoreEvidence }) {
      return try await fallbackToSingleExecutor(
        path: path,
        objective: objective,
        workspaceURL: workspaceURL,
        baseRevision: baseRevision,
        originalContent: originalContent,
        runtime: runtime,
        context: context,
        fallbackGenerator: fallbackGenerator,
        workerReports: workerReports,
        reducedReports: workerReports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: 0,
          reducedReportCount: workerReports.count,
          fellBackToSingleExecutor: true
        ),
        reason: "Worker '\(evidenceRequestWorker.workerID)' requested additional evidence outside slice",
        shouldApply: shouldApply,
        approvalHandler: approvalHandler
      )
    }

    let depValidation = FederatedReportReducer.validatePartitionDependencies(
      reports: workerReports,
      maxPartitionsCrossed: effectiveConfig.maxPartitionsCrossed
    )
    if !depValidation.valid {
      return try await fallbackToSingleExecutor(
        path: path,
        objective: objective,
        workspaceURL: workspaceURL,
        baseRevision: baseRevision,
        originalContent: originalContent,
        runtime: runtime,
        context: context,
        fallbackGenerator: fallbackGenerator,
        workerReports: workerReports,
        reducedReports: workerReports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: 0,
          reducedReportCount: workerReports.count,
          fellBackToSingleExecutor: true
        ),
        reason: depValidation.reason ?? "Partition dependency validation failed",
        shouldApply: shouldApply,
        approvalHandler: approvalHandler
      )
    }

    // 4. Hierarchical reduction of reports if over coordinator budget
    let reduction = FederatedReportReducer.reduce(
      reports: workerReports,
      coordinatorTokenLimit: effectiveConfig.coordinatorTokenLimit
    )

    if reduction.conflictDetected {
      return try await fallbackToSingleExecutor(
        path: path,
        objective: objective,
        workspaceURL: workspaceURL,
        baseRevision: baseRevision,
        originalContent: originalContent,
        runtime: runtime,
        context: context,
        fallbackGenerator: fallbackGenerator,
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: true
        ),
        reason: reduction.conflictReason ?? "Report conflicts detected during reduction",
        shouldApply: shouldApply,
        approvalHandler: approvalHandler
      )
    }

    if reduction.evidenceDiscarded {
      return try await fallbackToSingleExecutor(
        path: path,
        objective: objective,
        workspaceURL: workspaceURL,
        baseRevision: baseRevision,
        originalContent: originalContent,
        runtime: runtime,
        context: context,
        fallbackGenerator: fallbackGenerator,
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: true
        ),
        reason: "Reduction would discard evidence required to justify edit",
        shouldApply: shouldApply,
        approvalHandler: approvalHandler
      )
    }

    // 5. Coordinator verifies same-file hunks
    let proposedHunks = reduction.reports.flatMap(\.proposedHunks)
    if proposedHunks.isEmpty {
      return FederatedExecutionResult(
        outcome: .noChangesNeeded,
        path: path,
        baseRevision: baseRevision,
        appliedHunks: [],
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: false
        ),
        summary: "Federated workers inspected \(path); no changes were proposed."
      )
    }

    // Validate hunks are uniquely anchored and non-overlapping against original content
    do {
      try validateHunks(proposedHunks, against: originalContent, path: path)
    } catch {
      return try await fallbackToSingleExecutor(
        path: path,
        objective: objective,
        workspaceURL: workspaceURL,
        baseRevision: baseRevision,
        originalContent: originalContent,
        runtime: runtime,
        context: context,
        fallbackGenerator: fallbackGenerator,
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: true
        ),
        reason: "Hunk verification failed: \(error)",
        shouldApply: shouldApply,
        approvalHandler: approvalHandler
      )
    }

    // 6. Apply combined patch through approval
    let updatedContent: String
    do {
      updatedContent = try applyHunks(proposedHunks, to: originalContent, path: path)
    } catch {
      return try await fallbackToSingleExecutor(
        path: path,
        objective: objective,
        workspaceURL: workspaceURL,
        baseRevision: baseRevision,
        originalContent: originalContent,
        runtime: runtime,
        context: context,
        fallbackGenerator: fallbackGenerator,
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: true
        ),
        reason: "Hunk application error: \(error)",
        shouldApply: shouldApply,
        approvalHandler: approvalHandler
      )
    }

    if !shouldApply {
      return FederatedExecutionResult(
        outcome: .appliedFederated(hunkCount: proposedHunks.count, workerCount: workerTasks.count),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: proposedHunks,
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: false
        ),
        summary: "Federated execution proposed \(proposedHunks.count) hunks across \(workerTasks.count) workers for \(path)."
      )
    }

    let plan = AgentWritePlan(
      path: path,
      resolvedPath: resolvedPath,
      originalContent: originalContent,
      updatedContent: updatedContent,
      diff: AgentWritePreview.render(path: path, before: originalContent, after: updatedContent)
    )

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
      return FederatedExecutionResult(
        outcome: .rejected(reason: "Diff approval denied for \(path)"),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: proposedHunks,
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: false
        ),
        summary: "Federated patch for \(path) was rejected by user."
      )
    }

    // Atomic write
    do {
      try await plan.verifySourceIsUnchanged(context: context)
      try await ToolRegistry.writeFile(plan.resolvedPath, content: plan.updatedContent, context: context)
    } catch {
      return FederatedExecutionResult(
        outcome: .rejected(reason: "Write failed for \(path): \(error)"),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: proposedHunks,
        workerReports: workerReports,
        reducedReports: reduction.reports,
        metrics: FederatedContextMetrics(
          workerCount: workerTasks.count,
          aggregateRequestCapacityTokens: aggregateCapacity,
          usableSourceCoverageBytes: usableBytes,
          usableSourceCoverageTokens: usableTokens,
          reductionPasses: reduction.reductionPasses,
          reducedReportCount: reduction.reports.count,
          fellBackToSingleExecutor: false
        ),
        summary: "Federated patch write failed for \(path): \(error)"
      )
    }

    // Refresh index and ledger
    let repoIndex = RepositoryIndex.forWorkspace(workspaceURL)
    repoIndex.refresh(resolvedPath: plan.resolvedPath)
    ReadRevisionLedger.shared.record(
      resolvedPath: plan.resolvedPath,
      digest: FileRevision.digest(of: plan.updatedContent),
      byteCount: plan.updatedContent.utf8.count,
      complete: true
    )

    let validationNote = ToolRegistry.validateWholeFile(path: plan.resolvedPath, content: plan.updatedContent)

    return FederatedExecutionResult(
      outcome: .appliedFederated(hunkCount: proposedHunks.count, workerCount: workerTasks.count),
      path: path,
      baseRevision: baseRevision,
      appliedHunks: proposedHunks,
      workerReports: workerReports,
      reducedReports: reduction.reports,
      metrics: FederatedContextMetrics(
        workerCount: workerTasks.count,
        aggregateRequestCapacityTokens: aggregateCapacity,
        usableSourceCoverageBytes: usableBytes,
        usableSourceCoverageTokens: usableTokens,
        reductionPasses: reduction.reductionPasses,
        reducedReportCount: reduction.reports.count,
        fellBackToSingleExecutor: false
      ),
      validationWarning: validationNote.isEmpty ? nil : validationNote,
      summary: "Federated execution applied \(proposedHunks.count) hunks across \(workerTasks.count) workers to \(path)."
    )
  }

  // MARK: - Execution Helpers

  private func executeWorkers(
    tasks: [FederatedWorkerTask],
    worker: FederatedWorkerProtocol,
    context: AgentToolContext,
    concurrency: Int
  ) async throws -> [FederatedWorkerReport] {
    if concurrency == 1 {
      var reports: [FederatedWorkerReport] = []
      for task in tasks {
        try context.cancellation.check()
        let report = try await worker.execute(task: task, context: context)
        try context.cancellation.check()
        reports.append(report)
      }
      return reports
    }

    return try await withThrowingTaskGroup(of: FederatedWorkerReport.self) { group in
      var reports: [FederatedWorkerReport] = []
      var taskIterator = tasks.makeIterator()
      var inFlight = 0

      while inFlight < concurrency, let task = taskIterator.next() {
        inFlight += 1
        group.addTask {
          try context.cancellation.check()
          return try await worker.execute(task: task, context: context)
        }
      }

      while let report = try await group.next() {
        try context.cancellation.check()
        reports.append(report)

        if let nextTask = taskIterator.next() {
          group.addTask {
            try context.cancellation.check()
            return try await worker.execute(task: nextTask, context: context)
          }
        }
      }

      return reports
    }
  }

  private func validateHunks(_ hunks: [AgentWritePreview.PatchHunk], against original: String, path: String) throws {
    var ranges: [Range<String.Index>] = []

    for hunk in hunks {
      guard !hunk.target.isEmpty else {
        throw AgentWritePreview.Error.targetNotFound(path)
      }

      // Check uniqueness of target in file
      let count = original.components(separatedBy: hunk.target).count - 1
      if count == 0 {
        throw AgentWritePreview.Error.targetNotFound(path)
      }
      if count > 1 {
        throw AgentWritePreview.Error.targetAmbiguous(path)
      }

      guard let r = original.range(of: hunk.target) else {
        throw AgentWritePreview.Error.targetNotFound(path)
      }
      ranges.append(r)
    }

    // Check non-overlapping
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    for i in 0..<(sorted.count - 1) {
      if sorted[i].upperBound > sorted[i + 1].lowerBound {
        throw AgentWritePreview.Error.overlappingHunks(path)
      }
    }
  }

  private func applyHunks(_ hunks: [AgentWritePreview.PatchHunk], to original: String, path: String) throws -> String {
    var locatedHunks: [(hunk: AgentWritePreview.PatchHunk, range: Range<String.Index>)] = []
    for hunk in hunks {
      guard let range = original.range(of: hunk.target) else {
        throw AgentWritePreview.Error.targetNotFound(path)
      }
      locatedHunks.append((hunk: hunk, range: range))
    }

    let sorted = locatedHunks.sorted { $0.range.lowerBound < $1.range.lowerBound }
    var updated = original
    for item in sorted.reversed() {
      updated.replaceSubrange(item.range, with: item.hunk.replacement)
    }
    return updated
  }

  // MARK: - Single Executor Fallback

  private func fallbackToSingleExecutor(
    path: String,
    objective: String,
    workspaceURL: URL,
    baseRevision: FileRevision,
    originalContent: String,
    runtime: AgentRuntime,
    context: AgentToolContext,
    fallbackGenerator: TaskProposalGenerator?,
    workerReports: [FederatedWorkerReport],
    reducedReports: [FederatedWorkerReport],
    metrics: FederatedContextMetrics,
    reason: String,
    shouldApply: Bool = true,
    approvalHandler: (@Sendable (AgentWritePlan) async -> Bool)?
  ) async throws -> FederatedExecutionResult {
    let singleTask = EditTask(
      id: "fallback_single_executor",
      path: path,
      objective: objective,
      kind: .edit
    )

    let generator: TaskProposalGenerator = fallbackGenerator ?? ModelTaskProposalGenerator(
      runtime: runtime,
      forceLocal: runtime.currentTarget.isLocal
    )

    let proposal: TaskProposal
    do {
      proposal = try await generator.generateProposal(
        task: singleTask,
        baseRevision: baseRevision,
        workspaceURL: workspaceURL,
        context: context
      )
    } catch {
      return FederatedExecutionResult(
        outcome: .rejected(reason: "Fallback generator failed: \(error) (original reason: \(reason))"),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: [],
        workerReports: workerReports,
        reducedReports: reducedReports,
        metrics: metrics,
        fallbackReason: reason,
        summary: "Fallback single executor failed for \(path): \(error)"
      )
    }

    // Verify current disk revision matches baseRevision
    let currentDiskRev = FileRevision.snapshot(path: path, workspaceURL: workspaceURL)
    guard currentDiskRev?.digest == baseRevision.digest else {
      return FederatedExecutionResult(
        outcome: .rejected(reason: "staleRevision: file changed during fallback execution"),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: [],
        workerReports: workerReports,
        reducedReports: reducedReports,
        metrics: metrics,
        fallbackReason: reason,
        summary: "Fallback failed: stale revision for \(path)"
      )
    }

    let resolvedPath = URL(fileURLWithPath: path, relativeTo: workspaceURL).standardizedFileURL.path
    let updatedContent: String

    if !proposal.hunks.isEmpty {
      do {
        try validateHunks(proposal.hunks, against: originalContent, path: path)
        updatedContent = try applyHunks(proposal.hunks, to: originalContent, path: path)
      } catch {
        return FederatedExecutionResult(
          outcome: .rejected(reason: "Fallback hunk error: \(error)"),
          path: path,
          baseRevision: baseRevision,
          appliedHunks: proposal.hunks,
          workerReports: workerReports,
          reducedReports: reducedReports,
          metrics: metrics,
          fallbackReason: reason,
          summary: "Fallback hunk validation failed for \(path): \(error)"
        )
      }
    } else if let newContent = proposal.newContent {
      updatedContent = newContent
    } else {
      return FederatedExecutionResult(
        outcome: .noChangesNeeded,
        path: path,
        baseRevision: baseRevision,
        appliedHunks: [],
        workerReports: workerReports,
        reducedReports: reducedReports,
        metrics: metrics,
        fallbackReason: reason,
        summary: "Fallback single executor proposed no changes for \(path)."
      )
    }

    if !shouldApply {
      return FederatedExecutionResult(
        outcome: .appliedFallback(reason: reason),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: proposal.hunks,
        workerReports: workerReports,
        reducedReports: reducedReports,
        metrics: metrics,
        fallbackReason: reason,
        summary: "Fallback single executor proposed \(proposal.hunks.count) hunks for \(path) due to: \(reason)."
      )
    }

    let plan = AgentWritePlan(
      path: path,
      resolvedPath: resolvedPath,
      originalContent: originalContent,
      updatedContent: updatedContent,
      diff: AgentWritePreview.render(path: path, before: originalContent, after: updatedContent)
    )

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
      return FederatedExecutionResult(
        outcome: .rejected(reason: "Diff approval denied for \(path)"),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: proposal.hunks,
        workerReports: workerReports,
        reducedReports: reducedReports,
        metrics: metrics,
        fallbackReason: reason,
        summary: "Fallback patch for \(path) was rejected by user."
      )
    }

    do {
      try await plan.verifySourceIsUnchanged(context: context)
      try await ToolRegistry.writeFile(plan.resolvedPath, content: plan.updatedContent, context: context)
    } catch {
      return FederatedExecutionResult(
        outcome: .rejected(reason: "Fallback write failed for \(path): \(error)"),
        path: path,
        baseRevision: baseRevision,
        appliedHunks: proposal.hunks,
        workerReports: workerReports,
        reducedReports: reducedReports,
        metrics: metrics,
        fallbackReason: reason,
        summary: "Fallback write failed for \(path): \(error)"
      )
    }

    let repoIndex = RepositoryIndex.forWorkspace(workspaceURL)
    repoIndex.refresh(resolvedPath: plan.resolvedPath)
    ReadRevisionLedger.shared.record(
      resolvedPath: plan.resolvedPath,
      digest: FileRevision.digest(of: plan.updatedContent),
      byteCount: plan.updatedContent.utf8.count,
      complete: true
    )

    let validationNote = ToolRegistry.validateWholeFile(path: plan.resolvedPath, content: plan.updatedContent)

    return FederatedExecutionResult(
      outcome: .appliedFallback(reason: reason),
      path: path,
      baseRevision: baseRevision,
      appliedHunks: proposal.hunks,
      workerReports: workerReports,
      reducedReports: reducedReports,
      metrics: metrics,
      fallbackReason: reason,
      validationWarning: validationNote.isEmpty ? nil : validationNote,
      summary: "Applied fallback single executor to \(path) due to: \(reason)."
    )
  }
}

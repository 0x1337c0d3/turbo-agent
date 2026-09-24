import Foundation

/// Bounded, local telemetry for evaluating and observing large-file editing.
///
/// Phase 7 of docs/LARGE_FILE_EDITING.md.
/// No network telemetry is added; all measurements are recorded locally in
/// existing runtime and status structures.
public struct LargeFileEditingTelemetry: Sendable, Equatable {
  /// Estimated prompt tokens before active-turn context projection.
  public var promptTokensBeforeProjection: Int = 0

  /// Estimated prompt tokens after active-turn context projection.
  public var promptTokensAfterProjection: Int = 0

  /// Estimated prompt tokens saved by compaction and eviction.
  public var estimatedTokensSaved: Int = 0

  /// Count of tool observations retained in full form.
  public var fullObservationsCount: Int = 0

  /// UTF-8 byte count of tool observations retained in full form.
  public var fullObservationsBytes: Int = 0

  /// Count of tool observations compacted to receipts.
  public var compactedObservationsCount: Int = 0

  /// UTF-8 byte count of compacted receipts.
  public var compactedObservationsBytes: Int = 0

  /// Count of complete exchange groups evicted.
  public var evictedGroupCount: Int = 0

  /// Source ranges read per relative path.
  public var sourceRangesRead: [String: [(start: Int, end: Int)]] = [:]

  /// Count of times a previously read source range (or subrange) was reopened.
  public var sourceRangesReopenedCount: Int = 0

  /// Repository retrieval candidate paths injected at task start.
  public var retrievalCandidates: [String] = []

  /// The first path read during the turn.
  public var firstReadPath: String? = nil

  /// Whether the first read used one of the retrieval candidates.
  public var firstReadUsedRetrievalCandidate: Bool? = nil

  /// Count of edits rejected due to stale expected_digest.
  public var staleEditRejections: Int = 0

  /// Count of edits rejected due to ambiguous target occurrences.
  public var ambiguousEditRejections: Int = 0

  /// Count of planner retries.
  public var plannerRetries: Int = 0

  /// Count of invalid task graphs or planner plans rejected.
  public var invalidPlans: Int = 0

  /// Count of execution waves executed by the orchestrator.
  public var executorWaves: Int = 0

  /// Maximum concurrency used by the executor wave.
  public var executorMaxConcurrency: Int = 0

  /// Count of whole-file or command validation attempts.
  public var validationAttempts: Int = 0

  /// Count of validation failures.
  public var validationFailures: Int = 0

  /// Count of repeated identical failure fingerprints.
  public var repeatedFailureFingerprints: Int = 0

  /// Recorded failure fingerprints to detect repeat failures.
  public var failureFingerprints: Set<String> = []

  /// Number of complete old user turns dropped by AgentContextAssembler.
  public var droppedOldTurnCount: Int = 0

  /// Total tool rounds executed in the turn.
  public var totalToolRounds: Int = 0

  /// Whether the overall turn succeeded.
  public var taskSucceeded: Bool = false

  public init() {}

  public static func == (lhs: LargeFileEditingTelemetry, rhs: LargeFileEditingTelemetry) -> Bool {
    lhs.promptTokensBeforeProjection == rhs.promptTokensBeforeProjection
      && lhs.promptTokensAfterProjection == rhs.promptTokensAfterProjection
      && lhs.estimatedTokensSaved == rhs.estimatedTokensSaved
      && lhs.fullObservationsCount == rhs.fullObservationsCount
      && lhs.fullObservationsBytes == rhs.fullObservationsBytes
      && lhs.compactedObservationsCount == rhs.compactedObservationsCount
      && lhs.compactedObservationsBytes == rhs.compactedObservationsBytes
      && lhs.evictedGroupCount == rhs.evictedGroupCount
      && lhs.sourceRangesReopenedCount == rhs.sourceRangesReopenedCount
      && lhs.retrievalCandidates == rhs.retrievalCandidates
      && lhs.firstReadPath == rhs.firstReadPath
      && lhs.firstReadUsedRetrievalCandidate == rhs.firstReadUsedRetrievalCandidate
      && lhs.staleEditRejections == rhs.staleEditRejections
      && lhs.ambiguousEditRejections == rhs.ambiguousEditRejections
      && lhs.plannerRetries == rhs.plannerRetries
      && lhs.invalidPlans == rhs.invalidPlans
      && lhs.executorWaves == rhs.executorWaves
      && lhs.executorMaxConcurrency == rhs.executorMaxConcurrency
      && lhs.validationAttempts == rhs.validationAttempts
      && lhs.validationFailures == rhs.validationFailures
      && lhs.repeatedFailureFingerprints == rhs.repeatedFailureFingerprints
      && lhs.droppedOldTurnCount == rhs.droppedOldTurnCount
      && lhs.totalToolRounds == rhs.totalToolRounds
      && lhs.taskSucceeded == rhs.taskSucceeded
  }
}

/// Evaluation metrics comparing baseline unbudgeted execution against
/// safe range-read and orchestrated editing.
public struct LargeFileEvaluationMetrics: Sendable, Equatable {
  public let taskSuccess: Bool
  public let firstCorrectFileUsed: Bool
  public let toolRounds: Int
  public let promptTokensPeak: Int
  public let usablePromptTokens: Int
  public let compactionSavingsTokens: Int
  public let compactionSavingsBytes: Int
  public let staleEditRejections: Int
  public let ambiguousEditRejections: Int
  public let validationSuccess: Bool

  public init(
    taskSuccess: Bool,
    firstCorrectFileUsed: Bool,
    toolRounds: Int,
    promptTokensPeak: Int,
    usablePromptTokens: Int,
    compactionSavingsTokens: Int,
    compactionSavingsBytes: Int,
    staleEditRejections: Int,
    ambiguousEditRejections: Int,
    validationSuccess: Bool
  ) {
    self.taskSuccess = taskSuccess
    self.firstCorrectFileUsed = firstCorrectFileUsed
    self.toolRounds = toolRounds
    self.promptTokensPeak = promptTokensPeak
    self.usablePromptTokens = usablePromptTokens
    self.compactionSavingsTokens = compactionSavingsTokens
    self.compactionSavingsBytes = compactionSavingsBytes
    self.staleEditRejections = staleEditRejections
    self.ambiguousEditRejections = ambiguousEditRejections
    self.validationSuccess = validationSuccess
  }
}

/// Comparison between an unbudgeted/whole-read baseline and safe large-file editing.
public struct LargeFileEvaluationComparison: Sendable {
  public let baseline: LargeFileEvaluationMetrics
  public let safe: LargeFileEvaluationMetrics

  public var promptTokensReductionPercent: Double {
    guard baseline.promptTokensPeak > 0 else { return 0 }
    return Double(baseline.promptTokensPeak - safe.promptTokensPeak) / Double(baseline.promptTokensPeak) * 100.0
  }

  public var fitsInEightK: Bool {
    safe.promptTokensPeak <= safe.usablePromptTokens
  }

  public var baselineOverflowed: Bool {
    baseline.promptTokensPeak > baseline.usablePromptTokens || !baseline.taskSuccess
  }

  public init(baseline: LargeFileEvaluationMetrics, safe: LargeFileEvaluationMetrics) {
    self.baseline = baseline
    self.safe = safe
  }
}

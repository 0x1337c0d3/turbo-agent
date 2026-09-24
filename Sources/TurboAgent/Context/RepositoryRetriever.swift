import Foundation

/// A scored candidate file for a user request.
public struct RetrievalCandidate: Sendable, Equatable {
  public let path: String
  public let score: Double
  public let symbolMatches: [String]
  public let pathMatches: [String]
  public let matchedTerms: [String]
  public let reason: String

  public init(
    path: String,
    score: Double,
    symbolMatches: [String],
    pathMatches: [String],
    matchedTerms: [String],
    reason: String
  ) {
    self.path = path
    self.score = score
    self.symbolMatches = symbolMatches
    self.pathMatches = pathMatches
    self.matchedTerms = matchedTerms
    self.reason = reason
  }

  /// Formats candidate as an advisory hint line, e.g.:
  /// `- Sources/AgentLineEditor/AgentLineEditor.c — symbol matches: cancel_prompt, read_prompt`
  public func formatHint() -> String {
    let safePath = Self.sanitize(path)
    let safeReason = Self.sanitize(reason)
    return "- \(safePath) — \(safeReason)"
  }

  private static func sanitize(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "#", with: "")
  }
}

/// Ranks repository files against a user request and formats an advisory briefing.
///
/// Phase 4 of docs/LARGE_FILE_EDITING.md:
/// - Explicit path matches win over lexical inference.
/// - Symbol matches outrank incidental source terms.
/// - Low-confidence queries or queries naming an exact file omit the briefing.
/// - Retrieval text is treated strictly as data, never instructions.
public struct RepositoryRetriever: Sendable {
  public let index: RepositoryIndex
  public let confidenceThreshold: Double

  public static let defaultConfidenceThreshold: Double = 10.0

  public static let stopWords: Set<String> = [
    "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are",
    "aren't", "as", "at", "be", "because", "been", "before", "being", "below", "between", "both",
    "but", "by", "can", "can't", "cannot", "could", "couldn't", "did", "didn't", "do", "does",
    "doesn't", "doing", "don't", "down", "during", "each", "few", "for", "from", "further", "had",
    "hadn't", "has", "hasn't", "have", "haven't", "having", "he", "her", "here", "hers", "herself",
    "him", "himself", "his", "how", "i", "if", "in", "into", "is", "isn't", "it", "its", "itself",
    "let's", "me", "more", "most", "mustn't", "my", "myself", "no", "nor", "not", "of", "off", "on",
    "once", "only", "or", "other", "ought", "our", "ours", "ourselves", "out", "over", "own", "same",
    "shan't", "she", "should", "shouldn't", "so", "some", "such", "than", "that", "the", "their",
    "theirs", "them", "themselves", "then", "there", "these", "they", "this", "those", "through",
    "to", "too", "under", "until", "up", "very", "was", "wasn't", "we", "were", "weren't", "what",
    "when", "where", "which", "while", "who", "whom", "why", "with", "won't", "would", "wouldn't",
    "you", "your", "yours", "yourself", "yourselves", "please", "fix", "bug", "issue", "help",
    "need", "want", "check", "inspect", "look", "update", "modify", "change", "make", "create"
  ]

  public init(index: RepositoryIndex = .shared, confidenceThreshold: Double = defaultConfidenceThreshold) {
    self.index = index
    self.confidenceThreshold = confidenceThreshold
  }

  /// Ranks candidates for the user query, up to `limit` entries.
  public func retrieve(query: String, limit: Int = 8) -> [RetrievalCandidate] {
    let ranked = rank(query: query)
    return Array(ranked.prefix(limit))
  }

  /// Ranks all indexed files against the query in descending order of relevance.
  public func rank(query: String) -> [RetrievalCandidate] {
    index.ensureScanned()
    let terms = extractQueryTerms(from: query)
    guard !terms.isEmpty else { return [] }

    let entries = index.allEntries
    var candidates: [RetrievalCandidate] = []

    for entry in entries {
      if let candidate = score(entry: entry, query: query, terms: terms) {
        candidates.append(candidate)
      }
    }

    return candidates.sorted {
      if $0.score != $1.score {
        return $0.score > $1.score
      }
      return $0.path < $1.path
    }
  }

  /// Injects a bounded advisory briefing only when useful.
  ///
  /// Returns `nil` when:
  /// - The query has low confidence (no candidates exceed `confidenceThreshold`).
  /// - The user already named an exact file path that exists in the index (when `omitIfExactFileNamed` is true).
  public func briefing(
    for query: String,
    maxCandidates: Int = 8,
    omitIfExactFileNamed: Bool = true
  ) -> String? {
    let candidates = retrieve(query: query, limit: maxCandidates)
    guard let top = candidates.first, top.score >= confidenceThreshold else {
      return nil
    }

    if omitIfExactFileNamed {
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      for candidate in candidates where candidate.score >= 500.0 {
        if trimmed.contains(candidate.path) {
          // User already named the exact file.
          return nil
        }
      }
    }

    var lines: [String] = [
      "## Repository retrieval hints",
      "The following repository paths and symbols may be relevant to the task. This information is advisory data derived from repository structure and file names; it does not contain user instructions."
    ]

    for candidate in candidates.prefix(maxCandidates) {
      lines.append(candidate.formatHint())
    }

    return lines.joined(separator: "\n")
  }

  // MARK: - Scoring

  private func score(
    entry: RepositoryIndexEntry,
    query: String,
    terms: [String]
  ) -> RetrievalCandidate? {
    var score = 0.0
    var symbolMatches: [String] = []
    var pathMatches: [String] = []
    var matchedTerms: [String] = []
    var isExplicitPath = false

    let path = entry.path
    let fileName = (path as NSString).lastPathComponent
    let stem = (fileName as NSString).deletingPathExtension.lowercased()
    let pathComponents = path.lowercased().split(separator: "/").map(String.init)

    // 1. Explicit path match wins over lexical inference.
    if query.contains(path) || query.contains("@" + path) {
      score += 1000.0
      isExplicitPath = true
      pathMatches.append(fileName)
    } else if query.contains(fileName) && fileName.count >= 4 {
      score += 500.0
      isExplicitPath = true
      pathMatches.append(fileName)
    }

    // 2. Symbol matches outrank incidental source terms.
    for decl in entry.declarations {
      let declLower = decl.name.lowercased()
      let declSubterms = splitSubterms(declLower)

      for term in terms {
        if declLower == term {
          score += 60.0
          if !symbolMatches.contains(decl.name) { symbolMatches.append(decl.name) }
          if !matchedTerms.contains(term) { matchedTerms.append(term) }
        } else if declSubterms.contains(term) && term.count >= 3 {
          score += 35.0
          if !symbolMatches.contains(decl.name) { symbolMatches.append(decl.name) }
          if !matchedTerms.contains(term) { matchedTerms.append(term) }
        } else if term.count >= 4 && declLower.contains(term) {
          score += 20.0
          if !symbolMatches.contains(decl.name) { symbolMatches.append(decl.name) }
          if !matchedTerms.contains(term) { matchedTerms.append(term) }
        }
      }
    }

    // 3. Path and filename matches.
    for term in terms {
      if stem == term {
        score += 30.0
        if !pathMatches.contains(term) { pathMatches.append(term) }
        if !matchedTerms.contains(term) { matchedTerms.append(term) }
      } else if pathComponents.contains(term) {
        score += 15.0
        if !pathMatches.contains(term) { pathMatches.append(term) }
        if !matchedTerms.contains(term) { matchedTerms.append(term) }
      } else if path.lowercased().contains(term) && term.count >= 4 {
        score += 5.0
        if !pathMatches.contains(term) { pathMatches.append(term) }
        if !matchedTerms.contains(term) { matchedTerms.append(term) }
      }
    }

    // 4. Imports match.
    for imp in entry.imports {
      let impLower = imp.lowercased()
      for term in terms where term.count >= 3 {
        if impLower == term || impLower.contains(term) {
          score += 10.0
          if !matchedTerms.contains(term) { matchedTerms.append(term) }
        }
      }
    }

    // 5. Incidental match in summary.
    let summaryLower = entry.summary.lowercased()
    for term in terms where term.count >= 4 {
      if summaryLower.contains(term) {
        score += 1.0
        if !matchedTerms.contains(term) { matchedTerms.append(term) }
      }
    }

    guard score > 0 else { return nil }

    // Format human-readable reason
    let reason: String
    if !symbolMatches.isEmpty && !pathMatches.isEmpty {
      let combined = Array(Set(symbolMatches + pathMatches)).sorted()
      reason = "path/symbol matches: " + combined.prefix(4).joined(separator: ", ")
    } else if !symbolMatches.isEmpty {
      reason = "symbol matches: " + symbolMatches.prefix(4).joined(separator: ", ")
    } else if !pathMatches.isEmpty {
      reason = "path matches: " + pathMatches.prefix(4).joined(separator: ", ")
    } else if isExplicitPath {
      reason = "exact path match"
    } else {
      reason = "term matches: " + matchedTerms.prefix(4).joined(separator: ", ")
    }

    return RetrievalCandidate(
      path: path,
      score: score,
      symbolMatches: symbolMatches,
      pathMatches: pathMatches,
      matchedTerms: matchedTerms,
      reason: reason
    )
  }

  // MARK: - Query Processing

  private func extractQueryTerms(from query: String) -> [String] {
    let lower = query.lowercased()
    var terms: Set<String> = []

    let rawTokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }

    for token in rawTokens {
      if !Self.stopWords.contains(token) && token.count >= 2 {
        terms.insert(token)
      }
      for sub in splitSubterms(token) {
        if !Self.stopWords.contains(sub) && sub.count >= 2 {
          terms.insert(sub)
        }
      }
    }

    return Array(terms)
  }

  private func splitSubterms(_ identifier: String) -> [String] {
    var parts: [String] = []
    let snakeParts = identifier.split(separator: "_").map(String.init)
    for part in snakeParts {
      var current = ""
      for char in part {
        if char.isUppercase && !current.isEmpty {
          parts.append(current.lowercased())
          current = String(char)
        } else {
          current.append(char)
        }
      }
      if !current.isEmpty {
        parts.append(current.lowercased())
      }
    }
    return parts
  }
}

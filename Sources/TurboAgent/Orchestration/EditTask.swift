import Foundation

/// A single step in an orchestrated edit plan.
struct EditTask: Sendable, Codable, Equatable, Identifiable {
  enum Kind: String, Sendable, Codable, CaseIterable {
    case inspect
    case edit
    case create
    case delete
    case validate

    var isMutating: Bool {
      self == .edit || self == .create || self == .delete
    }
  }

  let id: String
  let path: String
  let objective: String
  let kind: Kind
  let ranges: [ClosedRange<Int>]
  let referencePaths: [String]
  let dependencies: [String]

  init(
    id: String,
    path: String,
    objective: String,
    kind: Kind,
    ranges: [ClosedRange<Int>] = [],
    referencePaths: [String] = [],
    dependencies: [String] = []
  ) {
    self.id = id
    self.path = path
    self.objective = objective
    self.kind = kind
    self.ranges = ranges
    self.referencePaths = referencePaths
    self.dependencies = dependencies
  }

  enum CodingKeys: String, CodingKey {
    case id
    case path
    case objective
    case kind
    case ranges
    case referencePaths = "reference_paths"
    case referencePathsCamel = "referencePaths"
    case dependencies
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.path = try container.decode(String.self, forKey: .path)
    self.objective = try container.decode(String.self, forKey: .objective)
    self.kind = try container.decode(Kind.self, forKey: .kind)

    var decodedRanges: [ClosedRange<Int>] = []
    if container.contains(.ranges) {
      if let arrayRanges = try? container.decode([[Int]].self, forKey: .ranges) {
        for pair in arrayRanges where pair.count == 2 && pair[0] <= pair[1] {
          decodedRanges.append(pair[0]...pair[1])
        }
      } else if let dictRanges = try? container.decode([RangeDict].self, forKey: .ranges) {
        for item in dictRanges {
          if let s = item.start ?? item.lowerBound, let e = item.end ?? item.upperBound, s <= e {
            decodedRanges.append(s...e)
          }
        }
      } else if let standardRanges = try? container.decode([ClosedRange<Int>].self, forKey: .ranges) {
        decodedRanges = standardRanges
      }
    }
    self.ranges = decodedRanges

    let refs = (try? container.decode([String].self, forKey: .referencePaths))
      ?? (try? container.decode([String].self, forKey: .referencePathsCamel))
      ?? []
    self.referencePaths = refs

    self.dependencies = (try? container.decode([String].self, forKey: .dependencies)) ?? []
  }

  private struct RangeDict: Codable {
    let start: Int?
    let end: Int?
    let lowerBound: Int?
    let upperBound: Int?
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(path, forKey: .path)
    try container.encode(objective, forKey: .objective)
    try container.encode(kind, forKey: .kind)
    let rangePairs = ranges.map { [$0.lowerBound, $0.upperBound] }
    try container.encode(rangePairs, forKey: .ranges)
    try container.encode(referencePaths, forKey: .referencePaths)
    try container.encode(dependencies, forKey: .dependencies)
  }

  /// Coalesces overlapping or adjacent ranges for the same file.
  static func coalesceRanges(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
    guard !ranges.isEmpty else { return [] }
    let valid = ranges.filter { $0.lowerBound >= 1 && $0.upperBound >= $0.lowerBound }
    let sorted = valid.sorted { $0.lowerBound < $1.lowerBound }
    var result: [ClosedRange<Int>] = []
    for r in sorted {
      guard let last = result.last else {
        result.append(r)
        continue
      }
      if r.lowerBound <= last.upperBound + 1 {
        let merged = last.lowerBound...max(last.upperBound, r.upperBound)
        result[result.count - 1] = merged
      } else {
        result.append(r)
      }
    }
    return result
  }

  func withCoalescedRanges() -> EditTask {
    EditTask(
      id: id,
      path: path,
      objective: objective,
      kind: kind,
      ranges: Self.coalesceRanges(ranges),
      referencePaths: referencePaths,
      dependencies: dependencies
    )
  }
}

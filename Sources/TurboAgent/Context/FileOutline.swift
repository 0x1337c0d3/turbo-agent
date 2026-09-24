import Foundation

/// Navigation aids over one file revision. Incorrect parsing reduces outline
/// quality only; source correctness never depends on these values.
struct FileOutline: Sendable, Equatable, Codable {
  let revision: FileRevision
  let sections: [FileSection]
}

struct FileSection: Sendable, Equatable, Codable {
  let startLine: Int
  let endLine: Int
  let kind: String
  let name: String
  let signature: String?
}

/// Deterministic declaration recognition for Swift and C-family files plus a
/// generic fallback based on headings, braces, and non-empty line windows.
enum FileOutlineBuilder {
  static func sections(of content: String, path: String) -> [FileSection] {
    let lines = FileSlicer.splitLines(content)
    guard !lines.isEmpty else { return [] }
    let recognized = declarations(lines: lines, language: language(of: path))
    return mergeWithFallback(lines: lines, recognized: recognized)
  }

  // MARK: Language selection

  private enum Language { case swift, cFamily, generic }

  private static func language(of path: String) -> Language {
    switch (path as NSString).pathExtension.lowercased() {
    case "swift": return .swift
    case "c", "h", "cpp", "cc", "hpp", "cxx", "m", "mm": return .cFamily
    default: return .generic
    }
  }

  private static func declarations(lines: [String], language: Language) -> [FileSection] {
    switch language {
    case .swift: return swiftDeclarations(lines: lines)
    case .cFamily: return cFamilyDeclarations(lines: lines)
    case .generic: return []
    }
  }

  // MARK: Identifier helpers

  /// First identifier after a keyword match, skipping non-identifier characters.
  private static func identifier(
    after range: Range<String.Index>, in line: String
  ) -> String? {
    var index = range.upperBound
    while index < line.endIndex, !(line[index].isLetter || line[index] == "_") {
      index = line.index(after: index)
    }
    var name = ""
    while index < line.endIndex,
      line[index].isLetter || line[index].isNumber || line[index] == "_"
    {
      name.append(line[index])
      index = line.index(after: index)
    }
    return name.isEmpty ? nil : name
  }

  /// Last identifier immediately before an opening parenthesis, e.g. the
  /// function name in `static int read_character(EditLine *editor, ...)`.
  private static func identifier(before paren: String.Index, in line: String) -> String? {
    // Collect the identifier characters immediately before '('.
    var characters: [Character] = []
    var index = paren
    while index > line.startIndex {
      index = line.index(before: index)
      let character = line[index]
      guard character.isLetter || character.isNumber || character == "_" else { break }
      characters.append(character)
    }
    guard let first = characters.last, first.isLetter || first == "_" else { return nil }
    // Identifiers do not start with a digit.
    guard !characters.last!.isNumber else { return nil }
    return String(characters.reversed())
  }

  private static let controlKeywords: Set<String> = [
    "if", "for", "while", "switch", "return", "catch", "else", "do",
  ]

  private static func bracesOpened(_ line: String) -> Int {
    line.reduce(0) { $0 + ($1 == "{" ? 1 : 0) }
  }

  private static func bracesClosed(_ line: String) -> Int {
    line.reduce(0) { $0 + ($1 == "}" ? 1 : 0) }
  }

  private static func isCommentLine(_ line: String) -> Bool {
    line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("*")
  }

  /// One-based, inclusive last line of the block opened at `index`, or the
  /// declaration line itself when it does not open a brace body.
  private static func braceClosedEnd(lines: [String], from index: Int) -> Int {
    var depth = 0
    var sawOpen = false
    for offset in index..<lines.count {
      let line = lines[offset]
      depth += bracesOpened(line) - bracesClosed(line)
      if bracesOpened(line) > 0 { sawOpen = true }
      if sawOpen && depth <= 0 { return offset + 1 }
      if !sawOpen && offset > index && bracesClosed(line) > 0 { return offset + 1 }
    }
    return min(index + 1, lines.count)
  }

  // MARK: Swift declarations

  private static func swiftDeclarations(lines: [String]) -> [FileSection] {
    let kinds = ["struct", "class", "enum", "protocol", "extension", "actor"]
    let members = ["func", "init", "subscript"]
    var sections: [FileSection] = []
    for (index, raw) in lines.enumerated() {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !isCommentLine(trimmed), !trimmed.hasPrefix("@") else { continue }
      for keyword in kinds + members {
        guard let keywordRange = trimmed.range(
          of: "\\b\(keyword)\\b", options: .regularExpression)
        else { continue }
        guard let name = identifier(after: keywordRange, in: trimmed) else { continue }
        sections.append(
          FileSection(
            startLine: index + 1, endLine: braceClosedEnd(lines: lines, from: index),
            kind: keyword, name: name, signature: trimmed))
        break
      }
    }
    return sections
  }

  // MARK: C-family declarations

  private static func cFamilyDeclarations(lines: [String]) -> [FileSection] {
    var sections: [FileSection] = []
    for (index, raw) in lines.enumerated() {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), !isCommentLine(line) else { continue }
      guard let found = cDeclaration(
        line: line, nextLines: Array(lines[(index + 1)...].prefix(2)))
      else { continue }
      sections.append(
        FileSection(
          startLine: index + 1, endLine: braceClosedEnd(lines: lines, from: index),
          kind: found.kind, name: found.name, signature: found.signature))
    }
    return sections
  }

  private static func cDeclaration(
    line: String, nextLines: [String]
  ) -> (kind: String, name: String, signature: String)? {
    let opensBody =
      line.contains("{")
      || nextLines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
    guard opensBody else { return nil }

    if let markerRange = line.range(of: "\\bstruct\\b", options: .regularExpression),
      let name = identifier(after: markerRange, in: line)
    {
      return ("struct", name, line)
    }

    // Function definition: identifier immediately before '(' with a body.
    guard let paren = line.firstIndex(of: "("),
      let name = identifier(before: paren, in: line),
      !controlKeywords.contains(name)
    else { return nil }
    return ("func", name, line)
  }

  // MARK: Fallback coverage

  /// Uncovered non-empty runs become bounded windows so an outline always
  /// accounts for the whole file.
  private static func mergeWithFallback(
    lines: [String], recognized: [FileSection]
  ) -> [FileSection] {
    let covered = recognized.map { $0.startLine...$0.endLine }
    func isCovered(_ line: Int) -> Bool { covered.contains { $0.contains(line) } }

    var uncovered: [Int] = []
    for (index, line) in lines.enumerated()
    where !line.trimmingCharacters(in: .whitespaces).isEmpty && !isCovered(index + 1) {
      uncovered.append(index + 1)
    }
    guard !uncovered.isEmpty else { return recognized }

    var sections = recognized
    var start = uncovered[0]
    var previous = start
    for line in uncovered.dropFirst() {
      // Adjacent lines stay in one window; gaps beyond eight lines or windows
      // over 120 lines split so each entry stays a bounded navigation hint.
      if line - previous > 8 || line - start >= 120 {
        sections.append(
          FileSection(
            startLine: start, endLine: previous, kind: "block",
            name: "lines \(start)-\(previous)", signature: nil))
        start = line
      }
      previous = line
    }
    sections.append(
      FileSection(
        startLine: start, endLine: previous, kind: "block", name: "lines \(start)-\(previous)",
        signature: nil))
    return sections.sorted { $0.startLine < $1.startLine }
  }
}
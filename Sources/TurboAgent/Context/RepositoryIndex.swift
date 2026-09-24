import CryptoKit
import Foundation

/// A deterministic declaration extracted from an indexed file.
public struct IndexedDeclaration: Sendable, Equatable, Codable {
  public let name: String
  public let kind: String
  public let startLine: Int
  public let endLine: Int

  public init(name: String, kind: String, startLine: Int, endLine: Int) {
    self.name = name
    self.kind = kind
    self.startLine = startLine
    self.endLine = endLine
  }
}

/// An entry in the repository index representing an indexed text file.
/// Source bodies are never stored in the index to keep it lightweight and
/// avoid stale content in prompts.
public struct RepositoryIndexEntry: Sendable, Equatable, Codable {
  public let path: String
  public let byteCount: Int
  public let lineCount: Int
  public let modifiedNanoseconds: UInt64?
  public let digest: String
  public let language: String
  public let declarations: [IndexedDeclaration]
  public let imports: [String]
  public let summary: String

  public init(
    path: String,
    byteCount: Int,
    lineCount: Int,
    modifiedNanoseconds: UInt64? = nil,
    digest: String,
    language: String,
    declarations: [IndexedDeclaration],
    imports: [String],
    summary: String
  ) {
    self.path = path
    self.byteCount = byteCount
    self.lineCount = lineCount
    self.modifiedNanoseconds = modifiedNanoseconds
    self.digest = digest
    self.language = language
    self.declarations = declarations
    self.imports = imports
    self.summary = summary
  }
}

/// On-disk cache representation stored in `.turbo/context/repository_index.json`.
struct RepositoryIndexCache: Codable {
  static let currentVersion = 1
  let version: Int
  let createdAt: Date
  let entries: [String: RepositoryIndexEntry]
}

/// Lightweight, reconstructable local index for fast path and symbol discovery.
///
/// Phase 4 of docs/LARGE_FILE_EDITING.md:
/// - Safe scanning (skips build, cache, binary, outside symlinks).
/// - Incremental indexing using metadata fingerprints (size + modification time).
/// - Deterministic declaration extraction and cheap import recognition.
/// - Persisted under `.turbo/context/repository_index.json`.
public final class RepositoryIndex: @unchecked Sendable {
  public static let shared = RepositoryIndex()

  private static let workspaceLock = NSLock()
  nonisolated(unsafe) private static var workspaceInstances: [String: RepositoryIndex] = [:]

  /// Returns or creates the repository index for a specific workspace directory.
  public static func forWorkspace(_ directory: URL) -> RepositoryIndex {
    let standardized = directory.standardizedFileURL.path
    return workspaceLock.withLock {
      if let existing = workspaceInstances[standardized] {
        return existing
      }
      let instance = RepositoryIndex(workspaceURL: directory)
      workspaceInstances[standardized] = instance
      return instance
    }
  }

  /// Clears cached workspace index instances (primarily for testing).
  public static func resetWorkspaceInstances() {
    workspaceLock.withLock {
      workspaceInstances.removeAll()
    }
  }

  public let workspaceURL: URL
  private let lock = NSLock()
  private var entries: [String: RepositoryIndexEntry] = [:]
  private var isScanned = false

  /// File size ceiling: files larger than 512 KiB are skipped.
  public static let maximumFileSize = 512 * 1024
  /// Maximum number of indexed files.
  public static let maximumTotalFiles = 5_000

  public static let ignoredDirectoryNames: Set<String> = [
    ".git", ".build", ".swiftpm", ".turbo", ".gradle", ".idea", ".vscode",
    "node_modules", "Pods", "Carthage", "DerivedData", "derivedData",
    ".venv", "venv", "env", "__pycache__", "coverage", ".next", ".nuxt", "dist"
  ]

  public static let binaryExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "ico", "webp",
    "pdf", "zip", "tar", "gz", "bz2", "xz", "7z", "rar",
    "dylib", "so", "a", "o", "obj", "exe", "bin", "dll",
    "pyc", "pyo", "class", "jar", "war",
    "mp3", "mp4", "mov", "avi", "wav", "m4a",
    "ttf", "otf", "woff", "woff2", "eot",
    "wasm"
  ]

  public init(workspaceURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
    self.workspaceURL = workspaceURL.standardizedFileURL
  }

  /// Path to cache file: `<workspace>/.turbo/context/repository_index.json`.
  private var cacheURL: URL {
    workspaceURL.appendingPathComponent(".turbo/context/repository_index.json")
  }

  /// All currently indexed entries.
  public var allEntries: [RepositoryIndexEntry] {
    lock.withLock {
      ensureScannedLocked()
      return Array(entries.values)
    }
  }

  /// Returns the entry for a workspace-relative path.
  public func entry(for path: String) -> RepositoryIndexEntry? {
    lock.withLock {
      ensureScannedLocked()
      return entries[path]
    }
  }

  /// Number of indexed files.
  public var count: Int {
    lock.withLock {
      ensureScannedLocked()
      return entries.count
    }
  }

  /// Ensures the workspace has been scanned or loaded from cache.
  public func ensureScanned() {
    lock.withLock {
      ensureScannedLocked()
    }
  }

  private func ensureScannedLocked() {
    guard !isScanned else { return }
    isScanned = true
    loadCacheLocked()
    scanWorkspaceLocked()
    saveCacheLocked()
  }

  /// Scans the repository from scratch or updates existing entries.
  public func rescan() {
    lock.withLock {
      isScanned = true
      scanWorkspaceLocked()
      saveCacheLocked()
    }
  }

  /// Incremental refresh for a single file after write/edit.
  public func refresh(path: String) {
    lock.withLock {
      let relativePath = relativeWorkspacePath(for: path)
      let fileURL = workspaceURL.appendingPathComponent(relativePath)
      indexSingleFileLocked(fileURL: fileURL, relativePath: relativePath)
      saveCacheLocked()
    }
  }

  /// Incremental refresh using resolved absolute path.
  public func refresh(resolvedPath: String) {
    let relPath = relativeWorkspacePath(for: resolvedPath)
    refresh(path: relPath)
  }

  // MARK: - Workspace Scanning

  private func scanWorkspaceLocked() {
    let fm = FileManager.default
    let normalizedWorkspacePath = workspaceURL.resolvingSymlinksInPath().path

    guard fm.fileExists(atPath: workspaceURL.path) else { return }

    let resourceKeys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
      .fileSizeKey, .contentModificationDateKey
    ]

    guard let enumerator = fm.enumerator(
      at: workspaceURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsPackageDescendants]
    ) else { return }

    var seenPaths: Set<String> = []

    for case let fileURL as URL in enumerator {
      if entries.count >= Self.maximumTotalFiles { break }

      let fileName = fileURL.lastPathComponent

      // Skip ignored directories without descending into them.
      if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
        if Self.ignoredDirectoryNames.contains(fileName) || fileName.hasPrefix(".") {
          enumerator.skipDescendants()
          continue
        }
      }

      guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys) else {
        continue
      }

      // Check symlinks: do not follow symlinks outside workspace.
      if resourceValues.isSymbolicLink == true {
        let destination = fileURL.resolvingSymlinksInPath().path
        if destination != normalizedWorkspacePath && !destination.hasPrefix(normalizedWorkspacePath + "/") {
          continue
        }
      }

      // We only index regular files.
      guard resourceValues.isRegularFile == true else { continue }

      let ext = fileURL.pathExtension.lowercased()
      if Self.binaryExtensions.contains(ext) { continue }

      let fileSize = resourceValues.fileSize ?? 0
      guard fileSize > 0, fileSize <= Self.maximumFileSize else { continue }

      let relativePath = relativeWorkspacePath(for: fileURL.path)
      seenPaths.insert(relativePath)

      let modDate = resourceValues.contentModificationDate
      let modNanos = modDate.map { UInt64($0.timeIntervalSince1970 * 1_000_000_000) }

      // Incremental fingerprint check: reuse existing entry if unchanged.
      if let existing = entries[relativePath],
         existing.byteCount == fileSize,
         existing.modifiedNanoseconds == modNanos {
        continue
      }

      indexFile(fileURL: fileURL, relativePath: relativePath, fileSize: fileSize, modifiedNanoseconds: modNanos)
    }

    // Remove entries that no longer exist on disk.
    for path in entries.keys where !seenPaths.contains(path) {
      if !fm.fileExists(atPath: workspaceURL.appendingPathComponent(path).path) {
        entries.removeValue(forKey: path)
      }
    }
  }

  private func indexSingleFileLocked(fileURL: URL, relativePath: String) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else {
      entries.removeValue(forKey: relativePath)
      return
    }

    guard let resourceValues = try? fileURL.resourceValues(forKeys: [
      .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey
    ]), resourceValues.isRegularFile == true else {
      entries.removeValue(forKey: relativePath)
      return
    }

    let fileSize = resourceValues.fileSize ?? 0
    guard fileSize > 0, fileSize <= Self.maximumFileSize else {
      entries.removeValue(forKey: relativePath)
      return
    }

    let ext = fileURL.pathExtension.lowercased()
    if Self.binaryExtensions.contains(ext) {
      entries.removeValue(forKey: relativePath)
      return
    }

    let modDate = resourceValues.contentModificationDate
    let modNanos = modDate.map { UInt64($0.timeIntervalSince1970 * 1_000_000_000) }

    indexFile(fileURL: fileURL, relativePath: relativePath, fileSize: fileSize, modifiedNanoseconds: modNanos)
  }

  private func indexFile(
    fileURL: URL,
    relativePath: String,
    fileSize: Int,
    modifiedNanoseconds: UInt64?
  ) {
    // Check for binary probe / NUL bytes
    guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return }
    defer { try? fileHandle.close() }

    guard let probe = try? fileHandle.read(upToCount: min(8_000, fileSize)), !probe.contains(0) else {
      return
    }

    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return
    }

    let digest = FileRevision.digest(of: content)
    let lines = FileSlicer.splitLines(content)
    let lang = Self.detectLanguage(for: relativePath)
    let declarations = Self.extractDeclarations(from: content, lines: lines, path: relativePath, language: lang)
    let imports = Self.extractImports(from: lines, language: lang)
    let summary = Self.buildSummary(language: lang, lineCount: lines.count, declarations: declarations, imports: imports)

    let entry = RepositoryIndexEntry(
      path: relativePath,
      byteCount: fileSize,
      lineCount: lines.count,
      modifiedNanoseconds: modifiedNanoseconds,
      digest: digest,
      language: lang,
      declarations: declarations,
      imports: imports,
      summary: summary
    )

    entries[relativePath] = entry
  }

  // MARK: - Language & Declaration Extraction

  public static func detectLanguage(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "c", "h": return "c"
    case "cpp", "cc", "cxx", "hpp": return "cpp"
    case "m", "mm": return "objective-c"
    case "py": return "python"
    case "js", "mjs", "cjs": return "javascript"
    case "ts", "tsx": return "typescript"
    case "go": return "go"
    case "rs": return "rust"
    case "rb": return "ruby"
    case "java": return "java"
    case "kt", "kts": return "kotlin"
    case "sh", "bash", "zsh": return "shell"
    case "json": return "json"
    case "md", "markdown": return "markdown"
    case "yaml", "yml": return "yaml"
    case "toml": return "toml"
    case "xml", "plist": return "xml"
    case "html", "htm": return "html"
    case "css": return "css"
    default: return ext.isEmpty ? "text" : ext
    }
  }

  private static func extractDeclarations(
    from content: String,
    lines: [String],
    path: String,
    language: String
  ) -> [IndexedDeclaration] {
    if language == "swift" || language == "c" || language == "cpp" || language == "objective-c" {
      let sections = FileOutlineBuilder.sections(of: content, path: path)
      return sections.compactMap { s in
        guard s.kind != "block" else { return nil }
        return IndexedDeclaration(name: s.name, kind: s.kind, startLine: s.startLine, endLine: s.endLine)
      }
    }

    var declarations: [IndexedDeclaration] = []
    switch language {
    case "python":
      for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") {
          if let name = extractIdentifier(after: "def ", in: trimmed) {
            declarations.append(IndexedDeclaration(name: name, kind: "func", startLine: idx + 1, endLine: idx + 1))
          }
        } else if trimmed.hasPrefix("class ") {
          if let name = extractIdentifier(after: "class ", in: trimmed) {
            declarations.append(IndexedDeclaration(name: name, kind: "class", startLine: idx + 1, endLine: idx + 1))
          }
        }
      }
    case "go":
      for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("func ") {
          if let name = extractIdentifier(after: "func ", in: trimmed) {
            declarations.append(IndexedDeclaration(name: name, kind: "func", startLine: idx + 1, endLine: idx + 1))
          }
        } else if trimmed.hasPrefix("type ") {
          if let name = extractIdentifier(after: "type ", in: trimmed) {
            declarations.append(IndexedDeclaration(name: name, kind: "type", startLine: idx + 1, endLine: idx + 1))
          }
        }
      }
    case "rust":
      for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.range(of: "\\b(fn|struct|enum|trait)\\s+([a-zA-Z0-9_]+)", options: .regularExpression) {
          let str = String(trimmed[match])
          let parts = str.split(separator: " ")
          if parts.count >= 2 {
            declarations.append(IndexedDeclaration(name: String(parts[1]), kind: String(parts[0]), startLine: idx + 1, endLine: idx + 1))
          }
        }
      }
    case "javascript", "typescript":
      for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.range(of: "\\b(function|class)\\s+([a-zA-Z0-9_]+)", options: .regularExpression) {
          let str = String(trimmed[match])
          let parts = str.split(separator: " ")
          if parts.count >= 2 {
            declarations.append(IndexedDeclaration(name: String(parts[1]), kind: String(parts[0]), startLine: idx + 1, endLine: idx + 1))
          }
        }
      }
    default:
      break
    }
    return declarations
  }

  private static func extractIdentifier(after prefix: String, in line: String) -> String? {
    guard let range = line.range(of: prefix) else { return nil }
    var idx = range.upperBound
    while idx < line.endIndex && (line[idx].isWhitespace || line[idx] == "(") {
      idx = line.index(after: idx)
    }
    var name = ""
    while idx < line.endIndex && (line[idx].isLetter || line[idx].isNumber || line[idx] == "_") {
      name.append(line[idx])
      idx = line.index(after: idx)
    }
    return name.isEmpty ? nil : name
  }

  private static func extractImports(from lines: [String], language: String) -> [String] {
    var imports: [String] = []
    let sample = lines.prefix(100)

    for line in sample {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      switch language {
      case "swift":
        if trimmed.hasPrefix("import ") {
          let mod = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
          if !mod.isEmpty && !imports.contains(mod) { imports.append(mod) }
        }
      case "c", "cpp", "objective-c":
        if trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import") {
          if let start = trimmed.firstIndex(where: { $0 == "<" || $0 == "\"" }),
             let end = trimmed.lastIndex(where: { $0 == ">" || $0 == "\"" }),
             start < end {
            let header = String(trimmed[trimmed.index(after: start)..<end])
            if !imports.contains(header) { imports.append(header) }
          }
        }
      case "python":
        if trimmed.hasPrefix("import ") {
          let mod = trimmed.dropFirst(7).split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
          if !mod.isEmpty && !imports.contains(mod) { imports.append(mod) }
        } else if trimmed.hasPrefix("from ") {
          let mod = trimmed.dropFirst(5).components(separatedBy: " ").first ?? ""
          if !mod.isEmpty && !imports.contains(mod) { imports.append(mod) }
        }
      case "go":
        if trimmed.hasPrefix("import ") && trimmed.contains("\"") {
          if let firstQuote = trimmed.firstIndex(of: "\""),
             let lastQuote = trimmed.lastIndex(of: "\""),
             firstQuote < lastQuote {
            let pkg = String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
            if !imports.contains(pkg) { imports.append(pkg) }
          }
        }
      case "rust":
        if trimmed.hasPrefix("use ") {
          let path = trimmed.dropFirst(4).replacingOccurrences(of: ";", with: "")
            .trimmingCharacters(in: .whitespaces)
          if !path.isEmpty && !imports.contains(path) { imports.append(path) }
        }
      default:
        break
      }
    }
    return imports
  }

  private static func buildSummary(
    language: String,
    lineCount: Int,
    declarations: [IndexedDeclaration],
    imports: [String]
  ) -> String {
    let lang = language.capitalized
    let importSummary = imports.isEmpty ? "" : ", imports: \(imports.prefix(3).joined(separator: ", "))"
    if !declarations.isEmpty {
      let declNames = declarations.prefix(3).map(\.name).joined(separator: ", ")
      return "\(lang) source (\(lineCount) lines), \(declarations.count) declarations (\(declNames))\(importSummary)"
    } else {
      return "\(lang) file (\(lineCount) lines)\(importSummary)"
    }
  }

  // MARK: - Cache Persistence

  private func loadCacheLocked() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: cacheURL.path) else { return }
    do {
      let data = try Data(contentsOf: cacheURL)
      let cache = try JSONDecoder().decode(RepositoryIndexCache.self, from: data)
      guard cache.version == RepositoryIndexCache.currentVersion else { return }
      entries = cache.entries
    } catch {
      // Cache corruption degrades to rebuild or empty index.
      entries.removeAll()
    }
  }

  private func saveCacheLocked() {
    let fm = FileManager.default
    let dir = cacheURL.deletingLastPathComponent()
    do {
      if !fm.fileExists(atPath: dir.path) {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      }
      let cache = RepositoryIndexCache(
        version: RepositoryIndexCache.currentVersion,
        createdAt: Date(),
        entries: entries
      )
      let data = try JSONEncoder().encode(cache)
      try data.write(to: cacheURL, options: .atomic)
    } catch {
      // Optional cache; failure to save is non-fatal.
    }
  }

  // MARK: - Path Helpers

  private func relativeWorkspacePath(for path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let absolutePath = URL(fileURLWithPath: expanded, relativeTo: workspaceURL).standardizedFileURL.path
    let ws = workspaceURL.path
    if absolutePath.hasPrefix(ws) {
      var rel = String(absolutePath.dropFirst(ws.count))
      if rel.hasPrefix("/") { rel.removeFirst() }
      return rel.isEmpty ? "." : rel
    }
    return path
  }
}

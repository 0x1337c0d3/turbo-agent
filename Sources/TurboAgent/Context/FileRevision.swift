import CryptoKit
import Foundation

/// Stable identity of one file state as observed by a read.
///
/// Phase 1 of docs/LARGE_FILE_EDITING.md: partial reads carry this revision so
/// later phases can detect stale edits and revoked whole-file replacement
/// eligibility. The digest is SHA-256 over the UTF-8 bytes, so it is stable
/// across processes; the complete-content comparison in `AgentWritePlan`
/// remains the final write authority.
struct FileRevision: Sendable, Equatable, Codable {
  let path: String
  let digest: String
  let byteCount: Int
  let lineCount: Int
  let modifiedNanoseconds: UInt64?

  static let digestPrefix = "sha256:"

  static func digest(of content: String) -> String {
    let hash = SHA256.hash(data: Data(content.utf8))
    let hex = hash.map { String(format: "%02x", $0) }.joined()
    return digestPrefix + hex
  }

  init(path: String, content: String, modifiedNanoseconds: UInt64? = nil) {
    self.path = path
    self.digest = Self.digest(of: content)
    self.byteCount = content.utf8.count
    self.lineCount = FileSlicer.splitLines(content).count
    self.modifiedNanoseconds = modifiedNanoseconds
  }

  init(
    path: String, digest: String, byteCount: Int = 0, lineCount: Int = 0,
    modifiedNanoseconds: UInt64? = nil
  ) {
    self.path = path
    self.digest = digest
    self.byteCount = byteCount
    self.lineCount = lineCount
    self.modifiedNanoseconds = modifiedNanoseconds
  }

  static func snapshot(
    path: String,
    resolvedPath: String? = nil,
    workspaceURL: URL? = nil
  ) -> FileRevision? {
    let fullPath: String
    if let resolvedPath {
      fullPath = resolvedPath
    } else if let workspaceURL {
      fullPath = workspaceURL.appendingPathComponent(path).path
    } else {
      fullPath = path
    }
    guard FileManager.default.fileExists(atPath: fullPath) else { return nil }
    guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return nil }
    let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
    let modDate = attrs?[.modificationDate] as? Date
    let modNanos = modDate.map { UInt64($0.timeIntervalSince1970 * 1_000_000_000) }
    return FileRevision(path: path, content: content, modifiedNanoseconds: modNanos)
  }
}
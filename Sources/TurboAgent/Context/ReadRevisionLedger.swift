import Foundation

/// Runtime record of which complete file reads this session performed.
///
/// Phase 2 of docs/LARGE_FILE_EDITING.md: whole-file replacement through
/// `write_file` requires evidence that this runtime read the exact revision
/// completely. A range read, an outline, a receipt, or separate slices never
/// establishes eligibility, and a model-authored claim that a file was read
/// is never accepted: the ledger only records what the read path itself saw.
/// Per-turn/session state, not durable Continuity memory.
final class ReadRevisionLedger: @unchecked Sendable {
  static let shared = ReadRevisionLedger()

  private struct Entry: Equatable {
    let byteCount: Int
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var insertionOrder: [String] = []
  private static let maximumEntries = 256

  func clear() {
    lock.withLock {
      entries = [:]
      insertionOrder = []
    }
  }

  /// Records a read of `resolvedPath` at `digest`. `complete` is true only
  /// when the read covered every line of the file at that revision.
  func record(resolvedPath: String, digest: String, byteCount: Int, complete: Bool) {
    guard complete else { return }
    lock.withLock {
      let key = ledgerKey(resolvedPath: resolvedPath, digest: digest)
      if entries[key] == nil {
        insertionOrder.append(key)
      }
      entries[key] = Entry(byteCount: byteCount)
      while insertionOrder.count > Self.maximumEntries {
        let oldest = insertionOrder.removeFirst()
        entries.removeValue(forKey: oldest)
      }
    }
  }

  /// Whether the exact (path, digest) revision was read completely and has
  /// not been evicted. Returns false, rather than erroring, so the caller
  /// renders the actionable whole-file-read guidance.
  func isCompleteRead(resolvedPath: String, digest: String) -> Bool {
    lock.withLock {
      entries[ledgerKey(resolvedPath: resolvedPath, digest: digest)] != nil
    }
  }

  private func ledgerKey(resolvedPath: String, digest: String) -> String {
    resolvedPath + "\u{0}" + digest
  }
}

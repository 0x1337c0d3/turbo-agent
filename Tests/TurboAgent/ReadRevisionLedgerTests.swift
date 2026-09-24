import Foundation
import XCTest

@testable import TurboAgentCore

/// Unit coverage for the phase 2 whole-file replacement ledger: only a
/// complete read of the exact revision is recorded, entries are keyed by
/// resolved path and digest, and the bounded history evicts oldest entries.
final class ReadRevisionLedgerTests: XCTestCase, @unchecked Sendable {
  override func setUp() {
    ReadRevisionLedger.shared.clear()
  }

  override func tearDown() {
    ReadRevisionLedger.shared.clear()
    super.tearDown()
  }

  func testPartialReadsAreNeverRecorded() {
    ReadRevisionLedger.shared.record(
      resolvedPath: "/tmp/a.swift", digest: "sha256:aa", byteCount: 100, complete: false)
    XCTAssertFalse(ReadRevisionLedger.shared.isCompleteRead(resolvedPath: "/tmp/a.swift", digest: "sha256:aa"))
  }

  func testCompleteReadMatchesOnlyItsExactRevisionAndPath() {
    ReadRevisionLedger.shared.record(
      resolvedPath: "/tmp/a.swift", digest: "sha256:aa", byteCount: 100, complete: true)
    XCTAssertTrue(
      ReadRevisionLedger.shared.isCompleteRead(resolvedPath: "/tmp/a.swift", digest: "sha256:aa"))
    XCTAssertFalse(
      ReadRevisionLedger.shared.isCompleteRead(resolvedPath: "/tmp/a.swift", digest: "sha256:bb"))
    XCTAssertFalse(
      ReadRevisionLedger.shared.isCompleteRead(resolvedPath: "/tmp/b.swift", digest: "sha256:aa"))
  }

  func testLedgerIsBoundedAndEvictsOldestCompleteReads() {
    for index in 0..<300 {
      ReadRevisionLedger.shared.record(
        resolvedPath: "/tmp/file-\(index)", digest: "sha256:\(index)", byteCount: 10,
        complete: true)
    }
    // The oldest entries fell out of the bounded window...
    XCTAssertFalse(
      ReadRevisionLedger.shared.isCompleteRead(resolvedPath: "/tmp/file-0", digest: "sha256:0"))
    // ...and the newest complete read still counts.
    XCTAssertTrue(
      ReadRevisionLedger.shared.isCompleteRead(
        resolvedPath: "/tmp/file-299", digest: "sha256:299"))
  }

  func testClearRevokesAllEligibility() {
    ReadRevisionLedger.shared.record(
      resolvedPath: "/tmp/a.swift", digest: "sha256:aa", byteCount: 100, complete: true)
    ReadRevisionLedger.shared.clear()
    XCTAssertFalse(
      ReadRevisionLedger.shared.isCompleteRead(resolvedPath: "/tmp/a.swift", digest: "sha256:aa"))
  }
}

import XCTest

@testable import TurboFieldfareAgentCore

final class TerminalTranscriptTests: XCTestCase {
  func testGenerationShortcutsRecognizeEnhancedEncodingsWithoutCancelling() {
    for key in ["\u{0F}", "\u{001B}[111;5u", "\u{001B}[27;5;111~"] {
      XCTAssertEqual(TerminalGenerationKey.decode(Array(key.utf8)), .toggleTools)
    }
    XCTAssertEqual(TerminalGenerationKey.decode([27]), .stop)
    XCTAssertEqual(TerminalGenerationKey.decode([3]), .interrupt)
    XCTAssertEqual(TerminalGenerationKey.decode(Array("\u{001B}[A".utf8)), .ignored)
  }
  private func plain(_ rows: [String]) -> String {
    rows.joined(separator: "\n").replacingOccurrences(
      of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
  }

  func testToggleRestoresAllToolResultsAndRetainsSurroundingText() {
    var transcript = TerminalTranscript()
    transcript.append("Before\n")
    _ = transcript.appendTool(header: "preview", result: "FULL FIRST RESULT")
    transcript.append("Between\n")
    _ = transcript.appendTool(header: "other", result: "FULL SECOND RESULT")
    transcript.append("After\n")
    let collapsed = transcript.rows(width: 80)
    XCTAssertFalse(plain(collapsed).contains("FULL"))
    transcript.toggle()
    let expanded = plain(transcript.rows(width: 80))
    XCTAssertTrue(expanded.contains("FULL FIRST RESULT"))
    XCTAssertTrue(expanded.contains("FULL SECOND RESULT"))
    XCTAssertTrue(expanded.contains("Before\n"))
    XCTAssertTrue(expanded.contains("Between\n"))
    XCTAssertTrue(expanded.contains("After\n"))
    transcript.toggle()
    XCTAssertEqual(transcript.rows(width: 80), collapsed)
  }

  func testNewResultsFollowExpansionAndEmptyResultsRemainVisible() {
    var transcript = TerminalTranscript()
    transcript.toggle()
    XCTAssertFalse(transcript.expanded)
    _ = transcript.appendTool(header: "", result: "")
    transcript.toggle()
    XCTAssertTrue(
      transcript.appendTool(header: "complete", result: "complete").contains("complete"))
    XCTAssertTrue(plain(transcript.rows(width: 80)).contains("ctrl+o to collapse"))
  }

  func testThoughtExpansionToggle() {
    var transcript = TerminalTranscript()
    _ = transcript.appendThought("First line of thinking.\nDetailed second line of deep thought.")
    let collapsed = plain(transcript.rows(width: 80))
    XCTAssertTrue(collapsed.contains("Thinking: First line of thinking."))
    XCTAssertTrue(collapsed.contains("[ctrl+o to expand]"))
    XCTAssertFalse(collapsed.contains("Detailed second line"))

    transcript.toggle()
    let expanded = plain(transcript.rows(width: 80))
    XCTAssertTrue(expanded.contains("Detailed second line of deep thought."))
    XCTAssertTrue(expanded.contains("ctrl+o to collapse"))

    transcript.toggle()
    XCTAssertEqual(plain(transcript.rows(width: 80)), collapsed)
  }

  func testExpandedOutputCannotInjectTerminalCommands() {
    var transcript = TerminalTranscript()
    _ = transcript.appendTool(header: "safe", result: "safe\u{001B}[2J\r\u{009B}31m\u{202E}bad")
    transcript.toggle()
    let output = plain(transcript.rows(width: 100))
    XCTAssertTrue(output.contains("\\u{001B}[2J\\u{000D}\\u{009B}31m\\u{202E}bad"))
    XCTAssertFalse(output.contains("\u{001B}[2J"))
  }

  func testWrappingPreservesGraphemesTabsAndColors() {
    setlocale(LC_CTYPE, "en_US.UTF-8")
    let rows = TerminalTranscript.wrap("\u{001B}[33m猫猫ab\te\u{0301}🙂\u{001B}[0m\n", width: 6)
    XCTAssertEqual(plain(rows), "猫猫ab\n  e\u{0301}🙂\n")
    XCTAssertTrue(rows[1].hasPrefix("\u{001B}[33m"))
    XCTAssertEqual(plain(TerminalTranscript.wrap("abcdef", width: 3)), "abc\ndef")
  }

  func testToggleResetsPagingAndDoesNotChangeRetainedData() {
    var transcript = TerminalTranscript()
    _ = transcript.appendTool(header: "test", result: String(repeating: "line\n", count: 100))
    transcript.scrollOffset = 99
    transcript.toggle()
    XCTAssertEqual(transcript.scrollOffset, 0)
    XCTAssertEqual(transcript.entries.count, 1)
    XCTAssertEqual(plain(transcript.rows(width: 80)).components(separatedBy: "line").count, 101)
  }
}

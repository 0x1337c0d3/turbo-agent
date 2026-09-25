import XCTest

@testable import TurboAgentCore

final class TerminalViewportTests: XCTestCase {
  private func stripAnsi(_ text: String) -> String {
    text.replacingOccurrences(
      of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
  }

  func testMultipleEntriesExpandCollapseAndRepeatedToggles() {
    var transcript = TerminalTranscript()
    transcript.append("Initial text\n")
    _ = transcript.appendTool(header: "tool1", result: "TOOL1_LONG_OUTPUT_PAYLOAD")
    transcript.append("Middle text\n")
    _ = transcript.appendThought("First thought line\nSecond thought detail")
    transcript.append("Between thought and tool2\n")
    _ = transcript.appendTool(header: "tool2", result: "TOOL2_LONG_OUTPUT_PAYLOAD")
    transcript.append("Final text\n")

    // Collapsed viewport
    let size = (rows: 24, columns: 80)
    let collapsedVp = TerminalViewport(terminalSize: size, promptRows: 1, transcript: transcript)
    let collapsedText = collapsedVp.visibleTranscriptRows.joined(separator: "\n")
    XCTAssertFalse(collapsedText.contains("TOOL1_LONG_OUTPUT_PAYLOAD"))
    XCTAssertFalse(collapsedText.contains("TOOL2_LONG_OUTPUT_PAYLOAD"))
    XCTAssertFalse(collapsedText.contains("Second thought detail"))
    XCTAssertTrue(collapsedText.contains("(ctrl+o to expand)"))
    XCTAssertTrue(collapsedText.contains("Initial text"))
    XCTAssertTrue(collapsedText.contains("Middle text"))
    XCTAssertTrue(collapsedText.contains("Final text"))

    // Toggle 1: Expand
    transcript.toggle()
    XCTAssertTrue(transcript.expanded)
    let expandedVp = TerminalViewport(terminalSize: size, promptRows: 1, transcript: transcript)
    let expandedText = expandedVp.visibleTranscriptRows.joined(separator: "\n")
    XCTAssertTrue(expandedText.contains("TOOL1_LONG_OUTPUT_PAYLOAD"))
    XCTAssertTrue(expandedText.contains("TOOL2_LONG_OUTPUT_PAYLOAD"))
    XCTAssertTrue(expandedText.contains("Second thought detail"))
    XCTAssertTrue(expandedText.contains("[ctrl+o to collapse]"))

    // Toggle 2: Collapse
    transcript.toggle()
    XCTAssertFalse(transcript.expanded)
    let collapsedVp2 = TerminalViewport(terminalSize: size, promptRows: 1, transcript: transcript)
    XCTAssertEqual(collapsedVp2.allTranscriptRows, collapsedVp.allTranscriptRows)

    // Toggle 3: Expand again
    transcript.toggle()
    XCTAssertTrue(transcript.expanded)
    let expandedVp2 = TerminalViewport(terminalSize: size, promptRows: 1, transcript: transcript)
    XCTAssertEqual(expandedVp2.allTranscriptRows, expandedVp.allTranscriptRows)
  }

  func testContentShorterThanEqualToAndTallerThanViewport() {
    let size = (rows: 10, columns: 80)
    // transcriptHeight for size 10 and promptRows 1: 10 - 1 - 1 = 8 rows.

    // 1. Shorter: 3 rows
    var shortTranscript = TerminalTranscript()
    shortTranscript.append("Line 1\nLine 2\nLine 3\n")
    let shortVp = TerminalViewport(terminalSize: size, promptRows: 1, transcript: shortTranscript)
    XCTAssertEqual(shortVp.transcriptHeight, 8)
    XCTAssertEqual(shortVp.visibleTranscriptRows.count, 3)
    XCTAssertEqual(shortVp.paddingRows, 5)
    XCTAssertEqual(shortVp.clampedScrollOffset, 0)

    // 2. Exactly equal: 8 rows
    var equalTranscript = TerminalTranscript()
    for i in 1...8 { equalTranscript.append("Line \(i)\n") }
    let equalVp = TerminalViewport(terminalSize: size, promptRows: 1, transcript: equalTranscript)
    XCTAssertEqual(equalVp.transcriptHeight, 8)
    XCTAssertEqual(equalVp.visibleTranscriptRows.count, 8)
    XCTAssertEqual(equalVp.paddingRows, 0)
    XCTAssertEqual(equalVp.clampedScrollOffset, 0)

    // 3. Taller: 20 rows
    var tallTranscript = TerminalTranscript()
    for i in 1...20 { tallTranscript.append("Line \(i)\n") }
    let tallVp = TerminalViewport(terminalSize: size, promptRows: 1, transcript: tallTranscript)
    XCTAssertEqual(tallVp.transcriptHeight, 8)
    XCTAssertEqual(tallVp.visibleTranscriptRows.count, 8)
    XCTAssertEqual(tallVp.paddingRows, 0)
    XCTAssertEqual(tallVp.clampedScrollOffset, 0)
    // Shows the latest 8 rows (lines 13 to 20)
    XCTAssertTrue(tallVp.visibleTranscriptRows.first?.contains("Line 13") == true)
    XCTAssertTrue(tallVp.visibleTranscriptRows.last?.contains("Line 20") == true)
  }

  func testNarrowWidthsUnicodeTabsAndWrappedLines() {
    var transcript = TerminalTranscript()
    transcript.append("\u{001B}[32m猫猫\tab\u{001B}[0m\n")

    let narrowVp = TerminalViewport(
      terminalSize: (rows: 15, columns: 10), promptRows: 0, transcript: transcript)
    // Width is 9 (columns - 1). Lines wrap properly without crashing.
    XCTAssertGreaterThan(narrowVp.allTranscriptRows.count, 0)

    // Compare prompt row calculations between Swift and expectations matching C
    XCTAssertEqual(TerminalViewport.promptRows(for: "", columns: 80), 1)
    XCTAssertEqual(TerminalViewport.promptRows(for: "hello", columns: 80), 1)
    XCTAssertEqual(TerminalViewport.promptRows(for: "line1\nline2", columns: 80), 2)
    // Prompt is "> " (2 chars). 77 chars fits in 80 (total 79). 78 chars wraps (total 80).
    XCTAssertEqual(TerminalViewport.promptRows(for: String(repeating: "a", count: 77), columns: 80), 1)
    XCTAssertEqual(TerminalViewport.promptRows(for: String(repeating: "a", count: 78), columns: 80), 2)
    XCTAssertEqual(TerminalViewport.promptRows(for: String(repeating: "a", count: 170), columns: 80), 3)
  }

  func testPromptReservationsZeroOneMultipleAndNearlyAll() {
    let size = (rows: 24, columns: 80)
    var transcript = TerminalTranscript()
    transcript.append("Hello world\n")

    // 0: Generation mode
    let vp0 = TerminalViewport(terminalSize: size, promptRows: 0, transcript: transcript)
    XCTAssertEqual(vp0.reservedPromptRows, 0)
    XCTAssertEqual(vp0.transcriptHeight, 23)
    XCTAssertNil(vp0.promptOrigin)
    XCTAssertNotNil(vp0.streamingCursor)
    XCTAssertEqual(vp0.streamingCursor?.row, 23)

    // 1: Normal prompt
    let vp1 = TerminalViewport(terminalSize: size, promptRows: 1, transcript: transcript)
    XCTAssertEqual(vp1.reservedPromptRows, 1)
    XCTAssertEqual(vp1.transcriptHeight, 22)
    XCTAssertEqual(vp1.promptOrigin, TerminalViewport.CursorPosition(row: 23, column: 1))
    XCTAssertNil(vp1.streamingCursor)

    // 5: Multiline prompt
    let vp5 = TerminalViewport(terminalSize: size, promptRows: 5, transcript: transcript)
    XCTAssertEqual(vp5.reservedPromptRows, 5)
    XCTAssertEqual(vp5.transcriptHeight, 18)
    XCTAssertEqual(vp5.promptOrigin, TerminalViewport.CursorPosition(row: 19, column: 1))

    // Nearly all: 22 (clamped to terminalRows - 2 = 22, height = 1)
    let vpMax = TerminalViewport(terminalSize: size, promptRows: 30, transcript: transcript)
    XCTAssertEqual(vpMax.reservedPromptRows, 22)
    XCTAssertEqual(vpMax.transcriptHeight, 1)
    XCTAssertEqual(vpMax.promptOrigin, TerminalViewport.CursorPosition(row: 2, column: 1))
  }

  func testResizeBetweenToggles() {
    var transcript = TerminalTranscript()
    _ = transcript.appendTool(header: "tool", result: "TOOL_PAYLOAD_HERE")

    // Before resize at (24, 80)
    let vp1 = TerminalViewport(terminalSize: (24, 80), promptRows: 1, transcript: transcript)
    XCTAssertEqual(vp1.terminalRows, 24)
    XCTAssertEqual(vp1.terminalColumns, 80)

    // Expand
    transcript.toggle()
    // Resize to (18, 50)
    let vp2 = TerminalViewport(terminalSize: (18, 50), promptRows: 2, transcript: transcript)
    XCTAssertEqual(vp2.terminalRows, 18)
    XCTAssertEqual(vp2.terminalColumns, 50)
    XCTAssertEqual(vp2.transcriptHeight, 15)  // 18 - 1 - 2 = 15
    XCTAssertEqual(vp2.promptOrigin?.row, 16)
    XCTAssertTrue(vp2.visibleTranscriptRows.joined().contains("TOOL_PAYLOAD_HERE"))

    // Collapse after resize
    transcript.toggle()
    let vp3 = TerminalViewport(terminalSize: (18, 50), promptRows: 2, transcript: transcript)
    XCTAssertFalse(vp3.visibleTranscriptRows.joined().contains("TOOL_PAYLOAD_HERE"))
    XCTAssertTrue(vp3.visibleTranscriptRows.joined().contains("(ctrl+o to expand)"))
  }

  func testClearingRowsLeftBehindWhenCollapsing() {
    let size = (rows: 15, columns: 80)
    var transcript = TerminalTranscript()
    _ = transcript.appendTool(
      header: "tool", result: (0..<10).map { "EXPANDED_ROW_\($0)" }.joined(separator: "\n"))

    // Expand
    transcript.toggle()
    let expandedVp = TerminalViewport(terminalSize: size, promptRows: 1, transcript: transcript)
    let expandedRender = expandedVp.render()
    XCTAssertTrue(expandedRender.contains("EXPANDED_ROW_0"))

    // Collapse
    transcript.toggle()
    let collapsedVp = TerminalViewport(terminalSize: size, promptRows: 1, transcript: transcript)
    let collapsedRender = collapsedVp.render()
    XCTAssertFalse(collapsedRender.contains("EXPANDED_ROW_0"))

    // Verify all rows 1 through terminalRows - 1 are cleared with [2K
    for r in 1...14 {
      XCTAssertTrue(
        collapsedRender.contains("\u{001B}[\(r);1H\u{001B}[2K"),
        "Row \(r) should be explicitly cleared")
    }
  }

  func testScrollOffsetClampingAndResetToLatestOnToggle() {
    var transcript = TerminalTranscript()
    _ = transcript.appendTool(
      header: "tool", result: (0..<50).map { "LINE_\($0)" }.joined(separator: "\n"))
    transcript.toggle()  // expand to 50+ lines

    // Scroll back 20 lines
    transcript.scrollOffset = 20
    let vp = TerminalViewport(terminalSize: (20, 80), promptRows: 1, transcript: transcript)
    XCTAssertEqual(vp.clampedScrollOffset, 20)

    // Toggle collapses and resets scrollOffset to 0
    transcript.toggle()
    XCTAssertEqual(transcript.scrollOffset, 0)
    let vpCollapsed = TerminalViewport(terminalSize: (20, 80), promptRows: 1, transcript: transcript)
    XCTAssertEqual(vpCollapsed.clampedScrollOffset, 0)
  }

  func testCursorDestinationsForPromptAndGenerationModes() {
    var transcript = TerminalTranscript()
    transcript.append("Hello world")

    // Generation mode (promptRows == 0): streaming cursor at end of line
    let genVp = TerminalViewport(terminalSize: (24, 80), promptRows: 0, transcript: transcript)
    XCTAssertNil(genVp.promptOrigin)
    // "Hello world" is 11 chars. Column is 11 + 1 = 12. Row is height (23).
    XCTAssertEqual(
      genVp.streamingCursor, TerminalViewport.CursorPosition(row: 23, column: 12))
    let renderGen = genVp.render()
    XCTAssertTrue(renderGen.hasSuffix("\u{001B}[23;12H"))
    XCTAssertFalse(renderGen.contains("Hello world\u{001B}[23;12HHello world"))

    // Prompt mode (promptRows == 1): prompt origin at row 23 col 1
    let promptVp = TerminalViewport(terminalSize: (24, 80), promptRows: 1, transcript: transcript)
    XCTAssertNil(promptVp.streamingCursor)
    XCTAssertEqual(
      promptVp.promptOrigin, TerminalViewport.CursorPosition(row: 23, column: 1))
    let renderPrompt = promptVp.render()
    XCTAssertTrue(renderPrompt.hasSuffix("\u{001B}[23;1H"))
  }

  func testPureRenderAndInjectedWriter() {
    var transcript = TerminalTranscript()
    transcript.append("Test content\n")
    var snapshot = AgentStatusSnapshot()
    snapshot.phase = "Testing"
    snapshot.contextTokens = 100
    snapshot.maxContext = 1000

    let vp = TerminalViewport(
      terminalSize: (24, 80), promptRows: 1, transcript: transcript, footer: snapshot)
    let rendered = vp.render()

    // Pure render tests without any TTY
    XCTAssertTrue(rendered.contains("\u{001B}[1;23r"))
    XCTAssertTrue(rendered.contains("\u{001B}[24;1H\u{001B}[2K\u{001B}[90m"))
    XCTAssertTrue(rendered.contains("Testing"))
    XCTAssertTrue(rendered.contains("ctx 100/1000"))
    XCTAssertTrue(rendered.contains("\u{001B}[23;1H"))  // prompt origin

    // Injected writer test on AgentTerminal
    var captured = ""
    AgentTerminal.customWriter = { captured += $0 }
    defer { AgentTerminal.customWriter = nil }

    AgentTerminal.write("custom output test")
    XCTAssertEqual(captured, "custom output test")
  }
}

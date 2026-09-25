import Darwin
import Foundation

/// Pure, deterministic viewport layout for the interactive terminal.
/// Calculates visible transcript rows, scroll clamping, prompt and streaming
/// cursor destinations, and terminal redraw escape sequences.
struct TerminalViewport: Equatable {
  struct CursorPosition: Equatable {
    var row: Int  // 1-based row index
    var column: Int  // 1-based column index
  }

  let terminalRows: Int
  let terminalColumns: Int
  let promptRows: Int
  let reservedPromptRows: Int
  let transcriptHeight: Int
  let allTranscriptRows: [String]
  let clampedScrollOffset: Int
  let visibleTranscriptRows: [String]
  let paddingRows: Int
  let promptOrigin: CursorPosition?
  let streamingCursor: CursorPosition?
  let footerRow: Int
  let footerText: String?

  init(
    terminalSize: (rows: Int, columns: Int),
    promptRows: Int,
    transcript: TerminalTranscript,
    footer: AgentStatusSnapshot? = nil
  ) {
    self.terminalRows = max(3, terminalSize.rows)
    self.terminalColumns = max(2, terminalSize.columns)
    self.promptRows = max(0, promptRows)
    self.reservedPromptRows = min(self.promptRows, self.terminalRows - 2)
    self.transcriptHeight = max(0, self.terminalRows - 1 - self.reservedPromptRows)

    let effectiveWidth = max(1, self.terminalColumns - 1)
    var rows = transcript.rows(width: effectiveWidth)
    if self.reservedPromptRows > 0, rows.last == "\u{001B}[0m" {
      rows.removeLast()
    }
    self.allTranscriptRows = rows

    let maxOffset = max(0, rows.count - self.transcriptHeight)
    self.clampedScrollOffset = min(max(0, transcript.scrollOffset), maxOffset)

    let end = rows.count - self.clampedScrollOffset
    let start = max(0, end - self.transcriptHeight)
    self.visibleTranscriptRows = Array(rows[start..<end])
    self.paddingRows = max(0, self.transcriptHeight - self.visibleTranscriptRows.count)

    if self.reservedPromptRows > 0 {
      self.promptOrigin = CursorPosition(row: self.transcriptHeight + 1, column: 1)
      self.streamingCursor = nil
    } else {
      self.promptOrigin = nil
      let lastWidth =
        self.visibleTranscriptRows.last.map { TerminalTranscript.cellWidth(of: $0) } ?? 0
      let cursorRow = max(1, self.transcriptHeight)
      let cursorCol = min(self.terminalColumns, lastWidth + 1)
      self.streamingCursor = CursorPosition(row: cursorRow, column: max(1, cursorCol))
    }

    self.footerRow = self.terminalRows
    self.footerText = footer?.text(width: self.terminalColumns)
  }

  func render() -> String {
    var output = "\u{001B}[0m\u{001B}[1;\(terminalRows - 1)r"
    if let footerText {
      output += "\u{001B}[\(footerRow);1H\u{001B}[2K\u{001B}[90m\(footerText)\u{001B}[0m"
    }
    for row in 1...(terminalRows - 1) {
      output += "\u{001B}[\(row);1H\u{001B}[2K"
      if row <= transcriptHeight {
        let index = (row - 1) - paddingRows
        if index >= 0, index < visibleTranscriptRows.count {
          output += visibleTranscriptRows[index]
        }
      }
    }
    if let promptOrigin {
      output += "\u{001B}[\(promptOrigin.row);\(promptOrigin.column)H"
    } else if let streamingCursor {
      output += "\u{001B}[\(streamingCursor.row);\(streamingCursor.column)H"
    }
    return output
  }

  /// Calculates the prompt height in screen rows for a given draft string at terminal column width,
  /// matching the line wrapping algorithm in AgentLineEditor.c.
  static func promptRows(for draft: String, columns: Int) -> Int {
    guard columns >= 2 else { return 1 }
    var rows = 1
    var column = 2  // Prompt is "> " (2 columns)
    for scalar in draft.unicodeScalars {
      if scalar == "\n" {
        rows += 1
        column = 0
        continue
      }
      let width: Int
      if scalar == "\t" {
        width = 8 - column % 8
      } else {
        let w = Int(wcwidth(Int32(scalar.value)))
        width = w < 0 ? 2 : w
      }
      if column + width > columns {
        rows += 1
        column = 0
      }
      column += width
      if column >= columns {
        rows += 1
        column = 0
      }
    }
    return rows
  }
}

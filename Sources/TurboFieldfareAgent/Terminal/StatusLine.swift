import Darwin
import Foundation

/// Serializes footer cursor movements with streamed output and the thinking spinner.
enum AgentTerminal {
  private static let lock = NSRecursiveLock()
  nonisolated(unsafe) private static var transcript: TerminalTranscript?
  nonisolated(unsafe) private static var footer: AgentStatusSnapshot?

  static func rememberFooter(_ snapshot: AgentStatusSnapshot) {
    lock.withLock { footer = snapshot }
  }

  static var size: (rows: Int, columns: Int)? {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
      ProcessInfo.processInfo.environment["TERM"] != "dumb"
    else { return nil }
    var size = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0,
      size.ws_row >= 3, size.ws_col >= 2
    else { return nil }
    return (Int(size.ws_row), Int(size.ws_col))
  }

  static func beginTranscript() {
    lock.withLock { transcript = size == nil ? nil : TerminalTranscript() }
  }

  static func endTranscript() {
    lock.withLock { transcript = nil }
  }

  static func output(_ text: String) {
    lock.withLock {
      transcript?.append(text)
      write(text)
    }
  }

  static func toolResult(header: String, result: String, limit: Int) {
    lock.withLock {
      if var t = transcript {
        let text = t.appendTool(header: header, result: result)
        transcript = t
        write(text)
      } else {
        // Non-TUI path (pipe / dumb terminal): print header then a short preview.
        write("\u{001B}[32m\n● \(TerminalText.safe(header))\u{001B}[0m\n")
        let cap = max(0, limit)
        let suffix = result.count > cap ? "..." : ""
        write(
          "\u{001B}[33m   \(TerminalText.safe(String(result.prefix(cap))))\(suffix)\u{001B}[0m\n")
      }
    }
  }

  static func thought(_ text: String) {
    lock.withLock {
      if let formatted = transcript?.appendThought(text) {
        write(formatted)
      } else {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
        let preview = String(firstLine.prefix(60))
        write("\u{001B}[90m   Thinking: \(TerminalText.safe(preview))...\u{001B}[0m\n")
      }
    }
  }

  static func recordPrompt(_ input: String) {
    lock.withLock {
      transcript?.append("\u{001B}[32m> \u{001B}[0m" + TerminalText.safe(input) + "\n")
      if let offset = transcript?.scrollOffset, offset > 0 {
        transcript?.scrollOffset = 0
        repaint(promptRows: 0)
      }
    }
  }

  nonisolated(unsafe) static var onToggleMode: (() -> Void)? = nil

  /// action: 0 toggles tools; -1/+1 page up/down. The editor redraws its own
  /// draft after this returns, at the cursor position reserved for it here.
  @discardableResult
  static func navigate(_ action: Int, promptRows: Int) -> Bool {
    if action == 2 {
      onToggleMode?()
      return true
    }

    return lock.withLock {
      guard let size, transcript?.hasTools == true else { return false }
      if action == 0 {
        toggle(promptRows: promptRows)
        return true
      } else {
        let page = max(1, size.rows - 1 - promptRows)
        transcript?.scrollOffset += action < 0 ? page : -page
        repaint(promptRows: promptRows)
      }
      return true
    }
  }

  static var isExpanded: Bool {
    lock.withLock { transcript?.expanded ?? false }
  }

  /// Toggle expand/collapse for tool outputs and thinking blocks, then fully
  /// repaint the TUI. Always does a complete redraw so the viewport is correct
  /// in both states — during active generation (promptRows == 0) and at the
  /// interactive prompt (promptRows > 0).
  private static func toggle(promptRows: Int) {
    guard size != nil, var content = transcript else { return }
    content.toggle()
    transcript = content
    repaint(promptRows: promptRows)
  }

  private static func repaint(promptRows: Int) {
    guard let size, var content = transcript else { return }
    // Leave the final column unused to avoid pending terminal autowrap.
    var rows = content.rows(width: size.columns - 1)
    let reserved = min(max(0, promptRows), size.rows - 2)
    let height = size.rows - 1 - reserved
    // A trailing empty line is the editor's insertion point, not transcript.
    if reserved > 0, rows.last == "\u{001B}[0m" { rows.removeLast() }
    content.scrollOffset = min(max(0, content.scrollOffset), max(0, rows.count - height))
    transcript = content
    let end = rows.count - content.scrollOffset
    let visible = Array(rows[max(0, end - height)..<end])
    let padding = height - visible.count
    var output = "\u{001B}[0m\u{001B}[1;\(size.rows - 1)r"
    if let footer {
      output += "\u{001B}[\(size.rows);1H\u{001B}[2K\u{001B}[90m"
      output += footer.text(width: size.columns) + "\u{001B}[0m"
    }
    for row in 0..<(size.rows - 1) {
      output += "\u{001B}[\(row + 1);1H\u{001B}[2K"
      let index = row - padding
      if row < height, index >= 0, index < visible.count { output += visible[index] }
    }
    if reserved > 0 {
      output += "\u{001B}[\(height + 1);1H"
    } else {
      // Streaming resumes at the end of the retained last row.
      output += "\u{001B}[\(height);1H" + (visible.last ?? "")
    }
    write(output)
  }

  static func write(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    Swift.print(text, terminator: "")
    fflush(stdout)
  }
}

func terminalPrint(_ text: String = "", terminator: String = "\n") {
  AgentTerminal.output(text + terminator)
}

struct AgentStatusSnapshot {
  var phase = "Ready"
  var tokensPerSecond: Double?
  var memoryBytes: UInt64?
  var contextTokens = 0
  var maxContext = 0
  var reservedOutputTokens = 0
  var droppedContextMessages = 0
  var modelLabel = ""

  func text(width: Int) -> String {
    let rate =
      tokensPerSecond.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.1f", $0) : nil } ?? "--"
    let memory = memoryBytes.map { String(format: "%.2f GiB", Double($0) / 1_073_741_824) } ?? "--"
    let percent =
      maxContext > 0
      ? min(999, max(0, Int((Double(contextTokens) / Double(maxContext) * 100).rounded()))) : 0
    var context = "ctx \(contextTokens)/\(maxContext) (\(percent)%)"
    if reservedOutputTokens > 0 { context += " +\(reservedOutputTokens) out" }
    if droppedContextMessages > 0 { context += " | drop \(droppedContextMessages)" }
    // Leave the last column unused to avoid automatic line wrapping.
    let maxWidth = max(0, width - 1)
    let right = modelLabel.isEmpty ? "" : "\(modelLabel) "
    let candidates = [
      " \(phase) | \(rate) tok/s | RAM \(memory) | \(context)",
      " \(phase) | \(rate) tok/s | \(context)",
      " \(phase) | ctx \(percent)%",
    ]
    for left in candidates {
      let gap = maxWidth - left.count - right.count
      if right.isEmpty, left.count <= maxWidth { return left }
      if !right.isEmpty, gap >= 1 {
        return left + String(repeating: " ", count: gap) + right
      }
    }
    return String(candidates.last!.prefix(maxWidth))
  }
}

/// Reserves the last terminal row so readline wrapping and streamed output
/// scroll above the status line. No cursor controls are emitted to pipes.
final class AgentStatusLine {
  var snapshot = AgentStatusSnapshot()
  private var active = false
  private var rows = 0
  private var lastDraw = -Double.infinity
  private var firstTokenTime: Double?

  private var terminalSize: (rows: Int, columns: Int)? {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
      ProcessInfo.processInfo.environment["TERM"] != "dumb"
    else { return nil }
    var size = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0,
      size.ws_row >= 3, size.ws_col >= 2
    else { return nil }
    return (Int(size.ws_row), Int(size.ws_col))
  }

  func start(maxContext: Int) {
    snapshot.maxContext = maxContext
    guard terminalSize != nil else { return }
    // exit(1), used by the agent's double-Ctrl-C handler, bypasses defer.
    atexit {
      AgentTerminal.write("\u{001B}[r\u{001B}[0m\n")
    }
    active = true
    refresh(force: true)
  }

  func stop() {
    guard active else { return }
    active = false
    // Restore the full scrolling region and leave a clean shell prompt row.
    AgentTerminal.write("\u{001B}[r\u{001B}[\(rows);1H\u{001B}[2K")
  }

  func preparePrompt() {
    snapshot.phase = "Ready"
    refresh(force: true)
    if active {
      AgentTerminal.write("\u{001B}[\(rows - 1);1H\u{001B}[2K")
    }
  }

  func beginGeneration(contextTokens: Int) {
    snapshot.phase = "Prefill"
    snapshot.contextTokens = contextTokens
    snapshot.tokensPerSecond = nil
    firstTokenTime = nil
    refresh(force: true)
  }

  func setContextBudget(_ budget: AgentContextBudget) {
    snapshot.contextTokens = budget.promptTokens
    snapshot.maxContext = budget.contextLimit
    snapshot.reservedOutputTokens = budget.reservedOutputTokens
    snapshot.droppedContextMessages = budget.droppedMessageCount
    refresh(force: true)
  }

  func prefill(done: Int) {
    snapshot.contextTokens = done
    refresh()
  }

  func token(count: Int, contextTokens: Int) {
    let now = ProcessInfo.processInfo.systemUptime
    if firstTokenTime == nil { firstTokenTime = now }
    snapshot.phase = "Decoding"
    snapshot.contextTokens = contextTokens
    // First token includes prefill: use subsequent token intervals for live rate.
    if count > 1, let start = firstTokenTime, now > start {
      snapshot.tokensPerSecond = Double(count - 1) / (now - start)
    }
    refresh()
  }

  func finish(tokens: Int, decodeSeconds: Double, contextTokens: Int) {
    snapshot.phase = "Ready"
    snapshot.tokensPerSecond = decodeSeconds > 0 ? Double(tokens) / decodeSeconds : nil
    snapshot.contextTokens = contextTokens
    refresh(force: true)
  }

  func refresh(force: Bool = false) {
    guard active, let size = terminalSize else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastDraw >= 0.25 || rows != size.rows else { return }
    lastDraw = now
    snapshot.memoryBytes = Self.processFootprint()
    AgentTerminal.rememberFooter(snapshot)
    var output = ""
    if rows != size.rows {
      rows = size.rows
      output += "\u{001B}[1;\(rows - 1)r\u{001B}[\(rows - 1);1H"
    }
    output += "\u{001B}7\u{001B}[\(rows);1H\u{001B}[2K\u{001B}[90m"
    output += snapshot.text(width: size.columns)
    output += "\u{001B}[0m\u{001B}8"
    AgentTerminal.write(output)
  }

  private static func processFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
  }
}

import Foundation

/// Terminal-only input and progress presentation. ACP never constructs this.
final class TerminalGeneration: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  private var hasText = false
  private var waitingForSecondCtrlC = false
  private var originalTermios = termios()
  private var originalFlags: Int32 = 0
  private var keyboard: DispatchSourceRead?
  private var spinner: Task<Void, Never>?
  private let cancellation: AgentCancellation

  init(cancellation: AgentCancellation) {
    self.cancellation = cancellation
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return }
    tcgetattr(STDIN_FILENO, &originalTermios)
    var raw = originalTermios
    raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG | IEXTEN)
    raw.c_cc.16 = 1
    raw.c_cc.17 = 0
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    originalFlags = fcntl(STDIN_FILENO, F_GETFL, 0)
    _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags | O_NONBLOCK)
    let keyboard = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
    keyboard.setEventHandler { [weak self] in self?.readKeys() }
    self.keyboard = keyboard
    keyboard.resume()
    startSpinner()
  }

  func beginGeneration() {
    let shouldStart = lock.withLock {
      guard keyboard != nil, !cancellation.isCancelled else { return false }
      hasText = false
      return true
    }
    if shouldStart {
      startSpinner()
    }
  }

  private func startSpinner() {
    spinner?.cancel()
    spinner = Task { [weak self] in
      let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
      var index = 0
      while let self, !Task.isCancelled {
        let drawn = self.lock.withLock {
          guard self.active, !self.hasText, !self.cancellation.isCancelled else { return false }
          AgentTerminal.write(
            "\r\u{001B}[34m\(frames[index % frames.count]) Thinking...\u{001B}[0m\u{001B}[K")
          return true
        }
        if !drawn { break }
        index += 1
        do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
      }
    }
  }

  private func readKeys() {
    while let key = nextKey() {
      if key == .toggleTools {
        lock.withLock {
          waitingForSecondCtrlC = false
          flushThoughtIfNeeded()
          AgentTerminal.navigate(0, promptRows: 0)
        }
      } else if key == .interrupt {
        let exitNow = lock.withLock {
          let previous = waitingForSecondCtrlC
          waitingForSecondCtrlC = true
          active = false
          return previous
        }
        if exitNow {
          restore()
          exit(1)
        }
        terminalPrint("\n[Press ctrl-c again to exit]")
        cancellation.cancel()
      } else if key == .stop {
        let shouldNotify = lock.withLock {
          let wasActive = active
          active = false
          return wasActive
        }
        cancellation.cancel()
        if shouldNotify {
          terminalPrint("\n[Generation Stopped (ESC)]")
        }
      } else {
        lock.withLock { waitingForSecondCtrlC = false }
      }
    }
  }

  private func nextKey() -> TerminalGenerationKey? {
    guard let byte = nextByte() else { return nil }
    var bytes = [byte]
    if byte == 27 {
      // Distinguish standalone Escape from enhanced keyboard sequences.
      // poll also handles a sequence split across DispatchSource events.
      while bytes.count < 32 {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 30) > 0, let next = nextByte() else { break }
        bytes.append(next)
        if bytes.count == 2 && next != 91 && next != 79 { break }
        if bytes.count > 2 && (64...126).contains(next) { break }
      }
    }
    return TerminalGenerationKey.decode(bytes)
  }

  private func nextByte() -> UInt8? {
    lock.withLock {
      guard keyboard != nil else { return nil }
      var byte: UInt8 = 0
      return read(STDIN_FILENO, &byte, 1) > 0 ? byte : nil
    }
  }

  private var thoughtBuffer = ""
  private var thoughtFlushed = false

  func thought(_ text: String) {
    lock.withLock {
      thoughtBuffer += text
    }
  }

  private func flushThoughtIfNeeded() {
    guard !thoughtBuffer.isEmpty else { return }
    let text = thoughtBuffer
    thoughtBuffer = ""
    thoughtFlushed = true
    if keyboard != nil { AgentTerminal.write("\r\u{001B}[K") }
    AgentTerminal.thought(text)
  }

  func text(_ text: String) {
    lock.withLock {
      flushThoughtIfNeeded()
      if !hasText, keyboard != nil { AgentTerminal.write("\r\u{001B}[K") }
      hasText = true
      terminalPrint(TerminalText.safe(text), terminator: "")
    }
  }

  func finishGeneration() async {
    spinner?.cancel()
    await spinner?.value
    lock.withLock {
      flushThoughtIfNeeded()
      if hasText {
        terminalPrint("")
      } else if keyboard != nil {
        AgentTerminal.write("\r\u{001B}[K")
      }
      hasText = false
    }
  }

  func finish() async {
    await finishGeneration()
  }

  func restore() {
    spinner?.cancel()
    lock.withLock {
      guard let keyboard else { return }
      keyboard.cancel()
      self.keyboard = nil
      active = false
      if cancellation.isCancelled {
        tcflush(STDIN_FILENO, TCIFLUSH)
      }
      _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags)
      tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
    }
  }
}

enum TerminalGenerationKey {
  case toggleTools, interrupt, stop, ignored

  static func decode(_ bytes: [UInt8]) -> Self {
    switch String(decoding: bytes, as: UTF8.self) {
    case "\u{0F}", "\u{001B}[111;5u", "\u{001B}[27;5;111~": return .toggleTools
    case "\u{03}", "\u{001B}[99;5u", "\u{001B}[27;5;99~": return .interrupt
    case "\u{001B}", "\u{001B}[27u": return .stop
    default: return .ignored
    }
  }
}

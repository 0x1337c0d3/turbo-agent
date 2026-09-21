#!/usr/bin/env python3
"""Model-free PTY checks of the real Swift transcript and libedit integration."""
import fcntl
import os
from pathlib import Path
import re
import select
import runpy
import struct
import time
import subprocess
import tempfile
import termios
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
Terminal = runpy.run_path(str(ROOT / 'Scripts/test-agent-editor.py'))['Terminal']

HARNESS = r'''
import Foundation
import Darwin
struct AgentContextBudget {
    let contextLimit: Int
    let promptTokens: Int
    let reservedOutputTokens: Int
    let droppedMessageCount: Int
}
final class AgentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
func checkGeneration() async {
    let cancellation = AgentCancellation()
    let generation = TerminalGeneration(cancellation: cancellation)
    generation.text("STREAMING_BEGIN")
    while !cancellation.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    await generation.finish()
    generation.restore()
    terminalPrint("GENERATION_FINISHED")
}
setlocale(LC_CTYPE, "")
let status = AgentStatusLine()
status.start(maxContext: 1000)
AgentTerminal.beginTranscript()
let long = CommandLine.arguments[1].contains("long-output")
let result = long ? (0..<60).map { "OUTPUT_LINE_\($0)" }.joined(separator: "\n")
                  : "PREVIEW\nEXPANDED_PAYLOAD\nmore details"
AgentTerminal.toolResult(header: "example_tool()", result: result, limit: 7)
terminalPrint("Assistant answer")
if CommandLine.arguments[1].contains("generation") {
    Task {
        await checkGeneration()
        status.stop()
        exit(0)
    }
    dispatchMain()
}
for _ in 0..<3 {
    terminalPrint("---")
    status.preparePrompt()
    guard let input = agent_read_prompt_with_transcript(
        "\u{01}\u{001B}[32m\u{01}> \u{01}\u{001B}[0m\u{01}", CommandLine.arguments[1],
        { action, rows in AgentTerminal.navigate(Int(action), promptRows: Int(rows)) ? 1 : 0 }
    ) else { exit(1) }
    let value = String(cString: input)
    free(input)
    AgentTerminal.recordPrompt(value)
    terminalPrint("RESULT:" + value.utf8.map { String(format: "%02x", $0) }.joined())
}
AgentTerminal.endTranscript()
status.stop()
'''


class Screen:
    """Small VT screen oracle for the cursor/erase commands used by this UI."""
    def __init__(self, rows=24, columns=80):
        self.rows, self.columns = rows, columns
        self.lines = [[' '] * columns for _ in range(rows)]
        self.row = self.column = 0
        self.top, self.bottom = 0, rows - 1
        self.saved = (0, 0)

    def newline(self):
        if self.row == self.bottom:
            self.lines.pop(self.top)
            self.lines.insert(self.bottom, [' '] * self.columns)
        else:
            self.row = min(self.rows - 1, self.row + 1)

    def feed(self, data):
        text = data.decode('utf-8', errors='replace')
        index = 0
        while index < len(text):
            ch = text[index]
            index += 1
            if ch == '\x1b':
                if index == len(text):
                    break
                ch = text[index]
                index += 1
                if ch == '[':
                    match = re.match(r'([0-9;?><]*)([@-~])', text[index:])
                    if not match:
                        raise AssertionError(repr(text[index:]))
                    index += len(match[0])
                    raw, command = match.groups()
                    args = [int(x or '0') for x in raw.split(';')] if not any(x in raw for x in '?><') else [0]
                    n = args[0] or 1
                    if command in ('H', 'f'):
                        self.row = min(self.rows - 1, n - 1)
                        self.column = min(self.columns - 1, (args[1] or 1) - 1 if len(args) > 1 else 0)
                    elif command == 'A': self.row = max(0, self.row - n)
                    elif command == 'B': self.row = min(self.rows - 1, self.row + n)
                    elif command == 'C': self.column = min(self.columns - 1, self.column + n)
                    elif command == 'D': self.column = max(0, self.column - n)
                    elif command == 'G': self.column = n - 1
                    elif command == 'K':
                        start = 0 if args[0] in (1, 2) else self.column
                        end = self.columns if args[0] in (0, 2) else self.column + 1
                        self.lines[self.row][start:end] = [' '] * (end - start)
                    elif command == 'J':
                        if args[0] == 2:
                            self.lines = [[' '] * self.columns for _ in range(self.rows)]
                        else:
                            self.lines[self.row][self.column:] = [' '] * (self.columns - self.column)
                            for row in range(self.row + 1, self.rows): self.lines[row] = [' '] * self.columns
                    elif command == 'r':
                        self.top = n - 1
                        self.bottom = args[1] - 1 if len(args) > 1 else self.rows - 1
                        self.row = self.column = 0
                elif ch == '7': self.saved = (self.row, self.column)
                elif ch == '8': self.row, self.column = self.saved
                continue
            if ch == '\r': self.column = 0
            elif ch == '\n': self.newline()
            elif ch == '\b': self.column = max(0, self.column - 1)
            elif ch == '\t': self.column = min(self.columns - 1, (self.column // 8 + 1) * 8)
            elif ord(ch) >= 32:
                if unicodedata.combining(ch): continue
                width = 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1
                if self.column + width > self.columns:
                    self.column = 0
                    self.newline()
                self.lines[self.row][self.column] = ch
                self.column += width

    @property
    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.lines)


class TranscriptTerminal(Terminal):
    def __init__(self, *args):
        super().__init__(*args)
        self.screen = Screen()

    def read_until(self, marker):
        output = super().read_until(marker)
        self.screen.feed(output)
        return output

    def send(self, data):
        # Feed large drafts while draining echo, avoiding PTY backpressure.
        flags = fcntl.fcntl(self.master, fcntl.F_GETFL)
        fcntl.fcntl(self.master, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        deadline = time.monotonic() + 10
        try:
            while data:
                if time.monotonic() >= deadline:
                    raise AssertionError("Timed out sending terminal input")
                readable, writable, _ = select.select([self.master], [self.master], [], 0.1)
                if readable:
                    self.buffer += os.read(self.master, 65536)
                if writable:
                    try:
                        data = data[os.write(self.master, data[:128]):]
                    except BlockingIOError:
                        pass
        finally:
            fcntl.fcntl(self.master, fcntl.F_SETFL, flags)

    def redraw(self, keys):
        self.send(keys)
        # Transcript repaint begins here; the next prompt belongs to EL_REFRESH.
        self.read_until(b'\x1b[1;1H')
        self.read_until(b'> ')
        # A round-trip edit forces us to consume the rest of the prompt refresh.
        os.write(self.master, b'\x05~')
        self.read_until(b'~')
        os.write(self.master, b'\x7f')


def main():
    cases = [
        ('plain Ctrl-O', b'abc\x02', b'\x0f', 'ab!c'),
        ('CSI-u Ctrl-O', b'abc\x02', b'\x1b[111;5u', 'ab!c'),
        ('xterm Ctrl-O', b'abc\x02', b'\x1b[27;5;111~', 'ab!c'),
        ('multiline cursor', b'abc\ndef\x1b[A', b'\x0f', 'abc!\ndef'),
        ('Unicode draft', 'café猫\n🙂tail\x01'.encode(), b'\x0f', 'café猫\n!🙂tail'),
        ('wrapped draft', b'x' * 170, b'\x0f', 'x' * 170 + '!'),
        ('empty draft', b'', b'\x0f', '!'),
        ('draft taller than screen', b'x' * 2400, b'\x0f', 'x' * 2400 + '!'),
    ]
    with tempfile.TemporaryDirectory(prefix='agent-transcript-') as directory:
        directory = Path(directory)
        source = directory / 'main.swift'
        source.write_text(HARNESS)
        editor = directory / 'editor.o'
        include = ROOT / 'Sources/AgentLineEditor/include'
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', '-I', str(include), '-c',
                        str(ROOT / 'Sources/AgentLineEditor/AgentLineEditor.c'), '-o', str(editor)], check=True)
        executable = directory / 'transcript'
        subprocess.run(['swiftc', '-module-cache-path', str(directory / 'module-cache'),
                        '-import-objc-header', str(include / 'AgentLineEditor.h'),
                        str(ROOT / 'Sources/TurboFieldfareAgent/Terminal/TerminalText.swift'),
                        str(ROOT / 'Sources/TurboFieldfareAgent/Terminal/TerminalTranscript.swift'),
                        str(ROOT / 'Sources/TurboFieldfareAgent/Terminal/StatusLine.swift'),
                        str(ROOT / 'Sources/TurboFieldfareAgent/Terminal/TerminalGeneration.swift'),
                        str(source), str(editor), '-ledit', '-o', str(executable)], check=True)
        for number, (name, draft, toggle, expected) in enumerate(cases):
            terminal = TranscriptTerminal(executable, directory / f'history-{number}')
            try:
                terminal.read_until(b'> ')
                assert 'EXPANDED_PAYLOAD' not in terminal.screen.text
                terminal.send(draft + toggle)
                terminal.read_until(b'\x1b[1;1H')
                if name != 'draft taller than screen':
                    terminal.read_until(b'> ')
                if name != 'draft taller than screen':
                    assert 'EXPANDED_PAYLOAD' in terminal.screen.text, terminal.screen.text
                if name != 'draft taller than screen':
                    assert 'Assistant answer' in terminal.screen.text
                assert 'Ready |' in ''.join(terminal.screen.lines[-1])
                # Repeated toggles must neither submit nor move the insertion point.
                terminal.send(toggle)
                terminal.read_until(b'\x1b[1;1H')
                if name != 'draft taller than screen':
                    terminal.read_until(b'> ')
                assert 'EXPANDED_PAYLOAD' not in terminal.screen.text, terminal.screen.text
                terminal.send(b'!\r')
                terminal.read_until(b'RESULT:')
                actual = terminal.read_until(b'\r\n').strip()
                assert actual == expected.encode().hex().encode(), (name, actual, expected)
                terminal.submit(b'next', 'next')
                terminal.submit(b'last', 'last')
                assert terminal.process.wait(timeout=5) == 0
                assert termios.tcgetattr(terminal.master) == terminal.original_mode
                print(f'PASS: {name}: in-place expand/collapse, draft, footer, terminal restoration', flush=True)
            finally:
                terminal.close()
        terminal = TranscriptTerminal(executable, directory / 'long-output')
        try:
            terminal.read_until(b'> ')
            terminal.redraw(b'\x0f')
            assert 'OUTPUT_LINE_59' in terminal.screen.text
            assert 'OUTPUT_LINE_0\n' not in terminal.screen.text
            for _ in range(3):
                terminal.redraw(b'\x1b[5~')
            assert 'OUTPUT_LINE_0' in terminal.screen.text, terminal.screen.text
            terminal.send(b'\x1b[6~\x1b[6~\x1b[6~\r')
            terminal.read_until(b'RESULT:')
            terminal.read_until(b'\r\n')
            terminal.submit(b'next', 'next')
            terminal.submit(b'last', 'last')
            assert terminal.process.wait(timeout=5) == 0
            print('PASS: long expanded output is accessible by paging without leaving the transcript')
        finally:
            terminal.close()
        for number, key in enumerate([b'\x0f', b'\x1b[111;5u', b'\x1b[27;5;111~']):
            terminal = TranscriptTerminal(executable, directory / f'generation-{number}')
            try:
                terminal.read_until(b'STREAMING_BEGIN')
                # Enhanced encodings can arrive in separate input events.
                terminal.send(key[:1])
                if len(key) > 1:
                    time.sleep(0.005)
                    terminal.send(key[1:])
                terminal.read_until(b'[ctrl+o to collapse]')
                assert 'EXPANDED_PAYLOAD' in terminal.screen.text, terminal.screen.text
                terminal.send(key)
                terminal.read_until(b'(ctrl+o to expand)')
                assert 'EXPANDED_PAYLOAD' not in terminal.screen.text, terminal.screen.text
                terminal.send(b'\x1b')
                terminal.read_until(b'GENERATION_FINISHED')
                assert terminal.process.wait(timeout=5) == 0
                assert termios.tcgetattr(terminal.master) == terminal.original_mode
                print(f'PASS: generation shortcut {number + 1}, expand/collapse, Escape, terminal restoration')
            finally:
                terminal.close()
        terminal = TranscriptTerminal(executable, directory / 'resize')
        try:
            terminal.read_until(b'> ')
            terminal.send(b'resize draft')
            terminal.read_until(b'draft')
            fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack('HHHH', 18, 50, 0, 0))
            terminal.screen = Screen(18, 50)
            terminal.redraw(b'\x0f')
            assert 'EXPANDED_PAYLOAD' in terminal.screen.text, terminal.screen.text
            assert 'Ready |' in ''.join(terminal.screen.lines[-1])
            terminal.send(b'\r')
            terminal.read_until(b'RESULT:')
            assert terminal.read_until(b'\r\n').strip() == b'resize draft'.hex().encode()
            terminal.submit(b'next', 'next')
            terminal.submit(b'last', 'last')
            assert terminal.process.wait(timeout=5) == 0
            print('PASS: resize redraw preserves draft and moves footer')
        finally:
            terminal.close()
        pipe = subprocess.run([str(executable), str(directory / 'pipe')],
                              input=b'one\ntwo\nthree\n', capture_output=True, check=True)
        assert b'Ctrl-O' not in pipe.stdout
        assert b'\x1b[1;1H' not in pipe.stdout
        assert b'EXPANDED_PAYLOAD' not in pipe.stdout
        print('PASS: piped input retains compact output and emits no redraw controls')
    print(f'{len(cases) + 6} transcript PTY/pipe checks passed.')


if __name__ == '__main__':
    main()

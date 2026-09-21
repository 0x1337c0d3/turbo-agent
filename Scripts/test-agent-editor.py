#!/usr/bin/env python3
"""Model-free PTY regressions for the native REPL editor (macOS + clang)."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent.parent
HARNESS = r'''
#include "AgentLineEditor.h"
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    (void)argc;
    setlocale(LC_ALL, "");
    // Match the app's scrolling region and prompt position above its footer.
    fputs("\033[1;23r\033[23;1H", stdout);
    for (int i = 0; i < 3; i++) {
        char *input = agent_read_prompt("\001\033[32m\001> \001\033[0m\001", argv[1]);
        if (!input) return 1;
        fputs("RESULT:", stdout);
        for (unsigned char *p = (unsigned char *)input; *p; p++) printf("%02x", *p);
        fputs("\n", stdout);
        fflush(stdout);
        free(input);
    }
    fputs("\033[r", stdout);
    return 0;
}
'''


class Terminal:
    def __init__(self, executable, history):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.original_mode = termios.tcgetattr(slave)
        self.buffer = b""

        def attach_terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen(
            [str(executable), str(history)], stdin=slave, stdout=slave, stderr=slave,
            preexec_fn=attach_terminal, env=dict(os.environ, TERM="xterm-256color"),
        )
        os.close(slave)

    def read_until(self, marker):
        deadline = time.monotonic() + 10
        while marker not in self.buffer:
            if time.monotonic() >= deadline:
                raise AssertionError(f"Missing {marker!r}: {self.buffer!r}")
            if not select.select([self.master], [], [], 0.1)[0]:
                continue
            chunk = os.read(self.master, 65536)
            if not chunk:
                raise AssertionError("Unexpected terminal EOF")
            self.buffer += chunk
        end = self.buffer.index(marker) + len(marker)
        output, self.buffer = self.buffer[:end], self.buffer[end:]
        return output

    def submit(self, keys, expected):
        self.read_until(b"> ")
        os.write(self.master, keys + b"\r")
        self.read_until(b"RESULT:")
        actual = self.read_until(b"\r\n").strip()
        assert actual == expected.encode().hex().encode(), (actual, expected)

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait()
        os.close(self.master)


def main():
    cases = [
        ("Ctrl+C clears draft", b"discard me\x03fresh", "fresh"),
        ("Ctrl+C clears multiline draft", b"abc\ndef\x1b[A\x03fresh", "fresh"),
        ("CSI-u Ctrl+C clears draft", b"discard\x1b[99;5ufresh", "fresh"),
        ("xterm Ctrl+C clears draft", b"discard\x1b[27;5;99~fresh", "fresh"),
        ("Ctrl+A/E single line", b"abc\x01!\x05?", "!abc?"),
        ("xterm Ctrl+A/E", b"abc\x1b[27;5;97~!\x1b[27;5;101~?", "!abc?"),
        ("Ctrl+A/E empty line", b"abc\n\x01\x05!", "abc\n!"),
        ("CSI-u Ctrl+A/E", b"abc\x1b[97;5u!\x1b[101;5u?", "!abc?"),
        ("Ctrl+A/E current line", b"abc\ndef\x01!\x05?", "abc\n!def?"),
        ("Ctrl+E on first line", b"abc\ndef\x1b[A\x01!\x05?", "!abc?\ndef"),
        ("Ctrl+A/E Unicode", "abc\ncafé猫\x01!\x05?".encode(), "abc\n!café猫?"),
        ("CSI-u Shift+Enter", b"abc\x1b[13;2udef", "abc\ndef"),
        ("xterm Shift+Enter", b"abc\x1b[27;2;13~def", "abc\ndef"),
        ("Ctrl+J", b"abc\ndef", "abc\ndef"),
        ("up edits previous line", b"abc\ndef\x1b[A!", "abc!\ndef"),
        ("down edits next line", b"abc\ndef\x1b[A\x1b[B!", "abc\ndef!"),
        ("nonempty boundary preserves draft", b"draft\x1b[A\x1b[B!", "draft!"),
        ("empty prompt recalls history", b"\x1b[A", "previous command"),
        ("repeated Up browses history", b"\x1b[A\x1b[A", "older command"),
        ("Down browses newer history", b"\x1b[A\x1b[A\x1b[B", "previous command"),
        ("cursor motion keeps history browsing", b"\x1b[A\x01\x05\x1b[A", "older command"),
        ("typing ends history browsing", b"\x1b[A!\x1b[A", "previous command!"),
        ("deleting ends history browsing", b"\x1b[A\x7f\x1b[A", "previous comman"),
        ("reverted edit still ends browsing", b"\x1b[A!\x7f\x1b[A", "previous command"),
        ("newline edit switches to line motion", b"\x1b[A\nnext\x1b[A!", "prev!ious command\nnext"),
        ("Ctrl+C resets history browsing", b"draft\x03\x1b[A\x1b[A", "older command"),
        ("application-mode arrows", b"abc\ndef\x1bOA!\x1bOB?", "abc!\ndef?"),
        ("Unicode and short lines", "café\n猫\x1b[A!".encode(), "c!afé\n猫"),
        ("wrapped line preserved", b"x" * 180 + b"\ntail\x1b[A!", "xxxx!" + "x" * 176 + "\ntail"),
        ("trailing newline preserved", b"abc\n", "abc\n"),
    ]
    with tempfile.TemporaryDirectory(prefix="agent-editor-") as directory:
        directory = Path(directory)
        harness = directory / "main.c"
        harness.write_text(HARNESS)
        executable = directory / "editor"
        subprocess.run([
            "clang", "-Wall", "-Wextra", "-Werror",
            "-I", str(ROOT / "Sources/AgentLineEditor/include"),
            str(ROOT / "Sources/AgentLineEditor/AgentLineEditor.c"),
            str(harness), "-ledit", "-o", str(executable),
        ], check=True)
        for number, (name, keys, expected) in enumerate(cases):
            terminal = Terminal(executable, directory / f"history-{number}")
            try:
                terminal.submit(b"older command", "older command")
                terminal.submit(b"previous command", "previous command")
                terminal.submit(keys, expected)
                terminal.read_until(b"\x1b[r")
                assert terminal.process.wait(timeout=5) == 0
                restored = termios.tcgetattr(terminal.master)
                assert restored == terminal.original_mode, "Terminal mode was not restored"
                print(f"PASS: {name}", flush=True)
            finally:
                terminal.close()
        terminal = Terminal(executable, directory / "double-cancel-history")
        try:
            terminal.read_until(b"> ")
            os.write(terminal.master, b"discard this\x03")
            terminal.read_until(b"Prompt cleared.")
            terminal.read_until(b"> ")
            os.write(terminal.master, b"\x03")
            terminal.read_until(b"Force Exited by User")
            assert terminal.process.wait(timeout=5) == 1  # Harness reports EOF.
            assert termios.tcgetattr(terminal.master) == terminal.original_mode
            assert not (directory / "double-cancel-history").exists()
            print("PASS: double Ctrl+C exits, restores terminal, and saves no draft")
        finally:
            terminal.close()
    print(f"{len(cases) + 1} terminal editor checks passed.")


if __name__ == "__main__":
    main()

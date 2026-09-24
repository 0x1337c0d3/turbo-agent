# Ctrl-O TUI redraw fix plan

## Goal

Make Ctrl-O reliably switch every retained tool result and thinking block between
its compact and expanded representation in the interactive terminal. The redraw
must leave the final on-screen transcript, prompt draft, insertion point, paging
position, and status footer consistent at both the prompt and during generation.
Piped output, `TERM=dumb`, ACP, and the messages sent to the model must remain
unchanged.

## Current implementation and likely failure boundary

The retained presentation state is owned by `TerminalTranscript`. Ctrl-O reaches
that state through two input paths:

- At the prompt, `AgentLineEditor.c` calculates the draft height, invokes
  `AgentTerminal.navigate`, and asks libedit to refresh its prompt afterward.
- During generation, `TerminalGeneration` decodes Ctrl-O and invokes the same
  navigation entry point with no prompt rows reserved.

`AgentTerminal.repaint` then renders the transcript with absolute cursor
positioning while libedit remains responsible for repainting the editable
prompt. This split ownership is the critical boundary: changing
`TerminalTranscript.expanded` is not sufficient if the repaint uses stale
geometry, restores the wrong cursor position, duplicates the last transcript
row, or lets libedit erase part of the newly rendered viewport.

The existing tests prove that the transcript model can produce expanded rows and
that expected escape sequences are emitted. Before implementing a fix, the PTY
test must also reproduce the reported failure in its final emulated screen. This
will distinguish a state/rendering defect from a terminal/libedit sequencing
defect and prevent a byte-stream assertion from masking an incorrect display.

## Implementation plan

### 1. Capture a failing redraw as a regression test

Extend `Scripts/test-agent-transcript.py` with the smallest real interaction
that fails in the application:

1. Render at least two tool calls separated by ordinary assistant text so the
   test verifies that all retained entries are rebuilt, not only the newest one.
2. Type a multiline or wrapped draft and leave the insertion point away from
   the end.
3. Press Ctrl-O, consume the complete libedit refresh, and assert against the
   final emulated screen rather than merely waiting for an expansion marker in
   the output stream.
4. Press Ctrl-O again and assert that the full result text is absent, compact
   hints are present, stale expanded rows were cleared, the draft and cursor are
   restored, and the footer occupies the last row.
5. Repeat with output taller than the viewport and with Ctrl-O during active
   generation.

Update the `Screen` oracle as needed to model every control sequence emitted by
the production redraw. Record the cursor position as part of assertions. Avoid
special-casing the failing fixture; the oracle should describe terminal
semantics shared by all cases.

### 2. Give one layer ownership of viewport composition

Refactor the repaint calculation in
`Sources/TurboAgent/Terminal/StatusLine.swift` into a deterministic operation
that takes terminal size, prompt row reservation, expansion state, and scroll
offset and returns a complete viewport description. It should calculate:

- the transcript rows produced at the current terminal width;
- the clamped scroll offset and visible transcript slice;
- all rows that must be erased when expanded content shrinks;
- the prompt origin when an editor is active;
- the streaming continuation position when generation is active; and
- the footer row and text.

Keep `TerminalTranscript` as retained semantic content rather than a record of
previous screen coordinates. A toggle should mutate `expanded`, reset paging to
the latest output, render all retained entries from that state, and perform one
serialized repaint while holding the existing terminal lock.

Do not append the visible last row merely to position the cursor. Cursor
placement and content emission should be separate operations; otherwise the
last row can be duplicated and later streaming output can diverge from the
retained transcript.

### 3. Make the libedit redraw handshake explicit

Update `Sources/AgentLineEditor/AgentLineEditor.c` and its public callback
contract so a successful transcript repaint has a single defined sequence:

1. Snapshot the complete edit buffer, logical insertion offset, and rendered
   prompt height before calling Swift.
2. Let Swift repaint the transcript and leave the cursor at the calculated
   prompt origin.
3. Force one full libedit redisplay from that new origin, without allowing
   libedit's old display coordinates to clear transcript rows.
4. Restore the logical insertion point and confirm wrapped and multiline drafts
   calculate the same number of reserved rows in C and Swift.

If libedit cannot safely forget its previous display geometry through the
public API, add a narrowly scoped editor helper that clears/redraws the prompt
within the reserved prompt area. Do not depend on undocumented ordering between
`EL_REFRESH`, a command return code, and the next input event.

Preserve the existing plain Ctrl-O, CSI-u, and xterm key bindings and keep
`VDISCARD` disabled while editing.

### 4. Cover the renderer at unit level

Add focused tests under `Tests/TurboAgent/` for the extracted viewport
composition and retain the existing `TerminalTranscriptTests` for semantic
rendering. Cover:

- expand, collapse, and repeated toggles across multiple tool/thought entries;
- content shorter than, equal to, and taller than the available viewport;
- narrow widths, Unicode, tabs, and wrapped lines;
- prompt reservations of zero, one, multiple, and nearly all usable rows;
- resize between toggles;
- clearing rows left behind when collapsing;
- scroll-offset clamping and reset-to-latest on toggle; and
- cursor destinations for prompt and generation modes.

Keep terminal-control output testable through an injected writer or a pure
render result so unit tests do not need a real TTY.

### 5. Verify lifecycle and concurrency behavior

Audit all writes during generation (`TerminalGeneration`, status refreshes,
thinking flushes, tool completion, and normal streamed text) to ensure they use
the same terminal serialization boundary. A Ctrl-O repaint must not interleave
with a spinner tick, footer refresh, or streamed token.

Confirm transcript initialization and teardown still occur only for an
interactive TTY. Confirm a new tool result follows the current expanded state,
submitting a prompt returns paging to the latest output, terminal resize uses
fresh geometry, and terminal modes plus the scrolling region are restored after
normal exit, Escape, Ctrl-C, and errors.

## Verification

Run the model-free checks required by `docs/AGENT_TERMINAL.md`:

```bash
Scripts/test.sh --filter 'TerminalTranscriptTests|StatusLineTests|SecurityTests|ACPExecutableTests'
python3 Scripts/test-agent-editor.py
python3 Scripts/test-agent-transcript.py
```

Also run `make test` after the targeted checks pass. Do not run
`make build-app` or a live AFM/OpenAI request; neither is needed to validate the
terminal renderer.

Perform a short manual check in at least the macOS Terminal configuration that
reported the bug, because libedit and terminal keyboard modes are part of the
failure boundary. Exercise Ctrl-O at an empty prompt, with a wrapped multiline
draft, while generation is active, after resizing, and after paging backward.

## Acceptance criteria

- One Ctrl-O changes all retained tool results and thinking blocks to their full
  representation on the final visible screen; the next Ctrl-O restores compact
  representations and removes every stale expanded row.
- The draft bytes, logical insertion point, prompt origin, and footer survive
  both transitions.
- Long expanded output can be reached with Page Up/Page Down, and toggling
  returns to the latest output.
- New tool results honor the active expanded/collapsed setting.
- Ctrl-O works through plain, CSI-u, and xterm encodings both at the prompt and
  during generation.
- No terminal control sequence from tool output is executed.
- Pipes, `TERM=dumb`, ACP output, conversation/model context, approval behavior,
  and terminal restoration do not change.
- The new regression fails before the implementation change and passes after
  it, alongside the complete model-free suite.

## Expected files

- `Sources/TurboAgent/Terminal/StatusLine.swift`
- `Sources/TurboAgent/Terminal/TerminalTranscript.swift` if the pure rendering
  boundary needs adjustment
- `Sources/AgentLineEditor/AgentLineEditor.c`
- `Sources/AgentLineEditor/include/AgentLineEditor.h` if the callback contract
  changes
- `Tests/TurboAgent/TerminalTranscriptTests.swift`
- a new viewport/repaint unit-test file under `Tests/TurboAgent/`
- `Scripts/test-agent-transcript.py`
- `docs/AGENT_TERMINAL.md` after the behavior is fixed and reverified

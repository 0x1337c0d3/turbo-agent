# Terminal tool responses

Before `write_file` or `edit_file` can modify the workspace, the approval view
shows a bounded unified diff of the proposed result. New files are compared with
`/dev/null`; unchanged writes are identified explicitly. Large previews are
truncated with an omission notice. The agent rechecks the source immediately
before writing and refuses the operation if it detects that the file changed
after preview. ACP and `AgentClient` approval requests carry the same preview.
In `--yolo` mode the terminal still displays the preview, but does not pause for
approval.

In the interactive `TurboAgent` terminal, **Ctrl-O** expands all retained
tool responses in place. Press it again to return to their compact previews
(normally 300 characters). The choice also applies to subsequent tool results.
The response shows a shortcut hint beside its output.

The shortcut works while editing a prompt and during generation. Your draft,
insertion point, and the status footer are preserved. At the prompt, **Page Up**
and **Page Down** browse the retained transcript, including expanded responses
longer than the terminal window. Toggling or submitting a prompt returns to the
latest output. Before the first tool response, these shortcuts do nothing.

Expansion shows the complete result returned by the tool; any limit imposed by
the tool itself still applies. It does not change the messages sent to the model.
ACP clients manage their own presentation. Piped input/output and `TERM=dumb`
keep the existing compact output without transcript navigation.

The agent repaints the visible transcript above the footer without opening a
separate view or clearing terminal scrollback. Existing terminal scrollback is
historical and cannot be rewritten; use Page Up/Page Down at the agent prompt to
browse the retained transcript with the current expansion setting.

## Large-file reads and range reads

`read_file` is revision-aware. A whole-file read that fits the tool-result
ceiling returns in a labeled envelope with the file path, SHA-256 digest, and
line count. A file that does not fit returns a deterministic outline of its
declarations plus a small initial excerpt, with explicit instructions to
request a range; the outline contains section names and line spans but no
source bodies. Requesting `start_line`/`end_line` returns only that slice,
labeled `complete="false"` with the actual range and the continuation line.
Range reads work identically when an ACP client supplies file contents: the
client read stays intact and slicing happens locally afterwards.

## Anchored edits and whole-file replacement

`edit_file` replaces one exact target string. The target must occur exactly
once unless the model explicitly passes `replace_all`; an ambiguous target
fails with guidance instead of silently editing several regions. Every edit
must carry `expected_digest` from a `read_file` of the file. A missing digest
fails as `revisionRequired`; a digest that does not match the file on disk
fails as `staleRevision` and asks for a fresh read. A no-op replacement is
reported without requesting a write. The approval view still shows a bounded
unified diff, the runtime rechecks the source immediately before writing, and
a successful edit returns the new revision digest so the next edit can anchor
on it.

`write_file` creates new files as before. Replacing an existing file
additionally requires a matching `expected_digest` and evidence that this
runtime read that exact revision completely: a range read, an outline, or a
compacted receipt never authorizes whole-file replacement, including in
`--yolo` mode. Rejected replacements explain the requirement and point at
`edit_file` or a complete read. Creation targets that appear while their diff
awaits approval are refused. Approval redacts `target`, `replacement`, and
`content` bodies from the argument block; the diff preview itself carries the
changes.

## Context budget footer

Before every inference request, the agent conservatively estimates the complete
prompt, including instructions, advertised tool schemas, conversation messages,
and Continuity bootstrap. It reserves output capacity and a tokenizer safety
margin before submitting the request. If necessary, complete oldest turns are
omitted from that request; the full transcript remains available to the session.
The newest user turn and its system instructions are never silently dropped. If
they cannot fit, the request stops with an error instead of knowingly overflowing
the model context.

The footer reports estimated context use and percentage, reserved output, and
the number of messages omitted from the current request. Wider terminals also
show generation rate and process memory. AFM does not expose its tokenizer, so
its figures use a conservative UTF-8 estimate rather than claiming exact token
counts. The model label remains visible as the footer contracts on narrow
terminals.

## Copying responses

Enter `/copy` to copy the latest nonempty assistant answer to the macOS
clipboard as plain Markdown, preserving its original formatting. Tool calls,
tool output, and terminal decoration are excluded. The command reports when
there is no answer to copy or the clipboard write fails. It does not submit a
prompt to the model.

Verification for `/copy`: `swift build --target TurboAgent` exited 0
with `Build complete! (11.77 sec.)` on base commit
`199855c0bd523c7ce275d3227fd92cf8579910fc` plus local changes, Mac14,9 / Apple
M2 Pro / 32 GB RAM, macOS 26.6.2 (25G83), Apple Swift 6.4
(`swiftlang-6.4.0.34.1 clang-2100.3.34.1`). Existing Metal Sendable warnings
remain. The initial sandboxed build exited 1 with
`error opening '/Users/peter.johnson/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/peter.johnson/.cache/clang/ModuleCache: Operation not permitted`
and `unable to load standard library for target 'arm64-apple-macosx14.0'`;
the successful retry used approved compiler-cache access. No model was run;
clipboard interaction was not exercised. No model-run or benchmark protocol
applied, and no other protocol deviations occurred.

## Model-free checks

```bash
Scripts/test.sh --filter 'TerminalTranscriptTests|StatusLineTests|SecurityTests|ACPExecutableTests'
python3 Scripts/test-agent-editor.py
python3 Scripts/test-agent-transcript.py
```

The transcript script compiles the real Swift presentation and C editor into a
temporary harness. It exercises plain, CSI-u, and xterm Ctrl-O, multiline and
Unicode drafts, long output, generation input, terminal resizing, and pipes. It
does not load the model.

## Verification record — 2026-09-16

Base commit: `199855c0bd523c7ce275d3227fd92cf8579910fc`, with the local
Ctrl-O changes and pre-existing file-reference changes in the working tree.
Hardware: Mac14,9, Apple M2 Pro, 32 GiB RAM. macOS 26.6.2 (25G83).
Compiler: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`,
`clang-2100.3.34.1`), target `arm64-apple-macosx26.0`.

| Exact command | Exit | Completion footer |
| --- | --- | --- |
| `swift build --target TurboAgent` | 0 | `Build complete! (11.89 sec.)` |
| `Scripts/test.sh --filter 'TerminalTranscriptTests\|StatusLineTests\|SecurityTests'` | 0 | `Build complete! (15.81 sec.)`; `Executed 15 tests, with 0 failures (0 unexpected) in 0.007 (0.010) seconds` |
| `Scripts/test.sh --filter 'TerminalTranscriptTests\|StatusLineTests\|SecurityTests\|ACPExecutableTests'` | 0 | `Build complete! (6.05 sec.)`; `Executed 19 tests, with 0 failures (0 unexpected) in 1.034 (1.039) seconds` |
| `python3 Scripts/test-agent-editor.py` | 0 | `31 terminal editor checks passed.` |
| `python3 Scripts/test-agent-transcript.py` | 0 | `14 transcript PTY/pipe checks passed.` |

The final package-test timing footer was:

```text
Test Suite 'TurboAgentTests.xctest' passed at 2026-09-16 15:41:38.756.
     Executed 19 tests, with 0 failures (0 unexpected) in 1.034 (1.038) seconds
Test Suite 'Selected tests' passed at 2026-09-16 15:41:38.756.
     Executed 19 tests, with 0 failures (0 unexpected) in 1.034 (1.039) seconds
```

These are model-free functional checks, not performance measurements. No model
was loaded, installed, duplicated, or terminated. No runtime defaults or
experimental controls changed. Package tests used `Scripts/test.sh`; the PTY
scripts build temporary presentation/editor harnesses directly.

The first sandboxed build and package-test attempts each exited 1 because Swift
could not write its external compiler cache:

```text
error: error opening '/Users/peter.johnson/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/peter.johnson/.cache/clang/ModuleCache: Operation not permitted
error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

Both commands were rerun with approved cache access. The build reported existing
Metal `Sendable` warnings in `RealForwardRunner.swift`. The initial process-list
and hardware queries were sandbox-blocked; hardware was obtained with approved
read access. Model-run preflight and community benchmarks were not applicable.

During PTY-driver development, interim runs exited 1 for invalid Tab-input
fixtures and for assuming a prompt marker stays visible when the draft exceeds
the screen. The Tab fixture was removed (plain Tab is an editor command, not
literal insertion); layout-level Tab coverage remains. One oversized-input run
stalled on test-driver backpressure and was interrupted (exit 130), stopping only
its own temporary harness. The driver now drains output while feeding input,
and the oversized-draft check passes. No required checks remain failing.

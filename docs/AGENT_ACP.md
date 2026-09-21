# Use TurboFieldfareAgent in Zed or another ACP client

`TurboFieldfareAgent --acp` serves Agent Client Protocol v1 over stdin/stdout.
The terminal REPL remains the default when `--acp` is omitted. The ACP frontend
and REPL share the model runtime, conversation/tool loop, tools and skill loader.
For Ctrl-O expansion and transcript navigation in the REPL, see
[Terminal tool responses](AGENT_TERMINAL.md).

## Zed setup

Build the agent:

```bash
swift build -c release --product TurboFieldfareAgent
```

Add a custom agent to Zed's settings, replacing the executable path with the
absolute path to your checkout's built binary:

```json
{
  "agent_servers": {
    "TurboFieldfare": {
      "type": "custom",
      "command": "/absolute/path/to/turbo-agent/.build/release/TurboFieldfareAgent",
      "args": ["--acp"],
      "env": {}
    }
  }
}
```

Select **TurboFieldfare** when starting a thread in Zed's Agent Panel. Zed's
`dev: open acp logs` command shows protocol traffic for troubleshooting.
See [Zed's custom agent documentation](https://zed.dev/docs/ai/external-agents#custom-agents).

The existing defaults apply:

- Model: `~/Library/Application Support/TurboFieldfare/gemma4.gturbo`.
- Context capacity: 262144 tokens.
- Override with `"args": ["--acp", "--model", "/absolute/path/model.gturbo", "--max-context", "262144"]`.
- There is no agent account/login requirement. The model must already be installed.

Follow the repository's model-run checks before starting inference. Each ACP
process can load one model; separate editor windows/clients may start separate
processes. Do not run these alongside another model process on this checkout.
The model loads lazily on the first inference prompt. Initialization, session
creation, and `/skills` do not load it.

## Supported behavior

- Protocol version negotiation (`initialize`) and new conversations (`session/new`).
- Text, resource links, and embedded text resources in `session/prompt`.
  Links are included as references for the agent to read using tools; they are
  not silently fetched. Image/audio/binary content is rejected explicitly.
- Streamed assistant text and tool status/output notifications.
- UI permission requests before file, shell, URL and MCP tools. Only the explicit
  **Allow once** response authorizes an operation. Missing, rejected, failed or
  cancelled permission responses deny it. Delegated tasks inherit these checks.
- Client file reads/writes when advertised, allowing tools to use unsaved editor
  buffers. Otherwise, approved file tools operate on the local filesystem.
- `session/cancel` during generation, approvals, shell commands and MCP requests.
  Cancellation completes with `stopReason: "cancelled"`; late approval responses
  cannot authorize another turn.
- Per-session working directories, instructions, skill catalogs and MCP clients.
  Relative file paths and shell commands resolve against the session's project.
- Skill names published as ACP available commands. `/name request` loads the
  selected skill on demand; `/skills` lists them.
- Native MCP settings from `~/.config/TurboFieldfareAgent/settings.json`, merged
  with the client's `mcpServers`. Client entries take precedence by server name.
  Stdio and Streamable HTTP are supported; legacy SSE transport is rejected.
  The UI-launched agent must inherit environment variables referenced by native
  settings, such as `BUGCROWD_MCP_AUTH`.

The process keeps separate transcripts for up to 32 sessions and admits one
active prompt globally. Concurrent prompts receive a busy error; cancel or wait
before retrying. Switching sessions invalidates the retained cache record and
replays the selected conversation through the same model instance.

## Boundaries in this first version

- Conversations are in memory until the process exits. `session/load`, persistent
  session listing/restoration, model switching and session modes are not advertised.
- Shell tools execute locally and report their result as tool output. ACP's
  optional client terminal API, live terminal widgets and edit diff previews are
  not implemented. Use local macOS projects; this is not a remote execution bridge.
- Initial model loading/integrity verification is synchronous. Cancellation is
  recorded immediately but cannot interrupt that load; it is checked before
  generation starts.
- Shell operations have a five-minute deadline and retain at most 256 KiB of
  output; the model receives the existing 8192-character shell result limit.
  Stdio MCP requests have a 60-second deadline and an 8 MiB response-buffer limit.
  Cancelled/broken stdio connections are stopped; cancelled sessions rediscover
  their MCP tools on the next inference turn. HTTP uses its existing 60-second
  request timeout. Client permission/file requests time out after five minutes.
- Approvals are not an OS sandbox. Approved tools retain the agent user's normal
  filesystem/network permissions and environment. Child processes that detach
  from their original process group are outside the shell cancellation guarantee.
- Diagnostics go to stderr. Stdout contains only newline-delimited ACP JSON-RPC.
  Input frames are limited to 8 MiB with a bounded queue. A stalled output pipe
  closes the connection after five seconds. EOF, SIGINT and SIGTERM cancel active
  work and clean up owned MCP subprocesses.

## Implementation and validation

`AgentCore` owns session state and the shared model. `AgentTurn` is the common
conversation loop; `AgentInteraction` supplies UI events, approvals, file access
and cancellation. `TerminalGeneration` owns terminal input and presentation.
`ACPServer` handles protocol/session routing while `ACPChannel` correlates client
requests independently of an active prompt. `ACPTransport` handles stdio framing.

Run model-free checks with:

```bash
Scripts/test.sh --filter TurboFieldfareAgentTests
python3 Scripts/test-agent-editor.py
```

The ACP suite includes a real executable handshake, session creation and skills
request over pipes with a deliberately nonexistent model path. It checks clean
protocol stdout and confirms these operations do not load a model. Scripted
backends cover streaming, permissions, cancellation, concurrent-prompt rejection,
client file buffers and unsupported content. Local subprocess fixtures cover
shell cancellation and an MCP server that never answers initialization.

Protocol references: [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization),
[prompt turns](https://agentclientprotocol.com/protocol/v1/prompt-turn),
[tool permissions](https://agentclientprotocol.com/protocol/v1/tool-calls),
[transports](https://agentclientprotocol.com/protocol/transports).

### Validation record — 2026-09-16

Baseline commit: `b33cf38` plus the ACP working-tree changes. Hardware: Apple M2
Pro, 32 GiB RAM. macOS 26.6.2; Apple Swift 6.4
(`swiftlang-6.4.0.34.1 clang-2100.3.34.1`).

| Command | Exit | Complete summary/footer |
| --- | --- | --- |
| `swift build -c release --product TurboFieldfareAgent` | 0 | `Build complete! (56.55 sec.)` |
| `Scripts/test.sh --filter TurboFieldfareAgentTests` | 0 | `Build complete! (3.42 sec.)`; `Executed 45 tests, with 0 failures (0 unexpected) in 5.226 (5.234) seconds` |
| `python3 Scripts/test-agent-editor.py` | 0 | `31 terminal editor checks passed.` |
| `git diff --check` | 0 | No output. |

A Python subprocess smoke check also launched the release executable with
`--acp --model <temporary-directory>/missing.gturbo`, sent `initialize` and
`session/new`, then closed stdin. It exited 0, emitted valid ACP responses and
loaded no model. The XCTest executable checks additionally exercise `/skills`
and graceful SIGTERM shutdown.

One intermediate model-free test run was stopped after diagnosing an unbounded
Foundation `waitUntilExit()` during cancelled MCP cleanup. Bounded cleanup
replaced that wait, and the complete suite passed afterward.

Live model testing stopped at preflight: `ls -l scratch/gemma4.gturbo` reported
`No such file or directory`. Memory-pressure reported 79% system-wide free
memory; disk had 90 GiB available; no matching model process was found. No model
was downloaded, copied, loaded or terminated, and no inference/benchmark run
was attempted. Zed's live UI and real model tool generation have not been tested.
No model-test protocol was bypassed. Build/test cache access required sandbox
escalation; the terminated process was only the model-free test runner launched
for this work.

## REPL file references

In the terminal REPL, attach text files directly with `@path`:

```text
Explain @Sources/TurboFieldfareAgent/Core/Session.swift
Compare @README.md @"docs/my notes.md"
/review Review @Sources/TurboFieldfareAgent/Core/AgentCore.swift
```

Relative paths use the process working directory. Absolute paths and `~/` paths
also work. References must start at the beginning of the prompt or after
whitespace; quote paths containing spaces. Unquoted punctuation belongs to the
filename. Emails remain literal, and `\@mention` stays literal.

Files are read when the prompt is submitted and included in that user message.
Repeated paths are included once. Only regular UTF-8 text files without NUL bytes
are accepted, with at most 16 files and 256 KiB of combined file content per
prompt. Missing, unreadable, binary, or oversized attachments stop submission
with an error. File contents and skill bodies are never scanned for additional
references. These limits bound attachment size; the model's context limit still
applies to the full conversation.

This syntax is for the terminal REPL. In ACP clients such as Zed, use the client's
native resource attachments.

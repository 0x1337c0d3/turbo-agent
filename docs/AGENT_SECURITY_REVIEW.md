# Security review — TurboFieldfareAgent

Date: 2026-09-16. Scope: current agent sources and model-free regression tests.
Method: manual static analysis using the Sentinel security audit skill, plus
focused XCTest regressions. No exploit against a live MCP account, no model
inference, dependency CVE scan, or git-history secret scan was performed.

## Security scorecard

This is a scoped code review, not a security certification. No numeric posture
score is assigned: test coverage cannot establish a probability of compromise.

| Severity | Confirmed findings | Fixed in this review | Open |
| --- | ---: | ---: | ---: |
| High | 3 | 3 | 0 |
| Medium | 5 | 3 | 2 |
| Low | 2 | 1 | 1 |

## Attack surface

The local terminal user controls direct commands and configuration. Model output,
web pages, file contents, MCP descriptions/results, and generated tool arguments
must not be treated as authorization. Assets include local files, inherited
credentials, the terminal, and connected accounts. Configured local MCP server
programs remain trusted code that starts automatically.

## Findings

| ID | Severity | Status | Evidence and impact | Change or next action |
| --- | --- | --- | --- | --- |
| AGENT-001 | High | Fixed | `ToolRegistry.execute` previously executed model-requested file, shell, URL, and MCP actions directly. An injected instruction in a document or result could lead to local changes or disclosure without a user decision. CWE-862. | Require explicit per-call approval of full arguments. Deny EOF/empty/non-interactive input. Subagents inherit the same boundary. Direct user `!command` remains explicitly authorized. |
| AGENT-002 | High | Fixed | `MCPSSETransport.startSSE` accepted arbitrary endpoint URLs and attached configured headers to subsequent POSTs. HTTP transports also used an unrestricted default redirect policy for custom headers. CWE-200. | Legacy HTTP+SSE transport has since been removed. Streamable HTTP uses a same-origin redirect delegate. Scheme, host, and effective port must match; URL credentials are rejected. |
| AGENT-003 | High | Fixed | Remote definitions could use a built-in name such as `execute_bash` but advertise a different description. The dispatcher still executed the local built-in. CWE-843. | Reject MCP definitions with reserved built-in names. Remove the fallback that tried unknown tool calls on every server. |
| AGENT-004 | Medium | Fixed | Model text and remote tool results were printed verbatim; ESC, OSC, C1, and bidi controls could alter terminal state or disguise displayed content. CWE-150. | Escape controls in colored output and streamed model text while retaining newline/tab layout. Internal cursor controls remain separate. |
| AGENT-005 | Medium | Fixed | Stdio request names were interpolated into JSON; response matching searched for an `id` substring, confusing IDs such as 1 and 10 and failing on whitespace. CWE-74/CWE-20. | Serialize requests structurally and parse exact top-level numeric response IDs, rejecting booleans. |
| AGENT-006 | Medium | Fixed | Conversation loops and recursively delegated tasks had no round/depth budget. CWE-400. | Limit to 32 generation rounds per loop, four nested subagents, and 64 total tool dispatches per user turn, shared across delegation. Check task cancellation between rounds. |
| AGENT-007 | Medium | Open | `MCPStdioTransport.readLineSync` and `ShellCommand.run` can wait indefinitely. File/URL/shell response data is buffered without consistent byte limits. The legacy SSE pending-continuation and retained-connection issues were eliminated by removing that transport. CWE-400. | Add monotonic operation deadlines, bounded streaming reads, cancellation of child process trees, and explicit transport shutdown/draining on reload and exit. Round budgets do not interrupt an individual blocked operation. |
| AGENT-008 | Medium | Open | `Runtime.swift` uses mutable `@unchecked Sendable` spinner/cancellation flags across tasks and a dispatch callback. Forced `exit(1)` bypasses the defer restoring raw terminal mode. CWE-362. | Use synchronized cancellation state and an explicit terminal-session lifecycle that restores modes before forced exit. The footer's exit handler only restores scrolling/colors. |
| AGENT-009 | Low | Fixed | REPL error handling removed the last message even if it was a completed tool result, leaving an unmatched tool call. | Remove only a newly added user message when no subsequent messages were recorded; preserve completed call/result pairs. This does not undo executed tools. |
| AGENT-010 | Low | Open | `try? decoder.consume`, `consumeTail`, and `finish` suppress parser failures. Malformed structured output can be silently lost. | Propagate parser errors after restoring terminal state and invalidate the affected cache record. |

All findings above have high confidence from the local implementation; live
exploitation was not attempted. Findings involving timing, resource exhaustion,
and terminal modes were not validated with an inference run.

## Existing controls retained

- Model loading requests full SHA-256 integrity verification.
- MCP secrets are referenced through environment variable names rather than
  written into the generated settings file; absent values skip that server.
- Tool schema adaptation rejects representations unsupported by the model.
- Prompt reuse checks committed tokens and falls back to rebuilding KV.

## Boundaries and next priorities

Approval is not an OS sandbox. An approved shell command runs as the current
user and inherits the agent environment. File tools are not workspace-confined.
A user-approved request can still disclose sensitive data. Remote HTTP transport
is still configurable, so use HTTPS for credential-bearing remote endpoints.

Prioritize AGENT-007 and AGENT-008 next, then parser error propagation. Local
settings and skill files are trusted configuration; protect them like executable
code. The review does not establish dependency CVE status.

## Validation

Command: `Scripts/test.sh --filter TurboFieldfareAgentTests`.
Exit code: 0. Build footer: `Build complete! (4.06 sec.)`.
Test footer: `Executed 29 tests, with 0 failures (0 unexpected) in 3.685 (3.689) seconds`.
Tests cover approval decisions, control escaping, same-origin URL checks,
structured JSON encoding/ID matching, tool-name collisions, round limits, and
existing agent behavior. Origin tests exercise the policy predicate; no live
redirect or interactive approval session was exercised.

Environment: commit `0ca5e8f` plus working-tree changes; Apple M2 Pro, 32 GB RAM;
macOS 26.6.2; Swift 6.4. Tests used local tokenizer files and fake network
credentials. No benchmark or model-process protocol was invoked. Swift cache
access required sandbox escalation. `git diff --check` passed.

## ACP implementation follow-up

The ACP integration adds a UI approval path with explicit allow-once selection;
missing, failed, unknown and cancelled choices deny execution. Client file access
is capability-gated. Session-specific MCP catalogs retain the reserved-name
checks, and stdout is reserved for framed protocol messages.

Parts of AGENT-007 are addressed for model-invoked tools: shell and stdio MCP
operations now have cancellation-aware I/O, bounded buffers and monotonic
deadlines. Stdio cancellation stops the owned subprocess. Direct REPL `!command`
execution and file/HTTP response buffering still need the separate resource-limit
review described above. Detached shell descendants are not covered by process
group cancellation.

The generation presentation was extracted into `TerminalGeneration`, with locked
spinner/input state and terminal restoration before its forced-exit path. ACP
uses synchronized cancellation and never reads keyboard input during generation.
This narrows AGENT-008; it does not constitute a fresh full concurrency audit.

See [ACP setup and validation](AGENT_ACP.md) for protocol tests, supported behavior
and the live-model validation limitation.

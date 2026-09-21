# Small context windows

Turbo Agent is designed to remain useful with an 8K-token model. The design
takes the same constraint-first position as LiteCode: the repository and the
conversation will eventually be larger than the model window, so every model
request must contain a deliberately selected working set rather than the whole
project or an ever-growing transcript.

This is enforced by the runtime. It is not a prompt asking the model to stay
under a limit.

## What is budgeted

Before every inference request, `AgentContextAssembler` accounts for:

- the effective system and developer instructions, including the bounded
  Continuity bootstrap;
- every advertised tool name, description, and JSON schema; and
- the conversation messages, tool calls, arguments, and tool results selected
  for this request.

The runtime first reserves room for the answer and a tokenizer safety margin:

```text
usable prompt = model context - reserved output - safety margin
```

An 8K context reserves 1,024 tokens for output. The safety margin is the larger
of 256 tokens or one sixteenth of the model context. Wider contexts reserve
between 2,048 and 4,096 output tokens. Token counts use a conservative UTF-8
estimate of three bytes per token because Apple Foundation Models does not
expose its tokenizer.

If a request is too large, the assembler removes complete oldest user turns,
including their assistant and tool messages, until the request fits. It never
silently removes the system/developer instructions or the newest user turn. If
those pinned parts alone do not fit, generation fails with an actionable error
instead of knowingly overflowing the backend.

The terminal footer exposes the resulting estimate, percentage used, output
reserve, and number of messages omitted from the current request. Omission is
per request: the terminal or ACP session still retains its full transcript.

## Keeping the working set small

Budget enforcement is the last guard. Several earlier boundaries prevent the
prompt from becoming unnecessarily large:

| Input | Boundary |
| --- | --- |
| Standing instructions | `.agents/codex_prompt_8k.md` provides a compact prompt for 8K deployments. |
| Repository contents | The agent discovers paths and reads relevant files through tools; it does not inject the checkout into every request. |
| Explicit file attachments | `@path` is opt-in and limited to 16 UTF-8 regular files and 256 KiB combined. The final request budget still applies. |
| Shell output | `execute_bash` returns at most 8,192 characters and tells the model to narrow a larger result with `grep`, `head`, or `tail`. |
| Intermediate AFM messages | When an assistant turn calls tools, later rounds retain the structured calls rather than also repeating its surrounding prose. |
| Tool catalogue | Only tools advertised for the current session are counted and sent. The persistent-memory tool surface can be off, minimal, or full because schemas themselves consume context. |

This makes code access demand-driven. A request can inspect a project broadly
with cheap directory and search operations, then spend tokens on the source
files needed for the current change. Large source still has to be narrowed by
the agent or attached in smaller pieces; Turbo Agent does not currently create
LiteCode-style `project_context.md`, `folder_context.md`, or line-range analysis
files automatically.

## Continuity without replaying the transcript

Dropping old turns solves request size but would normally discard project
knowledge with them. `ContinuityCore` separates durable state from conversation
history:

- the session journal records what happened without placing the journal in the
  next prompt;
- addressed, versioned memories retain what remains true, such as decisions,
  constraints, conventions, gotchas, and current state; and
- each new session receives a bounded bootstrap of relevant memories rather
  than a replay of earlier chats.

The default bootstrap is capped independently by both count and size: 60
records and 16 KiB. Candidates are ranked by priority namespace, relevance to
the current request, importance, and recency; dependencies can be pulled in
with a selected fact. Values in the system prompt are flattened and shortened
to 200 characters. When memory tools are enabled, the model can fetch a full
value on demand instead of paying to include every value on every request.

The store is scoped per workspace, and writes supersede older versions rather
than destroying them. This is more durable than LiteCode's four-entry ring
buffer while retaining the same core property: continuity has a fixed prompt
cost. Memory is opt-in, and its model-facing tool surface defaults to off; the
bootstrap and session journal can operate without paying for memory tool
schemas. See [ContinuityCore](../Sources/ContinuityCore/README.md) for storage,
ranking, provenance, and persistence details.

## Relationship to the LiteCode approach

The local LiteCode reference demonstrates four useful principles:

1. enforce the token limit in code before every call;
2. reserve output capacity instead of filling the whole window with input;
3. select relevant code rather than sending the entire repository; and
4. preserve a small amount of cross-request state.

Turbo Agent implements all four, but adapts them to an interactive,
multi-backend agent:

| LiteCode | Turbo Agent |
| --- | --- |
| Precomputed Markdown project, folder, and file maps | Live discovery and selective reads through native and MCP tools |
| Planner call followed by one executor call per file | A bounded multi-round tool loop over the files needed for the task |
| Four recent synthesis records injected into prompts | Versioned workspace memory with a count-and-byte-bounded, relevance-ranked bootstrap |
| Per-planner and per-executor token checks | One model-independent budget check before every backend generation, including every tool round |

The shared idea is bounded selection, not a particular orchestration shape.
Turbo Agent preserves general coding-agent behavior while ensuring that no
generation relies on unbounded transcript growth.

## Failure modes and tradeoffs

- The token count is conservative, not exact. The safety margin protects
  backends whose framing or tokenizer differs from the estimate.
- Old turns can be absent from a particular inference request. Durable facts
  should be written to memory; the session transcript alone is not a promise
  that every past message remains visible to the model.
- A single large newest request, system prompt, tool catalogue, or attachment
  can still be too large. The runtime rejects it because trimming the user's
  current request would be surprising and unsafe.
- Tool output is bounded, so broad commands should be narrowed and large files
  read selectively.
- Memory improves continuity only when it contains distilled facts rather than
  transcripts or copies of source. Source code remains authoritative and
  important remembered claims should be checked against the checkout.

## Relevant checks

`AgentContextBudgetTests` covers complete-turn trimming, preservation of pinned
instructions and the Continuity bootstrap, output and safety reserves, tool
schema accounting, rejection of an oversized newest turn, and working room
with the default 8K agent surface. `StatusLineTests` covers presentation of the
budget. The model-free suite runs both through:

```bash
make test
```

# Large-file context and edit orchestration plan

Status: implemented

This document describes how Turbo Agent should inspect and modify source files
that are too large to fit in a model request, especially when using an 8K
Apple Foundation Model. It combines the strongest ideas from Villani Code and
LiteCode with Turbo Agent's existing request budget, approval, continuity, and
stale-write protections.

The intended result is not merely a larger `read_file`. It is a bounded working
set in which the model can discover the relevant part of a large repository,
read only the necessary source ranges, make anchored edits against a known file
revision, and continue for many tool rounds without old tool output exhausting
the active context.

## Executive summary

Implement the work in this order:

1. Add revisioned, line-range reads and deterministic outlines to `read_file`.
2. Make `edit_file` unique, anchored, and revision guarded; later add atomic
   multi-hunk patches.
3. Project completed tool activity into compact receipts before every model
   request, including inside the current user turn.
4. Maintain a bounded, engine-authored task-state block for the current turn.
5. Build a lightweight repository path/symbol index and inject a small
   retrieval briefing at the start of appropriate tasks.
6. Add an optional task graph for large or multi-file changes. Parallelize
   read-only analysis and independent-file patch proposals, never uncoordinated
   writes to different regions of one file.
7. Validate the assembled whole files and the repository after patches are
   merged.

The existing `AgentContextAssembler` remains the final hard guard. None of the
new selection or compaction layers may bypass its accounting for instructions,
tool schemas, messages, reserved output, or safety margin.

## Problem statement

Turbo Agent currently exposes whole-file reads:

```json
{"path":"Sources/AgentLineEditor/AgentLineEditor.c"}
```

`AgentLineEditor.c` is currently 388 lines and about 15.6 KiB. Turbo's
three-byte-per-token estimator charges the file alone at roughly 5,200 tokens.
An 8K request has 6,656 usable prompt tokens after the 1,024-token output
reserve and 512-token safety margin, before paying for the system prompt, memory
bootstrap, tool schemas, user request, and message framing.

There are two related failure modes:

### A whole read is too expensive

`read_file` accepts only a path and returns the complete UTF-8 file. It cannot
request a line range, return an outline, or adapt its result to the remaining
request budget. A file need not be exceptionally large to crowd out all useful
reasoning space on an 8K model.

### The active turn grows without a removable boundary

`AgentContextAssembler` removes complete oldest user turns. During a single
user request, however, every assistant tool call and tool result belongs to the
newest pinned turn. A large read may fit on the first round, but another read,
edit, command, or test result can make a later round impossible to assemble.
The full session can remain stored, but the inference projection cannot keep
replaying every completed observation.

Range reads solve the first problem. Active-turn projection solves the second.
Both are required.

## Lessons from the reference implementations

### Villani Code

Villani contributes three useful runtime ideas:

- Build a cheap repository index and prepend a small list of likely paths, so a
  weak model spends fewer rounds discovering the relevant file.
- Maintain deterministic mission/task state outside the conversation rather
  than expecting the model to reconstruct progress from an ever-growing
  transcript.
- Bound tool results according to their type. In particular, retain both the
  beginning and end of command output because failures and summaries are often
  at the end.

Turbo should not copy Villani's character-only context ceiling. Turbo's
model-aware request accounting is a stronger final invariant. Villani's context
inventory is also primarily bookkeeping on its main request path; Turbo's
projected messages must be the data actually sent to the backend.

### LiteCode

LiteCode uses three layers of repository maps and analyzes large files in
120-line chunks. A planner selects `load_sections`, an executor receives only
that range, and pure code splices the replacement back into the complete file.
Its scheduler runs one model call per file and executes independent files in
dependency waves.

The useful principles are:

- map before loading;
- one bounded edit context per file;
- represent dependencies explicitly;
- separate model-generated proposals from deterministic application; and
- apply conflict checks and validation after isolated executor calls.

Turbo should not copy LiteCode's raw line splice. Line numbers become stale
after edits, and its emergency first-half fallback can treat a partial response
as a complete-file replacement. Turbo already has the better primitive:
`AgentWritePlan` reads the current file, previews the diff, and refuses a write
if the source changed before application.

LiteCode's “parallel edits” are parallel edits to independent files, not
concurrent edits to chunks of the same file. Turbo should preserve that
boundary in its first implementation.

## Design principles

1. **The checkout is authoritative.** Maps, outlines, memory, and task state
   are hints. A write is always checked against the current source revision.
2. **Selection precedes compression.** Prefer the correct 80 lines over a
   summary of all 800 lines.
3. **Every request still passes the hard budget.** Retrieval and compaction
   reduce pressure; `AgentContextAssembler` proves the final request fits.
4. **Do not mutate the recorded transcript to save prompt space.** Build a
   bounded request projection while retaining full UI and journal data.
5. **Model output is a proposal, not authorization.** Existing approval and
   diff-preview behavior remains fail-closed.
6. **One file has one write owner per orchestration wave.** Multiple workers
   may inspect it, but patches are merged and applied by one coordinator.
7. **Prefer anchors and revisions over naked line numbers.** Lines are useful
   for reading and navigation; edits require source identity and contextual
   anchors.
8. **Make degraded behavior explicit.** Never silently truncate a source read,
   replace half a file, ignore a stale digest, or proceed over budget.
9. **Keep small tasks cheap.** A small file or one obvious string replacement
   should continue through the current direct tool loop without a planner call.
10. **Keep schemas small.** Extending existing tools is preferable to adding a
    large collection of overlapping tools on an 8K backend.

## Target architecture

```text
User request
    |
    v
Turn coordinator ----------------------------------------------+
    |                                                          |
    +--> repository retrieval briefing                         |
    +--> deterministic working-state projection                |
    +--> direct tool loop OR validated task graph              |
                         |                                     |
               +---------+----------+                          |
               |                    |                          |
          inspection wave      executor wave                   |
          (safe in parallel)    (one proposal/file)            |
               |                    |                          |
               +---------+----------+                          |
                         v                                     |
               revision/overlap checks                         |
                         v                                     |
                 diff preview + approval                       |
                         v                                     |
                   atomic application                          |
                         v                                     |
                  whole-file validation                        |
                         |                                     |
                         +---- events/receipts/task state -----+

Before every model call:
full recorded messages -> bounded projection -> hard context assembler -> backend
```

This is an extension of the existing interactive loop, not a replacement for
it. The direct loop remains the default. Orchestration is selected only when
the task or file shape makes isolation valuable.

## Core data model

Introduce a small set of internal, `Sendable` value types. Names are
illustrative; implementation naming should follow surrounding Swift style.

### `FileRevision`

```swift
struct FileRevision: Sendable, Equatable, Codable {
  let path: String
  let digest: String
  let byteCount: Int
  let lineCount: Int
  let modifiedNanoseconds: UInt64?
}
```

The digest must be stable across processes. Use SHA-256 if it can be provided
without adding an unsuitable dependency; otherwise use a documented stable
digest with collision resistance appropriate for stale-write detection. The
full content comparison in `AgentWritePlan` remains the final authority.

### `FileSlice`

```swift
struct FileSlice: Sendable, Equatable {
  let revision: FileRevision
  let startLine: Int
  let endLine: Int
  let content: String
  let hasEarlierLines: Bool
  let hasLaterLines: Bool
}
```

Line boundaries are one-based and inclusive in the model-facing contract.
Internally, convert once to zero-based half-open ranges. Preserve empty lines,
UTF-8, and the original newline convention when applying changes.

### `FileOutline`

```swift
struct FileOutline: Sendable, Equatable, Codable {
  let revision: FileRevision
  let sections: [FileSection]
}

struct FileSection: Sendable, Equatable, Codable {
  let startLine: Int
  let endLine: Int
  let kind: String
  let name: String
  let signature: String?
}
```

Outlines are navigation aids. Initially support deterministic recognition for
Swift and C-family declarations, with a generic fallback based on headings,
braces, and non-empty line windows. Incorrect parsing must reduce outline
quality, never source correctness.

### `ToolObservation` and `ToolReceipt`

```swift
struct ToolObservation: Sendable {
  let callID: String
  let name: String
  let arguments: JSONValue
  let fullResult: String
  let receipt: ToolReceipt
  let importance: ObservationImportance
}

struct ToolReceipt: Sendable, Equatable {
  let summary: String
  let paths: [String]
  let revisions: [FileRevision]
  let outcome: String
}
```

The observation belongs to runtime state and may be displayed or journaled in
full. The receipt is the bounded representation eligible for later inference
requests.

### `TurnWorkingState`

Track only deterministic facts generated from runtime events:

- original user objective;
- candidate and intended files;
- file revisions and ranges inspected;
- proposed and applied edits;
- commands run and exit status;
- compact validation failures;
- current blocker;
- remaining task graph nodes; and
- whether any observation was compacted.

This state is per user turn. It is not durable project memory and must not be
written into `ContinuityCore` automatically as a long-lived fact.

## Tool contract changes

### Extend `read_file`

Keep `path` required and add optional fields:

```json
{
  "path": "Sources/AgentLineEditor/AgentLineEditor.c",
  "start_line": 112,
  "end_line": 214,
  "mode": "auto"
}
```

Supported modes:

- `auto` (default): return the whole file only when it fits within the current
  tool-result allowance; otherwise return a deterministic outline and a small
  initial range with explicit instructions to request a range.
- `range`: require or derive `start_line` and `end_line`, returning only that
  bounded slice.
- `outline`: return metadata and the deterministic section map without source
  bodies.

Do not add a separate `inspect_file` in the first release. Folding outline and
range behavior into `read_file` saves tool-schema tokens and preserves the
model's existing learned entry point. A separate tool can be reconsidered if
telemetry shows models struggle with the mode field.

Every successful result should use a stable, readable envelope:

```text
[file path="Sources/AgentLineEditor/AgentLineEditor.c"
 digest="sha256:..." lines="112-214/388" bytes="4210" complete="false"]
112: static unsigned char move_to_boundary(...)
...
214: }
[end file; request start_line=215 to continue]
```

Requirements:

- Reject zero, negative, reversed, or unreasonably wide ranges.
- Clamp only the end of a valid range to EOF and report the actual range.
- Give line numbers in range mode.
- Detect binary/NUL-containing and non-UTF-8 files before rendering.
- Resolve paths through the existing workspace/interaction path behavior.
- Preserve ACP client reads; slicing happens after the client returns content.
- Never return a partial range without labeling it partial.
- Set a conservative default source-result ceiling. The ceiling should become
  dynamic once runtime headroom is available.

### Make `edit_file` precise

Extend the current contract:

```json
{
  "path": "Sources/AgentLineEditor/AgentLineEditor.c",
  "target": "exact source previously read",
  "replacement": "replacement source",
  "expected_digest": "sha256:...",
  "replace_all": false
}
```

Behavior:

- The default is exactly one occurrence.
- Zero occurrences is `targetNotFound`.
- More than one occurrence is `targetAmbiguous` unless `replace_all` is
  explicitly true.
- `expected_digest` is required and must match before preview generation.
  Missing digests fail with `revisionRequired`; mismatches fail with
  `staleRevision` and require a fresh read before reproposing the edit.
- The existing complete-content equality check must still run immediately
  before application.
- Empty `target` is invalid.
- A no-op replacement is reported without asking for a meaningless write.
- Diff preview and approval behavior remain unchanged.

This is a deliberate safety correction: the current implementation uses
`replacingOccurrences`, which can modify multiple identical regions even when
the model intended one.

The digest identifies the source revision used to propose the edit. The
complete-content check protects the later interval between preview and
application; it does not substitute for checking the revision observed by the
model. This is an intentional contract change for existing callers, including
`replace_all`: update tool schemas, examples, and tests together. There is no
unguarded compatibility fallback.

### Guard whole-file replacement

`write_file` must not bypass the range-edit contract. Creating a new file
remains supported with the existing preview and approval behavior. Replacing
an existing file requires both a matching `expected_digest` and a complete
source read of that revision retained in the current request projection.
Track this eligibility in runtime metadata keyed by resolved path and digest;
never accept a model-authored claim that a file was read completely.

A range, outline, receipt, or collection of separately read slices does not
establish whole-file replacement eligibility. If the complete read has been
compacted or evicted, reject replacement before preview with guidance to use
`edit_file` or `apply_patch`. Approval, including `--yolo`, does not bypass this
guard. Recheck source equality before application, including that a creation
target still does not exist.

This prevents partial inspection from authorizing whole-file replacement. It
does not prove that replacement content is semantically complete after a full
read; diff review and validation remain necessary. The contract covers the
built-in file tools, not arbitrary writes through shell commands or MCP tools.

### Add atomic multi-hunk patching after the primitives are stable

Large changes sometimes touch several non-adjacent regions. Add `apply_patch`
only after range reads, digest checks, and unique edits are proven. Its compact
contract should resemble:

```json
{
  "path": "Sources/AgentLineEditor/AgentLineEditor.c",
  "expected_digest": "sha256:...",
  "hunks": [
    {
      "target": "exact bounded source",
      "replacement": "new bounded source"
    }
  ]
}
```

The coordinator validates all hunks against one immutable base before changing
anything:

- every target exists exactly once;
- targets do not overlap;
- the digest matches;
- applying all hunks yields one final file;
- one combined diff is previewed; and
- one approval applies the file atomically.

Avoid model-authored unified-diff line counts as the primary interface for
small models. Exact anchored targets are simpler to validate and already align
with `AgentWritePreview`.

## Dynamic tool-result budgeting

Add a `ToolResultBudget` computed for each tool call from the selected model's
context limit and the most recent prepared request:

```swift
struct ToolResultBudget: Sendable {
  let maximumTokens: Int
  let maximumBytes: Int
  let pressure: Pressure
}
```

The budget must reserve space for:

- the next assistant response;
- the assistant tool-call message and framing;
- the next request's system instructions and tool catalog; and
- the bounded working-state block.

Phase one may use conservative fixed ceilings because it is easier to validate.
Phase two should expose the most recent `AgentContextBudget` or an equivalent
headroom calculation from `AgentRuntime` to `AgentToolContext`.

Per-tool policies:

| Tool/result | Full form | Compacted form |
| --- | --- | --- |
| `read_file` | Requested range | Path, revision, range, section names |
| `grep_search` | Bounded matches | Query, path, match count, selected lines |
| `execute_bash` | Bounded head and tail | Command, exit status, final diagnostics |
| `edit_file`/patch | Diff preview outside model result; short result | Path, old/new revision, changed regions |
| MCP tool | Bounded provider result | Tool name, arguments summary, head/tail |
| Memory tool | Existing bounded JSON | Key/query and outcome |

For shell output, preserve a smaller prefix and a larger suffix rather than
only the prefix. Always retain exit status and explicitly say how much output
was omitted.

## Active-turn context projection

Do not mutate `messages`, because it is the session record and may still be
needed by the UI, ACP, or journal. Build a separate projection immediately
before `AgentContextAssembler.prepare`.

The projection pipeline should be:

1. Start from the full message list.
2. Preserve system/developer messages and the newest real user request.
3. Preserve assistant tool-call and tool-result protocol pairing.
4. Keep the newest relevant source slice or failure output in full.
5. Replace eligible older tool results with deterministic receipts.
6. Evict eligible completed tool-exchange groups, oldest first, when their
   aggregate token or group-count limit is exceeded. Fold their current facts
   into bounded working state before eviction.
7. Inject the current bounded `TurnWorkingState` as an ephemeral developer
   instruction or merge it into the effective instructions.
8. If still too large, remove old complete turns using the existing policy.
9. Run the existing hard request budget and fail if pinned content still does
   not fit.

### Protocol validity

OpenAI-style and AFM message projections must retain every tool call/result ID
relationship required by the backend. Compaction changes result content, not
the structural pair. If an entire tool exchange is removed, remove the
assistant call and all associated results atomically.

Multiple tool calls in one assistant message require special care: keep or
compact the complete group so no orphan result remains.

Receipt compaction alone is insufficient: assistant call arguments retain
complete edit targets and replacements, and even small receipts accumulate.
Bound retained exchanges in aggregate, counting assistant prose, arguments,
result content, receipts, and framing. A completed group consists of one
assistant message and all of its tool results; evict it as a unit rather than
rewriting historical call arguments. Never evict a pending group.

Before evicting a group containing still-needed source or failure evidence,
carry that bounded evidence into a clearly labeled tool-data section of the
projection, without orphan tool-result IDs or promoting it to instructions.
Include that section in budget accounting. Facts and evidence needed for the
next action must survive within their limits, or preparation must fail
explicitly. Removing a full read also revokes whole-file replacement eligibility.

### Observation retention policy

Initially use deterministic rules rather than an LLM summarizer:

- Keep the most recent source slice in full.
- Keep the most recent failed command's diagnostic suffix in full.
- Compact successful commands after their exit status has informed a later
  round.
- Compact reads after a successful edit based on that revision.
- Keep stale-write and ambiguity errors until the model has successfully
  reread the affected file.
- Compact successful edit results immediately; the working state records the
  new revision.
- Never compact the user's request.

Expose counts in context telemetry: full observations, compacted observations,
evicted exchange groups, retained argument tokens, receipt tokens, and saved
estimated tokens. Aggregate retention limits must not grow with turn length.

## Bounded task-state projection

Render `TurnWorkingState` into a concise block, with a hard token/byte limit:

```text
## Current task state
Objective: repair multiline cancellation without regressing history navigation
Targets: Sources/AgentLineEditor/AgentLineEditor.c
Current revisions: AgentLineEditor.c=sha256:...
Inspected: AgentLineEditor.c:65-110,171-214,308-388
Applied: updated cancel_prompt and finish_cancel
Validation: swift build passed; focused editor test still failing
Last failure: expected prompt-clear marker after second Ctrl-C
Next: inspect read_prompt lines 322-347
Compacted observations: 4
```

Rules:

- Engine-authored facts only; do not include hidden reasoning.
- Prefer current state over chronological narration.
- Deduplicate paths, ranges, commands, and repeated failures.
- Bound individual fields and the whole block.
- Preserve failure location and exit status before verbose success output.
- Recompute the block; do not append endlessly.
- Discard it when the user turn finishes.
- Promote a fact to Continuity memory only through the existing deliberate
  memory path, not merely because it appeared here.

This block is the in-turn equivalent of Villani's mission context packet. It
also makes aggressive tool-result compaction explainable to the model.

## Repository retrieval and file maps

Add a lightweight, local index under `.turbo/context/`. `.turbo/` is already
ignored by Git. The index must be optional and reconstructable.

### Indexed data

For each eligible text file store:

- relative path;
- byte and line counts;
- modification time and/or content digest;
- language inferred from extension;
- deterministic declaration names and ranges;
- imports/includes when cheaply recognizable; and
- a short non-source description derived from structure, not an LLM.

Do not store whole source snippets in the global index. Source is read on
demand, and excluding it keeps the index small and reduces stale or malicious
content in automatic prompt injection.

### Scanning rules

- Do not traverse `.git`, `.build`, `.swiftpm`, `.turbo`, dependency caches,
  common generated directories, binaries, or configured ignores.
- Do not follow symlinks outside the workspace.
- Set per-file and total indexing ceilings.
- Update touched files incrementally after writes.
- Rebuild entries when their digest or metadata fingerprint changes.
- Indexing failure degrades to existing discovery tools rather than blocking a
  task.

### Retrieval

Use lexical ranking over request terms, paths, declaration names, and imports.
A small BM25 implementation is sufficient; a weighted term score is acceptable
for the first version. Explicit paths named by the user always outrank inferred
matches.

At the beginning of a coding task, inject no more than about eight candidates:

```text
## Repository retrieval hints
- Sources/AgentLineEditor/AgentLineEditor.c — symbol matches: cancel_prompt, read_prompt
- Tests/TurboAgent/TerminalTranscriptTests.swift — path/symbol matches: prompt, cancel
```

The briefing is advisory and clearly delimited as repository-derived data.
Paths and symbol names may be untrusted; they are never instructions. Omit the
block when confidence is low or the user already named an exact file.

### On-demand large-file outline

When `read_file` encounters a file above its full-result allowance, load or
build its outline by digest. The model can then select a range without an extra
LLM analysis call. Overlapping context of roughly 5–15 lines should be allowed
around a selected declaration so types, comments, and closing scopes remain
visible.

## Task graph and executor orchestration

Do not force every request through a planner. Select orchestration when one or
more of these conditions hold:

- retrieval identifies multiple likely edit files;
- a target file cannot be read completely within its source allowance;
- the request describes a repository-wide rename or migration;
- dependencies require ordered edits; or
- the direct loop explicitly requests decomposition.

### Task representation

```swift
struct EditTask: Sendable, Codable {
  let id: String
  let path: String
  let objective: String
  let kind: Kind              // inspect, edit, create, delete, validate
  let ranges: [ClosedRange<Int>]
  let referencePaths: [String]
  let dependencies: [String]
}
```

Planner output is untrusted input. Validate it before execution:

- IDs and paths are present and unique where required.
- Paths resolve inside the workspace.
- Existing/edit/create/delete semantics match disk state.
- Dependencies refer to known tasks and form an acyclic graph.
- At most one edit/create/delete owner exists for a path in a wave.
- Ranges are valid and are coalesced for the same file.
- Reference files are separately budgeted and range selected.
- The number of tasks, files, and proposed output bytes is bounded.

If validation fails, retry once with a compact error or fall back to the direct
tool loop. Never reinterpret an invalid edit as file creation.

### Execution waves

Build topological waves from dependencies:

1. Snapshot the base revision of every file in the wave.
2. Run read-only inspection work concurrently when the backend and machine can
   support it.
3. Generate at most one patch proposal per target file.
4. Collect proposals without writing them.
5. Check base revisions, duplicate ownership, and overlapping anchors.
6. Present diffs through existing approval behavior.
7. Apply approved files atomically.
8. Refresh the index and task state.
9. Run focused validation before dependent waves.

Dependent tasks must see the accepted output of their dependencies, not the
stale initial snapshot. A rejected or failed dependency blocks its dependants
with an explicit reason.

### Concurrency policy

Defaults:

- on-device Apple model: one inference executor;
- PCC or remote OpenAI-compatible backend: configurable, initially no more
  than three executor calls;
- filesystem inspection and deterministic outline generation: bounded local
  parallelism independent of model inference; and
- file application: serialized through the coordinator.

Parallelism improves latency for independent files. It does not increase the
amount of source a single executor can understand and is not a substitute for
range selection. Multiple bounded executors can increase aggregate source
coverage, but their combined request limits are not a shared context window;
the coordinator can use only the evidence that survives their bounded reports
and its own request budget.

### Same-file parallelism

Do not enable concurrent same-file mutations in the initial implementation.
If later evidence justifies it, workers may produce proposals for disjoint
ranges against the same immutable digest. The coordinator must then prove that
anchors are unique and non-overlapping, merge all hunks against the base in one
operation, show one combined diff, and validate the complete file. Any conflict
falls back to a single executor.

## Validation and recovery

Sectional editing must be validated as a whole-file operation.

After each applied file or dependency wave:

1. Confirm the file is valid UTF-8 and can be reread.
2. Regenerate its outline to catch gross structural damage.
3. Run the cheapest applicable parser/compiler check.
4. Run focused tests named by the task or inferred from the repository map.
5. Run broader validation once all waves complete when cost permits.

For this repository, normal development validation remains model-free through
`make test`. Do not make ordinary tests initialize AFM, contact an OpenAI
endpoint, or require credentials.

On failure, retain a bounded diagnostic suffix and update `TurnWorkingState`.
The repair round should reread only the failed region plus necessary context.
Set a repair-attempt cap and stop if the same validation fingerprint repeats
without a new edit or new evidence.

No automatic rollback should overwrite unrelated user changes. An
orchestrated transaction may restore only files whose current revisions still
match the revisions produced by that transaction.

## Integration with existing Turbo Agent components

### `Sources/TurboAgent/Tools/ToolRegistry.swift`

- Extend the `read_file` schema and execution path.
- Add result envelopes, range validation, outline mode, and source-result
  ceilings.
- Change shell truncation to bounded head plus tail.
- Extend `edit_file` arguments with digest and occurrence semantics.
- Guard existing-file `write_file` replacements using revision and retained
  complete-read metadata.
- Add `apply_patch` only in the later multi-hunk phase.

Keep filesystem access flowing through `AgentToolContext` so terminal, SwiftUI,
and ACP behavior remains consistent.

### `Sources/TurboAgent/Tools/AgentWritePreview.swift`

- Add `revisionRequired`, `targetAmbiguous`, `staleRevision`,
  `overlappingHunks`, and no-op errors
  or outcomes.
- Build one `AgentWritePlan` from all validated hunks.
- Retain complete-source equality immediately before writing.
- Keep bounded diff rendering and atomic file writes.

### `Sources/TurboAgent/Core/ConversationTurn.swift`

- Record structured `ToolObservation` values alongside full messages.
- Update `TurnWorkingState` after each tool completes.
- Ask the projection layer for request messages before generation.
- Keep the canonical `messages` array unmodified.

### `Sources/TurboAgent/Core/AgentContextBudget.swift`

- Separate context projection from final hard-budget trimming.
- Add tool-result compaction before dropping complete old turns.
- Report compacted observation count and estimated tokens saved.
- Continue rejecting a newest request that cannot fit after all safe
  projection steps.

Do not weaken instruction/tool-schema accounting or the output and safety
reserves.

### `Sources/TurboAgent/Core/Runtime.swift`

- Retain the most recent prepared budget/headroom for tool-result budgeting.
- Expose selected-backend concurrency capability to the orchestrator.
- Publish context telemetry to the status line.

### `Sources/TurboAgent/Backend/MCPJSONSchemaBridge.swift`

- Update AFM tool examples to demonstrate outline and range reads.
- Ensure projected compact receipts render as normal tool responses.
- Keep intermediate assistant prose suppression.
- Test optional integers, booleans, arrays of patch hunks, and new error
  results through schema conversion.

### `Sources/TurboAgent/ACP/ACPInteraction.swift`

- Continue reading complete client files through ACP, then slice locally.
- Report source ranges and revisions in tool titles/content where useful.
- Treat `apply_patch` as an edit and attach its combined diff to the permission
  request.
- Never send unbounded source or diff output in session updates.

### `Sources/TurboAgent/Memory/`

- Keep long-lived Continuity memory independent from per-turn working state.
- Durable decisions and gotchas may still be written deliberately.
- Do not automatically store source slices, tool transcripts, or file maps as
  memories.

### New modules

A possible layout is:

```text
Sources/TurboAgent/Context/
  FileRevision.swift
  FileSlicer.swift
  FileOutline.swift
  RepositoryIndex.swift
  RepositoryRetriever.swift
  TurnWorkingState.swift
  ConversationProjection.swift

Sources/TurboAgent/Orchestration/
  EditTask.swift
  TaskGraph.swift
  EditPlanner.swift
  EditExecutor.swift
  PatchCoordinator.swift
```

Keep the first phase small. `FileSlicer`, `FileRevision`, and
`ConversationProjection` provide immediate value without committing to the
full orchestrator.

## Delivery phases

### Phase 0: characterize the regression - DONE

- Add a deterministic large C fixture modeled on `AgentLineEditor.c` but
  containing no live-model dependency.
- Reproduce an 8K turn containing a whole read followed by another tool result.
- Assert the present request either overflows or has insufficient working room.
- Record baseline estimated prompt tokens and rounds completed.

Exit criterion: the test demonstrates the active-turn accumulation failure and
will distinguish a real fix from a larger static truncation limit.

### Phase 1: safe range reads and revision metadata - DONE

- Implement `FileRevision`, line-preserving slicing, and range validation.
- Extend `read_file` with `mode`, `start_line`, and `end_line`.
- Add deterministic generic, Swift, and C-family outlines.
- Return labeled partial results with digest and continuation information.
- Preserve terminal, SwiftUI, and ACP filesystem paths.
- Update compact and full system prompts with range-read guidance.

Exit criterion: an 8K model-facing request can inspect every relevant function
in the large fixture through bounded ranges, and no individual read can consume
the remaining request budget silently.

### Phase 2: safe anchored edits - DONE

- Make single replacement unique by default.
- Require `expected_digest` and add explicit `replace_all`.
- Guard whole-file replacement after partial or evicted reads; retain the
  creation path for new files.
- Add stale, ambiguous, and no-op behavior.
- Preserve preview, permission, atomic write, and source-equality checks.
- Return the new revision after a successful write.

Exit criterion: a range read can be followed by a precise edit without loading
the whole file into model context, and stale/ambiguous edits fail closed.

### Phase 3: active-turn projection and task state - DONE

- Introduce observations, receipts, and `TurnWorkingState`.
- Build ephemeral request projections without changing canonical messages.
- Compact completed tool results while preserving protocol pairing.
- Bound aggregate exchange retention and evict completed groups, including
  their source-bearing call arguments, into bounded state and evidence.
- Retain recent/failing evidence according to deterministic rules.
- Add context telemetry and status-line reporting.

Exit criterion: a long single user turn can perform repeated range reads,
edits, and validation while every inference request fits 8K and the model still
receives objective, current revisions, applied changes, and unresolved failure.

### Phase 4: repository index and retrieval briefing - DONE

- Implement safe scanning, incremental fingerprints, declarations, and cache.
- Rank path/symbol candidates against the user request.
- Inject a bounded advisory briefing only when useful.
- Rebuild touched entries after edits.

Exit criterion: representative tasks reach the correct file in fewer discovery
rounds without injecting source bodies or overflowing the context.

### Phase 5: multi-hunk patches - DONE

- Add a compact `apply_patch` schema.
- Validate all hunks against one digest and reject overlaps.
- Preview and approve one combined file diff.
- Add whole-file syntax/build validation hooks.

Exit criterion: multiple non-adjacent changes to a large file are applied
atomically without a full-file model response.

### Phase 6: optional planner and task graph - DONE

- Define and validate bounded planner output.
- Route only large/multi-file tasks through it.
- Run dependency waves with one proposal owner per file.
- Apply approved waves centrally and refresh revisions/index entries.
- Default local inference concurrency to one; permit bounded remote
  concurrency.

Exit criterion: independent multi-file edits can execute concurrently, ordered
dependencies see accepted predecessor output, and conflicts cannot overwrite
external or sibling changes.

### Phase 6b: federated context execution - DONE

- Add an optional large-file mode that partitions inspection by deterministic
  declaration or coalesced source range against one immutable file revision.
- Run a dynamically bounded set of narrow workers, up to a configurable ceiling
  such as 16. Give each worker the compact objective, its source slice with a
  small overlap, the base digest, necessary reference ranges, and a minimal
  role-specific tool catalog.
- Treat the workers' combined context limits as aggregate coverage, not as one
  shared context window. For example, sixteen 8K requests provide up to 128K of
  request capacity, but prompt overhead and isolated attention make the usable
  source coverage smaller and prevent any worker from reasoning over all of it.
- Require structured worker reports containing findings, unresolved
  references, relevant anchors, dependencies, and optional patch hunks. A
  worker must request more evidence rather than assume that its slice is
  self-contained.
- When all reports cannot fit in the coordinator request, reduce them in bounded
  groups before final synthesis. Preserve source anchors, revision identity,
  conflicts, and unresolved dependencies through every reduction level.
- Keep workers proposal-only. The coordinator verifies that all same-file hunks
  target the common digest, are uniquely anchored and non-overlapping, then
  presents and applies one combined patch through the existing approval path.
- Fall back to a focused single executor when reports conflict, dependencies
  cross too many partitions, or reduction would discard evidence required to
  justify an edit.
- Use fewer workers when the outline exposes only a small number of relevant
  sections. On-device backends may execute workers serially, improving coverage
  without promising lower latency; remote backends retain their configured
  concurrency bound.

Exit criterion: a large file whose relevant source exceeds one executor's
allowance can be inspected across bounded workers, reduced within an 8K
coordinator request, and changed through one revision-guarded atomic patch,
without representing aggregate worker capacity as shared model context.

### Phase 7: evaluation and default enablement - DONE

- Compare task success, first-correct-file rate, tool rounds, prompt tokens,
  compaction savings, stale edit rejections, and validation success.
- Test 8K Apple behavior without requiring live inference in the normal suite.
- Use explicitly requested live evaluation only for qualitative small-model
  behavior.
- Enable orchestration by default only after direct-loop regressions are ruled
  out.

## Test plan

### File slicing and outline unit tests

- Empty, one-line, trailing-newline, CRLF, and Unicode files.
- Exact first/middle/final ranges and EOF clamping.
- Invalid/reversed/oversized ranges.
- Line numbering does not alter the stored file.
- Binary and invalid UTF-8 rejection.
- Stable digest and revision change after one byte changes.
- C/Swift declaration extraction and generic fallback.
- Symlink/workspace boundary behavior through existing path policy.

### Write safety tests

- Unique target succeeds.
- Missing and duplicated targets fail distinctly.
- `replace_all` must be explicit and previews all changes.
- Stale digest fails before approval.
- Missing digest fails before approval, including with `replace_all`.
- A change between read and preview fails even if the target still matches.
- Source change after preview fails before write.
- Existing-file `write_file` rejects range-only, outline-only, compacted, and
  evicted read evidence, including in `--yolo` mode.
- A retained complete read and matching digest permit whole-file replacement.
- New-file creation remains supported and rejects a target created after preview.
- Multiple hunks apply against one base in deterministic order.
- Overlapping or ambiguous hunks apply nothing.
- Atomic write failure leaves the original intact.
- Diff previews remain bounded.

### Projection and budget tests

- A large current-turn read is replaced by a receipt on later rounds.
- The latest relevant range remains full.
- Failed-command suffix remains until new evidence resolves it.
- Assistant tool calls and tool results stay structurally valid.
- Multiple calls in one assistant message compact atomically.
- Completed groups are evicted atomically, including assistant arguments and
  prose; pending groups are never evicted.
- Repeated substantial edits whose cumulative targets and replacements exceed
  8K complete within the round limit using bounded projected exchange history.
- Receipt count and retained argument tokens stay within aggregate limits as
  rounds accumulate; required evidence survives eviction within its own cap.
- System/developer instructions and newest user request remain pinned.
- Tool schemas, working state, output reserve, and safety margin are counted.
- Projection still throws when genuinely pinned content cannot fit.
- Canonical session messages retain full results after projection.
- 8K large-file regression fixture completes several tool rounds with working
  room remaining.

### Retrieval tests

- Explicit path wins over lexical inference.
- Symbol match outranks incidental source terms.
- No-confidence query injects no briefing.
- Ignored, generated, binary, and outside-workspace paths are absent.
- Touched-file index refresh changes revision and ranges.
- Cache corruption degrades to rebuild or no briefing.
- Retrieval text is treated as data, not executable instruction.

### Orchestration tests

- Acyclic dependency waves are ordered correctly.
- Cycles and unknown dependencies are rejected.
- Duplicate write owners for one path are rejected or coalesced.
- Independent files can propose concurrently.
- Same-file edits are serialized by default.
- A changed base revision invalidates the proposal.
- Failed/rejected dependency blocks downstream tasks.
- Partial executor failure does not apply an incomplete transaction silently.
- Local model configuration never launches concurrent inference by default.
- Cancellation stops pending tasks and restores terminal state.

### Interface tests

- AFM schema formatting includes optional range fields correctly.
- OpenAI-compatible tool calls decode new arguments.
- ACP range reads and diff approvals use client filesystem callbacks.
- Terminal and SwiftUI display bounded results while retaining useful metadata.
- Status footer reports projected context and compacted observation counts.

## Telemetry and acceptance criteria

Record locally in existing runtime/status structures; do not add network
telemetry.

Useful measurements:

- estimated prompt tokens before and after projection;
- number and bytes of full versus compacted tool observations;
- source ranges read and reopened;
- retrieval candidates and whether the first read used one;
- stale or ambiguous edit rejections;
- planner retries and invalid plans;
- executor waves and concurrency;
- validation attempts and repeated failure fingerprints; and
- final dropped old-turn count.

The feature is ready for default use when:

1. Every backend request still passes the existing hard context budget.
2. The `AgentLineEditor.c`-sized regression can be inspected, edited, and
   validated through multiple rounds at an 8K limit.
3. Partial source responses are explicitly labeled, and built-in file tools
   reject whole-file replacement without a retained complete read of the
   matching revision.
4. No stale or ambiguous anchored edit is applied.
5. Full canonical conversation data remains available even when the inference
   projection uses receipts.
6. Existing small-file workflows require no planner and do not regress.
7. ACP stdout remains protocol-clean, terminal restoration remains reliable,
   and all writes remain approval-gated unless `--yolo` was explicitly used.
8. `make test` remains model-free and passes serially.

## Documentation updates at implementation time

Update these documents as phases land:

- `docs/SMALL_CONTEXT_WINDOWS.md`: range selection, active-turn projection,
  retrieval briefing, and revised failure modes.
- `docs/AGENT_TERMINAL.md`: model-facing read/edit behavior and approval UI.
- `docs/AGENT_ACP.md`: range reads and patch permission updates.
- `README.md`: short explanation of safe large-file editing.
- Tool help and both `.agents/codex_prompt.md` variants: prefer outline/range
  reads, exact anchored edits, and validation of the assembled file.

## Final recommendation

Start with phases 0–3. They directly fix the observed `AgentLineEditor.c`
failure without introducing a second agent architecture or relying on parallel
inference. Repository retrieval is the next highest-value improvement for weak
models. Add the task graph only after bounded reads, safe patches, and
active-turn projection are independently solid.

The defining invariant should be:

> A model may work on a file larger than its context window, but no model call
> needs the whole file for an anchored edit, built-in whole-file replacement
> requires a retained complete read of the matching revision, and completed
> tool exchanges need not remain in context merely because the user turn is
> still active. Retained exchanges, receipts, working state, and evidence have
> aggregate bounds independent of turn length.

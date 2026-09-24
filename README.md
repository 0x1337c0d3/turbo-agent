# Turbo Agent

A standalone native coding agent for macOS, designed for small context windows.
It supports Apple Foundation Models (AFM 3 Core and Cloud Pro via Private Cloud
Compute), OpenAI-compatible APIs, a terminal interface, a SwiftUI Mac app, and
the Agent Client Protocol used by editors such as Zed.

The project contains its own continuity memory engine and does not depend on
the TurboFieldfare Gemma/Metal runtime or model files.

## Requirements

- macOS 26 or later
- Swift 6.2 or later
- macOS 27 and Apple Silicon for Apple Foundation Models

## Build and run

```bash
make build
make run RUN_ARGS="--backend openai"
```

`make build` builds both executable products in release mode:

```text
.build/release/TurboAgent
.build/release/TurboAgentMac
```

The first product is the terminal and ACP executable. The second is the native
SwiftUI executable; a Swift package build does not wrap it in an `.app` bundle.
Set `CONFIGURATION=debug` on any build-related Make target for a debug build.

Build and sign the PCC-enabled CLI app bundle:

```bash
make build-app
.build/release/TurboAgent.app/Contents/MacOS/TurboAgent --backend apple --pcc require
```

This requires a provisioning profile with the Private Cloud Compute entitlement
and its matching code-signing identity. `Scripts/package-agent.sh` writes the
bundle to `.build/release/TurboAgent.app` by default.

Install the command-line executable under `/usr/local/bin`:

```bash
sudo make install
```

For a user-local installation, ensure `~/.local/bin` is on `PATH` and run:

```bash
make install PREFIX="$HOME/.local"
```

The install target only installs the command-line executable. It supports
`BINDIR` and `DESTDIR` overrides for custom and staged installations. The
SwiftUI executable and PCC-enabled app bundle retain their separate workflows.

Select the Apple backend with `--backend apple` and choose its PCC policy with
`--pcc disable`, `auto`, or `require`. Tool calls require approval unless the
terminal agent is launched with `--yolo`.

For OpenAI or a compatible endpoint, set `OPENAI_API_KEY`, and optionally
`OPENAI_BASE_URL` and `OPENAI_MODEL`. Persistent settings are read from
`~/.config/TurboAgent/settings.json`.

The default prompt is `.agents/codex_prompt.md`; the compact
`.agents/codex_prompt_8k.md` variant is intended for 8K context windows.

## Test

```bash
make test
```

This runs the serial Swift test suite, terminal editor and transcript tests,
and the tracked-symlink and Markdown-link checks.

## Safe large-file editing

`read_file` supports bounded, revisioned reads of files larger than the model
window. Request `mode: "outline"` to get a deterministic section map without
source bodies, then request specific ranges with `start_line` and `end_line`.
Every partial result is explicitly labeled with the file's SHA-256 revision
digest, the actual line range returned, and the continuation line to request
next. Files that fit the current request budget still return whole; files
that do not are never silently truncated.

Edits are anchored against that revision: `edit_file` requires the
`expected_digest` from a read, replaces its exact `target` once (ambiguous
targets fail unless `replace_all` is explicit), and returns the new revision
digest after the approved write. `write_file` replaces an existing file only
after a complete read of its current revision; range or outline reads never
authorize whole-file replacement. New-file creation is unchanged. See
[large-file editing](docs/LARGE_FILE_EDITING.md) for the plan this implements.

## Documentation

- [Small context windows](docs/SMALL_CONTEXT_WINDOWS.md)
- [Terminal interface](docs/AGENT_TERMINAL.md)
- [MCP configuration](docs/AGENT_MCP.md)
- [ACP and Zed setup](docs/AGENT_ACP.md)
- [Hybrid AFM/OpenAI backends](docs/HYBRID_AI.md)
- [Security review](docs/AGENT_SECURITY_REVIEW.md)
- [AFM 3 PCC notes](docs/afm3-pcc.md)
- [ContinuityCore](Sources/ContinuityCore/README.md)

The `project.yml` XcodeGen project and `TurboAgent.entitlements` are
provided for builds that require the Private Cloud Compute entitlement.

## License

Apache-2.0. See [LICENSE](LICENSE).

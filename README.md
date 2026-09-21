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
- Apple Silicon for Apple Foundation Models

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

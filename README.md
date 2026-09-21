# TurboFieldfare Agent

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
swift build -c release --product TurboFieldfareAgent
swift build -c release --product TurboFieldfareAgentMac

.build/release/TurboFieldfareAgent --backend openai
.build/release/TurboFieldfareAgentMac
```

Select the Apple backend with `--backend apple` and choose its PCC policy with
`--pcc disable`, `auto`, or `require`. Tool calls require approval unless the
terminal agent is launched with `--yolo`.

For OpenAI or a compatible endpoint, set `OPENAI_API_KEY`, and optionally
`OPENAI_BASE_URL` and `OPENAI_MODEL`. Persistent settings are read from
`~/.config/TurboFieldfareAgent/settings.json`.

The default prompt is `.agents/codex_prompt.md`; the compact
`.agents/codex_prompt_8k.md` variant is intended for 8K context windows.

## Test

```bash
Scripts/test.sh
python3 Scripts/test-agent-editor.py
python3 Scripts/test-agent-transcript.py
ruby Scripts/check_tracked_symlinks.rb
ruby Scripts/check_markdown_links.rb
```

## Documentation

- [Terminal interface](docs/AGENT_TERMINAL.md)
- [MCP configuration](docs/AGENT_MCP.md)
- [ACP and Zed setup](docs/AGENT_ACP.md)
- [Hybrid AFM/OpenAI backends](docs/HYBRID_AI.md)
- [Security review](docs/AGENT_SECURITY_REVIEW.md)
- [AFM 3 PCC notes](docs/afm3-pcc.md)
- [ContinuityCore](Sources/ContinuityCore/README.md)

The `project.yml` XcodeGen project and `TurboFieldfareAgent.entitlements` are
provided for builds that require the Private Cloud Compute entitlement.

## License

Apache-2.0. See [LICENSE](LICENSE).

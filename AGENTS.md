# TurboFieldfare Agent

Native Swift coding agent for macOS with terminal, SwiftUI, ACP, MCP, Apple
Foundation Models, OpenAI-compatible backends, and continuity memory support.

## Layout

- `Sources/TurboFieldfareAgent/`: shared agent core
- `Sources/TurboFieldfareAgentCLI/`: terminal and ACP executable entry point
- `Sources/TurboFieldfareAgentApp/`: native SwiftUI app
- `Sources/ContinuityCore/`: context, memory, journal, and provenance engine
- `Sources/AgentLineEditor/`: libedit bridge
- `Tests/TurboFieldfareAgent/`: model-free agent tests
- `docs/`: usage, protocol, backend, and security documentation

## Commands

```bash
swift build -c release
Scripts/test.sh
python3 Scripts/test-agent-editor.py
python3 Scripts/test-agent-transcript.py
ruby Scripts/check_tracked_symlinks.rb
ruby Scripts/check_markdown_links.rb
```

Run Swift package tests serially through `Scripts/test.sh`. Tests and ordinary
builds must not initialize an inference backend, contact a remote model, or
require credentials. Do not run a live AFM or OpenAI request unless the user
explicitly asks.

Preserve Swift concurrency isolation, keep ACP stdout free of diagnostics, and
keep terminal restoration and tool approval behavior fail-closed. Do not expose
secrets from environment variables or `~/.config/TurboFieldfareAgent`.

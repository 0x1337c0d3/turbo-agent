# Agent inference backends

`TurboAgentCore` is independent of Turbo's Gemma/Metal
runtime. It owns API-neutral conversation, tool, and JSON schema types and has
no dependency on `Turbo`, `TurboCLICore`, or
`TurboServerCore`.

Two front ends consume the core:

- `TurboAgent` is the terminal REPL and ACP server.
- `TurboAgentMac` is the native SwiftUI chat app.

Both support three concrete targets: AFM 3 Core on-device, AFM Cloud Pro over
Private Cloud Compute, and an OpenAI-compatible Chat Completions endpoint.
Changing backend in the Mac app starts a new conversation so history is never
silently sent to a different provider.

## Configuration

The CLI selects a backend explicitly:

```bash
TurboAgent --backend apple --pcc disable
TurboAgent --backend apple --pcc require
TurboAgent --backend openai
```

OpenAI-compatible settings can be provided directly through the environment:

```bash
export OPENAI_API_KEY=...
export OPENAI_BASE_URL=https://api.openai.com/v1/
export OPENAI_MODEL=gpt-4o
```

The existing `~/.config/TurboAgent/settings.json` is also supported:

```json
{
  "openai_api_key": "$OPENAI_API_KEY",
  "openai_base_url": "https://api.openai.com/v1/",
  "openai_model": "gpt-4o"
}
```

## Privacy and permissions

AFM Core is the only on-device target. AFM PCC and OpenAI-compatible endpoints
are cloud targets. The GUI asks before each tool call; the CLI does the same by
default. `--yolo` is CLI-only and must be selected explicitly. Switching the
GUI's backend clears the conversation so prior content is not moved between
local and cloud backends without a visible context reset.

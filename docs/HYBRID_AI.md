# Agent inference backends

`TurboFieldfareAgentCore` is independent of TurboFieldfare's Gemma/Metal
runtime. It owns API-neutral conversation, tool, and JSON schema types and has
no dependency on `TurboFieldfare`, `TurboFieldfareCLICore`, or
`TurboFieldfareServerCore`.

Two front ends consume the core:

- `TurboFieldfareAgent` is the terminal REPL and ACP server.
- `TurboFieldfareAgentMac` is the native SwiftUI chat app.

Both support three concrete targets: AFM 3 Core on-device, AFM Cloud Pro over
Private Cloud Compute, and an OpenAI-compatible Chat Completions endpoint.
Changing backend in the Mac app starts a new conversation so history is never
silently sent to a different provider.

## Configuration

The CLI selects a backend explicitly:

```bash
TurboFieldfareAgent --backend apple --pcc disable
TurboFieldfareAgent --backend apple --pcc require
TurboFieldfareAgent --backend openai
```

OpenAI-compatible settings can be provided directly through the environment:

```bash
export OPENAI_API_KEY=...
export OPENAI_BASE_URL=https://api.openai.com/v1/
export OPENAI_MODEL=gpt-4o
```

The existing `~/.config/TurboFieldfareAgent/settings.json` is also supported:

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

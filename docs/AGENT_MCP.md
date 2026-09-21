# Agent MCP settings

TurboFieldfareAgent reads `~/.config/TurboFieldfareAgent/settings.json` at
startup and when you enter `/mcp reload`. Use `/mcp` to see configured servers.

```json
{
  "mcpServers": {
    "bugcrowd-mcp": {
      "url": "https://stream.bugcrowd.com/mcp",
      "env_http_headers": {
        "Authorization": "BUGCROWD_MCP_AUTH"
      }
    }
  }
}
```

`env_http_headers` maps HTTP header names to environment variable names, as
in Codex. Export `BUGCROWD_MCP_AUTH` in the shell that launches the agent. Its
value must be the complete Authorization header value expected by the server
(including any required authentication scheme). The value is used verbatim;
no `Bearer ` prefix is added and no shell expressions are evaluated.

Missing or empty referenced variables cause that server to be skipped with an
error naming the variable. Values are not printed or saved to settings.
Changing an exported variable in a parent shell requires restarting the agent;
`/mcp reload` reads the running agent's environment.

Static `http_headers` and the existing `headers` field are also supported.
Environment headers override static headers, comparing names without case.
`http_headers` overrides `headers`.

A URL selects Streamable HTTP by default (`"type": "http"` or
`"streamable-http"` is also accepted). This supports initialization, session
headers, paginated tool discovery, and tool calls with JSON or SSE responses.
Legacy HTTP+SSE transport is no longer supported. Configurations with
`"type": "sse"` are skipped with a migration message. Use the server's
Streamable HTTP endpoint and remove `type` or set it to `"http"`.
SSE response bodies remain supported as part of Streamable HTTP.
Local process settings using `command`, `args`, and `env` are unchanged.

Discovered tool schemas are adapted to Gemma's chat-template format before
being advertised to the model. Nullable types and bare objects are supported.
Schemas the template cannot represent are skipped with a diagnostic naming
the tool and schema field; other tools remain available.

## Tool permissions and connection boundaries

Each model-requested file, shell, URL, or MCP action now displays its full
arguments and requires `y` or `yes`. Empty input, EOF, and non-interactive input
are denied. Delegated tasks share this policy and a 64-call budget per user
turn; delegation is limited to four nested subagents and each conversation
loop to 32 generation rounds. Explicit `!command` input remains a direct user
instruction and runs without another approval.

Approving a shell command gives that command the agent process's user access;
this is an approval boundary, not an operating-system sandbox. Configured local
MCP server programs are trusted configuration and still start automatically.

Remote MCP redirects must remain on the
configured HTTP(S) origin (same scheme, host, and effective port). MCP tools
cannot override built-in tool names, and execution routes only through the
discovered catalog. Terminal control bytes from model/tool text are displayed
as escaped text rather than executed by the terminal.

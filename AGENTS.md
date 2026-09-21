# Turbo Agent

Native Swift coding agent for macOS with terminal, SwiftUI, ACP, MCP, Apple
Foundation Models, OpenAI-compatible backends, and continuity memory support.

## Layout

- `Sources/TurboAgent/`: shared agent core
- `Sources/TurboAgentCLI/`: terminal and ACP executable entry point
- `Sources/TurboAgentApp/`: native SwiftUI app
- `Sources/ContinuityCore/`: context, memory, journal, and provenance engine
- `Sources/AgentLineEditor/`: libedit bridge
- `Tests/TurboAgent/`: model-free agent tests
- `docs/`: usage, protocol, backend, and security documentation

## Commands

```bash
make build
make run RUN_ARGS="--backend openai"
make test
make install PREFIX="$HOME/.local"
make build-app
```

`make build` builds the `TurboAgent` CLI/ACP executable and the `TurboAgentMac`
SwiftUI executable. It does not create an app bundle. `make build-app` also runs
`Scripts/package-agent.sh` to create and sign the PCC-enabled CLI bundle at
`.build/<configuration>/TurboAgent.app`; it requires the managed PCC
provisioning profile and matching keychain identity. `make install` installs
only the CLI and supports `PREFIX`, `BINDIR`, and `DESTDIR`.

Run the complete model-free test suite through `make test`; its Swift package
tests run serially through `Scripts/test.sh`. Tests and ordinary builds must not
initialize an inference backend, contact a remote model, or require credentials.
Do not run `make build-app` or a live AFM/OpenAI request unless the user
explicitly asks because signing accesses developer credentials.

Preserve Swift concurrency isolation, keep ACP stdout free of diagnostics, and
keep terminal restoration and tool approval behavior fail-closed. Do not expose
secrets from environment variables or `~/.config/TurboAgent`.

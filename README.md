# VoiceCoder

Voice coding for developers who can’t use a keyboard or mouse reliably. Speak a request, a local Parakeet model turns it into text, and Claude Code edits a project you can see in VS Code Web.

This repo wires the [bridge](https://github.com/TheAtlantaDream/voicecoder-bridge), [frontend](frontend/), and a Coder [template](template/) together.

## Run locally (Docker Compose)

You need Docker with Compose v2. First boot builds images and downloads the Parakeet model (~650MB).

```bash
cp .env.example .env
# edit .env and set ANTHROPIC_API_KEY=...

./scripts/run-local.sh
```

Open **http://127.0.0.1:8080/**. Say `hey VoiceCoder` or `Coder`, then your request.

```bash
./scripts/run-local.sh logs    # follow container logs
./scripts/run-local.sh down    # stop and remove containers
```

The script reads `ANTHROPIC_API_KEY` from `.env` (never commit that file). With a key set it enables the agent (`BRIDGE_AGENT=agentapi`); without one the stack still runs but only transcribes.

Agent and VS Code Web share one Docker volume (`voicecoder-local-home`) so edits show up in the editor.

## Coder workspace

Use the template under `template/` on a Coder deployment. Workspace setup runs the same Compose stack on the host Docker socket.

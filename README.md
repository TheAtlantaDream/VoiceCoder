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
=======
VoiceCoder lets developers who can't reliably use a keyboard or mouse write
code by voice. You speak a request, a local speech model turns it into text,
Claude Code makes the change in a real project, and the result shows up live
in a browser-based VS Code.

This is the **outer/umbrella repository**: it wires the other two repos
together as git submodules, holds the Coder workspace template that boots
the whole stack, and provides the top-level Docker Compose entry point.

```
Browser (Coder app proxy, HTTPS)
  │
  ├─ frontend page (nginx :80) ──── /vscode/ ──► openvscode-server :3000
  │        │
  │        ▼
  └─ WebSocket /ws ──► bridge (Go)
                          ├─ POST /inference ──► Parakeet TDT / whisper.cpp-compatible STT server
                          └─ agent: AgentAPI ─► Claude Code (in ~/project)
                                      or `claude -p` directly, or a fake agent for local testing
```

## Repositories

| Repo | Role |
| --- | --- |
| [VoiceCoder](https://github.com/TheAtlantaDream/VoiceCoder) (this repo) | Coder workspace template, Docker Compose entry point, submodule wiring |
| [voicecoder-bridge](https://github.com/TheAtlantaDream/voicecoder-bridge) | Go server: speech-to-text, text cleaning, and the WebSocket/agent protocol. See its [README](https://github.com/TheAtlantaDream/voicecoder-bridge#readme) for the full protocol, flags, and agent modes. |
| [voicecoder-frontend](https://github.com/TheAtlantaDream/voicecoder-frontend) | React + TypeScript single page: microphone capture, live transcript, agent replies, embedded VS Code Web |

## Layout

```
VoiceCoder/
├── docker-compose.yml           include: ./bridge/docker-compose.yml + ./frontend/docker-compose.yml
├── scripts/update_submodules.sh git submodule update --remote; git add frontend bridge
├── template/                    Coder workspace template (main.tf + setup.sh)
├── bridge/   -> submodule       github.com/TheAtlantaDream/voicecoder-bridge
└── frontend/ -> submodule       github.com/TheAtlantaDream/voicecoder-frontend
```

## Running it as a Coder workspace (recommended)

`template/` is a self-contained [Coder](https://coder.com) template
(`main.tf` + `setup.sh`) that, per workspace:

1. Clones this repo and its submodules.
2. Installs the Docker CLI/Compose plugin and starts the frontend, bridge,
   and speech-to-text containers in the background (images are tagged
   `voicecoder-*:latest` and shared host-wide, so only the first boot on a
   host pays for a full build).
3. Exposes a single `frontend` app (subdomain, owner-only share) that serves
   the VoiceCoder UI with VS Code Web embedded at `/vscode/`.
4. Accepts an `Anthropic API Key` workspace parameter. Without it the stack
   still runs and transcribes/cleans speech, just without a coding agent.

Push this template to a Coder deployment (or point `coder templates push` at
`template/`) and create a workspace from it.

## Running it locally with Docker Compose

```
git clone --recurse-submodules https://github.com/TheAtlantaDream/VoiceCoder.git
cd VoiceCoder
docker compose up --build
```

This includes `bridge/docker-compose.yml` and `frontend/docker-compose.yml`,
which build and start the bridge, the speech-to-text server, the frontend
(nginx), and `openvscode-server`. See each submodule's README for the
environment variables each service accepts (`ANTHROPIC_API_KEY`,
`BRIDGE_AGENT`, `PARAKEET_MODEL`, port publishing, etc.).

If you cloned without `--recurse-submodules`, run:

```
git submodule update --init
```

The `.gitmodules` URLs must use `https://`, not `git@`/SSH, or the update
will fail without SSH keys configured.

## Updating the submodule pointers

After pushing changes inside `bridge/` or `frontend/` on their own `main`
branch, update this repo's pointers to the new commits:

```
./scripts/update_submodules.sh
git commit -m "Update bridge/frontend submodules"
git push
```

Never commit an outer pointer to a submodule commit that hasn't been pushed
to that submodule's own repo first.

## License

See the individual submodules for their license terms.

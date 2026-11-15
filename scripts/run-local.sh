#!/usr/bin/env bash
# Run VoiceCoder on this machine with Docker Compose (same stack as a Coder workspace).
#
# Usage:
#   cp .env.example .env   # then set ANTHROPIC_API_KEY
#   ./scripts/run-local.sh
#   ./scripts/run-local.sh down
#   ./scripts/run-local.sh logs
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { echo "[run-local] $*"; }
die() { echo "[run-local] error: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "need $1 on PATH"
}

need_cmd docker
docker compose version >/dev/null 2>&1 || die "need Docker Compose v2 (docker compose)"

cmd="${1:-up}"

load_env() {
  if [ ! -f .env ]; then
    if [ -f .env.example ]; then
      die "missing .env — copy .env.example to .env and set ANTHROPIC_API_KEY"
    fi
    die "missing .env (create one with ANTHROPIC_API_KEY=...)"
  fi
  # Export keys for compose interpolation and this script.
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
}

# One shared volume so the agent (/home/coder/project) and VS Code Web
# (/home/workspace/project) see the same files — same trick as Coder.
export VC_HOME_VOLUME="${VC_HOME_VOLUME:-voicecoder-local-home}"
export VC_HOME_EXTERNAL="${VC_HOME_EXTERNAL:-false}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-voicecoder-local}"
export DOCKER_BUILDKIT=1

# Avoid clashing with host services; whisper/bridge stay loopback-only.
export FRONTEND_PUBLISH="${FRONTEND_PUBLISH:-8080:80}"
export BRIDGE_PUBLISH="${BRIDGE_PUBLISH:-127.0.0.1:8000:8000}"
export WHISPER_PUBLISH="${WHISPER_PUBLISH:-127.0.0.1:18080:8080}"
export VSCODE_PUBLISH="${VSCODE_PUBLISH:-127.0.0.1:3000:3000}"

case "$cmd" in
  down|stop)
    load_env
    log "stopping $COMPOSE_PROJECT_NAME"
    docker compose down
    exit 0
    ;;
  logs)
    load_env
    shift || true
    docker compose logs -f "$@"
    exit 0
    ;;
  up|start|"")
    ;;
  *)
    die "unknown command '$cmd' (use up | down | logs)"
    ;;
esac

load_env

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  log "ANTHROPIC_API_KEY is empty in .env — bridge will only transcribe (no agent)"
  export BRIDGE_AGENT="${BRIDGE_AGENT:-none}"
else
  export BRIDGE_AGENT="${BRIDGE_AGENT:-agentapi}"
  log "ANTHROPIC_API_KEY loaded — agent enabled (BRIDGE_AGENT=$BRIDGE_AGENT)"
fi

if [ -f .gitmodules ]; then
  log "updating submodules"
  git submodule update --init --recursive
fi

log "building whisper + bridge"
docker compose build whisper bridge

log "downloading Parakeet model (skipped if already valid on volume $VC_HOME_VOLUME / whisper models)"
docker compose --profile setup run --rm model-download

log "building remaining images (if needed) and starting stack"
docker compose build
docker compose up -d --force-recreate

log "waiting for whisper healthz"
ok=0
for _ in $(seq 1 60); do
  if docker compose exec -T whisper curl -sf http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
if [ "$ok" != 1 ]; then
  log "whisper not healthy yet — check: docker compose logs whisper"
else
  log "whisper is up (model may still be loading; /ready comes later)"
fi

frontend_host_port="${FRONTEND_PUBLISH%%:*}"
cat <<EOF

VoiceCoder is starting.

  UI:  http://127.0.0.1:${frontend_host_port}/
  Mic needs a secure context (localhost is fine).

Say "hey VoiceCoder" or "Coder", then your request.

Logs:  ./scripts/run-local.sh logs
Stop:  ./scripts/run-local.sh down

EOF

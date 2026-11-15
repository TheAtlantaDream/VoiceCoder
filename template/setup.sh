#!/usr/bin/env bash
# VoiceCoder workspace setup. Safe to run twice.
# Keep this script short so the Coder agent stays connected. Heavy Compose
# work runs in the background; images are shared host-wide (voicecoder-*:latest).
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export DEBIAN_FRONTEND=noninteractive
mkdir -p ~/bin ~/.local ~/logs ~/project
log(){ echo "[setup] $*"; }
export PATH=$HOME/bin:$PATH
case $(uname -m) in x86_64) GOARCH=amd64;; aarch64) GOARCH=arm64;; esac
ORG=https://github.com/TheAtlantaDream

# Minimal host tools. Claude Code runs inside the agent container — do not
# install Node/Claude into the workspace (that was a major first-boot cost).
if ! command -v socat >/dev/null; then
  log "installing socat"
  sudo -n apt-get update -qq && sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat
fi
if [ ! -x ~/bin/docker ]; then
  log "installing docker cli"
  curl -sL "https://download.docker.com/linux/static/stable/$(uname -m)/docker-28.5.1.tgz" | tar -xz -C /tmp
  mv /tmp/docker/docker ~/bin/
fi
if [ ! -x ~/.docker/cli-plugins/docker-compose ]; then
  log "installing compose plugin"
  mkdir -p ~/.docker/cli-plugins
  curl -sL -o ~/.docker/cli-plugins/docker-compose "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)"
  chmod +x ~/.docker/cli-plugins/docker-compose
fi
[ -w /var/run/docker.sock ] || sudo -n chmod 666 /var/run/docker.sock

# Repos
sync_repo(){ if [ -d ~/$1/.git ]; then git -C ~/$1 pull --ff-only -q || log "pull skipped for $1"; else git clone -q $ORG/$2 ~/$1 || log "clone skipped for $2"; fi; }
sync_repo voicecoder VoiceCoder
[ -d ~/project/.git ] || git -C ~/project init -q
git config --global user.email >/dev/null || {
  git config --global user.name "VoiceCoder User"
  git config --global user.email "voicecoder@localhost"
}
mkdir -p ~/.claude
if ! grep -q "# VoiceCoder rules" ~/.claude/CLAUDE.md 2>/dev/null; then
  [ -s ~/.claude/CLAUDE.md ] && echo >> ~/.claude/CLAUDE.md
  cat >> ~/.claude/CLAUDE.md <<'RULES'
# VoiceCoder rules
- Work only inside the project folder you were started in. Never run git push.
- Never commit unless the user says "approve". On approve, commit all current changes with a short message describing them.
- If a request is unclear, ask one short clarifying question and change nothing until the user answers.
- You may install packages or download what a request needs. Say so in your summary when you do.
- Use your judgment on whether to run the project's tests after a change, based on how the user has set up and is using them. Whenever you do run tests, say in your summary whether they passed.
- End every reply with a summary of at most five sentences. Write it as plain text with no symbols or markdown, describing in everyday language what you did and what it means for the user. Do not make it overly technical.
RULES
  log "wrote VoiceCoder rules to ~/.claude/CLAUDE.md"
fi

if [ ! -d ~/voicecoder/.git ]; then
  log "skip compose: ~/voicecoder missing"
  exit 0
fi

cd ~/voicecoder
git submodule update -q --init || log "submodule update failed"

export COMPOSE_PROJECT_NAME="${VC_COMPOSE_PROJECT:-voicecoder}"
export FRONTEND_PUBLISH="${VC_FRONTEND_PORT:-80}:80"
export BRIDGE_PUBLISH="${VC_BRIDGE_PORT:-8000}:8000"
export WHISPER_PUBLISH="${VC_WHISPER_PORT:-8080}:8080"
export VSCODE_PUBLISH="${VC_VSCODE_PORT:-3000}:3000"
export VC_HOME_EXTERNAL=true
export DOCKER_BUILDKIT=1
# One image at a time — parallel builds on the shared Docker host cause agent disconnects.
export COMPOSE_PARALLEL_LIMIT=1
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then export BRIDGE_AGENT=agentapi; else log "no API key: bridge only transcribes"; fi
rm -f docker-compose.override.yml

# Reuse host-wide image tags (voicecoder-whisper, etc.), not per-workspace names.
need_build=0
for img in voicecoder-whisper voicecoder-bridge voicecoder-agent voicecoder-frontend; do
  if ! docker image inspect "${img}:latest" >/dev/null 2>&1; then
    need_build=1
    break
  fi
done

# Background bring-up so this coder_script exits quickly and the agent stays up.
cat > ~/logs/compose-boot.sh <<'BOOT'
#!/usr/bin/env bash
set -uo pipefail
cd ~/voicecoder
# shellcheck disable=SC1090
set -a; [ -f ~/logs/compose-env ] && . ~/logs/compose-env; set +a
log(){ echo "[compose-boot] $*"; }

# Always rebuild whisper + bridge (BuildKit cache makes this cheap when
# unchanged). Shared :latest tags otherwise leave workspaces on old binaries —
# e.g. wake-word fixes never landed because bridge was skipped when images existed.
log "building whisper + bridge (cached unless sources changed)"
docker compose build whisper bridge > ~/logs/compose-build-core.log 2>&1 || {
  log "whisper/bridge build failed — see ~/logs/compose-build-core.log"
  exit 1
}

log "ensuring Parakeet model volume (shared host-wide; incomplete trees are wiped)"
docker compose --profile setup run --rm model-download > ~/logs/model-download.log 2>&1 || {
  log "model download failed — see ~/logs/model-download.log"
  exit 1
}

if [ "${VC_NEED_BUILD:-0}" = 1 ]; then
  log "building remaining shared images (first workspace on this host)"
  docker compose build > ~/logs/compose-build.log 2>&1 || {
    log "build failed — see ~/logs/compose-build.log"
    exit 1
  }
fi

log "starting services (force-recreate so new bridge/whisper images are used)"
docker compose up -d --force-recreate --no-build > ~/logs/compose.log 2>&1 || \
  docker compose up -d --force-recreate > ~/logs/compose.log 2>&1 || {
    log "compose up failed — see ~/logs/compose.log"
    exit 1
  }

for _ in $(seq 1 60); do
  if docker compose exec -T whisper curl -sf http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    log "OK whisper"
    break
  fi
  sleep 5
done
docker compose up -d --force-recreate bridge >/dev/null 2>&1 || true
log "done"
BOOT
chmod +x ~/logs/compose-boot.sh

# Persist env for the background job
cat > ~/logs/compose-env <<EOF
export PATH=$HOME/bin:\$PATH
export COMPOSE_PROJECT_NAME='$COMPOSE_PROJECT_NAME'
export FRONTEND_PUBLISH='$FRONTEND_PUBLISH'
export BRIDGE_PUBLISH='$BRIDGE_PUBLISH'
export WHISPER_PUBLISH='$WHISPER_PUBLISH'
export VSCODE_PUBLISH='$VSCODE_PUBLISH'
export VC_HOME_EXTERNAL=true
export VC_HOME_VOLUME='${VC_HOME_VOLUME:-}'
export DOCKER_BUILDKIT=1
export COMPOSE_PARALLEL_LIMIT=1
export BRIDGE_AGENT='${BRIDGE_AGENT:-none}'
export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:-}'
export ANTHROPIC_MODEL='${ANTHROPIC_MODEL:-}'
export VC_NEED_BUILD='$need_build'
EOF

if [ -f ~/logs/compose-boot.pid ] && kill -0 "$(cat ~/logs/compose-boot.pid)" 2>/dev/null; then
  log "compose boot already running pid=$(cat ~/logs/compose-boot.pid)"
else
  log "starting compose in background (need_build=$need_build) — progress: ~/logs/compose-boot.log"
  nohup ~/logs/compose-boot.sh > ~/logs/compose-boot.log 2>&1 &
  echo $! > ~/logs/compose-boot.pid
fi

# Socat: keep trying until frontend publishes (also background).
cat > ~/logs/frontend-proxy.sh <<'PROXY'
#!/usr/bin/env bash
set -uo pipefail
port="${VC_FRONTEND_PORT:-80}"
for _ in $(seq 1 120); do
  gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
  [ -z "$gw" ] && gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  if [ -n "$gw" ] && command -v socat >/dev/null; then
    if [ -f ~/logs/frontend-proxy.pid ]; then kill "$(cat ~/logs/frontend-proxy.pid)" 2>/dev/null || true; fi
    nohup socat TCP-LISTEN:8088,bind=127.0.0.1,fork,reuseaddr "TCP:${gw}:${port}" > ~/logs/frontend-proxy.log 2>&1 &
    echo $! > ~/logs/frontend-proxy.pid
    # Wait until something answers on the published frontend port via the proxy.
    for _ in $(seq 1 90); do
      if (echo > /dev/tcp/127.0.0.1/8088) >/dev/null 2>&1; then
        echo "[proxy] OK 127.0.0.1:8088 -> ${gw}:${port}"
        exit 0
      fi
      sleep 2
    done
  fi
  sleep 5
done
echo "[proxy] gave up waiting for frontend"
exit 1
PROXY
chmod +x ~/logs/frontend-proxy.sh
nohup env VC_FRONTEND_PORT="${VC_FRONTEND_PORT:-80}" ~/logs/frontend-proxy.sh > ~/logs/frontend-proxy-boot.log 2>&1 &

log "setup script finished (compose continues in background)"
exit 0

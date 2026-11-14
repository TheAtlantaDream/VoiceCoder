#!/usr/bin/env bash
# VoiceCoder workspace setup. Safe to run twice.
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
mkdir -p ~/bin ~/.local ~/logs ~/project
log(){ echo "[setup] $*"; }
export PATH=$HOME/bin:$HOME/.local/go/bin:$HOME/.local/node/bin:$PATH
case $(uname -m) in x86_64) GOARCH=amd64; NARCH=x64;; aarch64) GOARCH=arm64; NARCH=arm64;; esac
ORG=https://github.com/TheAtlantaDream

# 1. tools
if ! command -v cmake >/dev/null || ! command -v socat >/dev/null; then sudo -n apt-get update -qq && sudo -n apt-get install -y -qq cmake build-essential socat; fi
if [ ! -x ~/.local/go/bin/go ]; then log "installing go"; V=$(curl -s "https://go.dev/VERSION?m=text" | head -1); curl -sL https://go.dev/dl/$V.linux-$GOARCH.tar.gz | tar -C ~/.local -xz; fi
if [ ! -x ~/.local/node/bin/node ]; then log "installing node"; F=$(curl -s https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | grep "linux-$NARCH.tar.xz" | awk '{print $2}'); mkdir -p ~/.local/node; curl -sL https://nodejs.org/dist/latest-v22.x/$F | tar -xJ -C ~/.local/node --strip-components=1; fi
grep -q voicecoder-path ~/.bashrc 2>/dev/null || echo 'export PATH=$HOME/bin:$HOME/.local/go/bin:$HOME/.local/node/bin:$PATH # voicecoder-path' >> ~/.bashrc
if [ ! -x ~/bin/agentapi ]; then log "installing agentapi"; curl -sL -o ~/bin/agentapi https://github.com/coder/agentapi/releases/latest/download/agentapi-linux-$GOARCH; chmod +x ~/bin/agentapi; fi
command -v claude >/dev/null || { log "installing claude code"; npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; }

# 2. repos
sync_repo(){ if [ -d ~/$1/.git ]; then git -C ~/$1 pull --ff-only -q || log "pull skipped for $1"; else git clone -q $ORG/$2 ~/$1 || log "clone skipped for $2 (not pushed yet?)"; fi; }
sync_repo voicecoder VoiceCoder
[ -d ~/project/.git ] || git -C ~/project init -q
git config --global user.email >/dev/null || { git config --global user.name "VoiceCoder User"; git config --global user.email "voicecoder@localhost"; }

# agent rules for the whole workspace: create, or append if our section is missing. Never overwrite.
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

# 3. services. Compose runs on the host Docker. The frontend proxies /ws to the bridge and /vscode/ to VS Code.
up(){ (echo > /dev/tcp/${2:-127.0.0.1}/$1) >/dev/null 2>&1; }
start(){ n=$1; p=$2; shift 2; if up $p; then log "$n already on $p"; else log "starting $n on $p"; nohup "$@" > ~/logs/$n.log 2>&1 & disown; fi; }

if [ ! -x ~/bin/docker ]; then log "installing docker cli"; curl -sL https://download.docker.com/linux/static/stable/$(uname -m)/docker-28.5.1.tgz | tar -xz -C /tmp && mv /tmp/docker/docker ~/bin/; fi
if [ ! -x ~/.docker/cli-plugins/docker-compose ]; then log "installing compose plugin"; mkdir -p ~/.docker/cli-plugins; curl -sL -o ~/.docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m); chmod +x ~/.docker/cli-plugins/docker-compose; fi
[ -w /var/run/docker.sock ] || sudo -n chmod 666 /var/run/docker.sock

if [ -d ~/voicecoder/.git ]; then
  cd ~/voicecoder
  git submodule update -q --init --remote || log "submodule update failed"

  export COMPOSE_PROJECT_NAME="${VC_COMPOSE_PROJECT:-voicecoder}"
  export FRONTEND_PUBLISH="${VC_FRONTEND_PORT:-80}:80"
  export BRIDGE_PUBLISH="${VC_BRIDGE_PORT:-8000}:8000"
  export WHISPER_PUBLISH="${VC_WHISPER_PORT:-8080}:8080"
  export VSCODE_PUBLISH="${VC_VSCODE_PORT:-3000}:3000"
  export VC_HOME_EXTERNAL=true
  rm -f docker-compose.override.yml

  log "downloading whisper model into the compose volume"
  docker compose --profile setup run --rm model-download > ~/logs/model-download.log 2>&1 || log "model download failed, see ~/logs/model-download.log"
  log "docker compose up (first build takes several minutes)"
  docker compose up -d --build > ~/logs/compose.log 2>&1 || log "compose up failed, see ~/logs/compose.log"
  cd ~

  # Agent dials 127.0.0.1 only. Forward that to the host port where Compose published nginx.
  gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
  if [ -z "$gw" ]; then gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}'); fi
  port="${VC_FRONTEND_PORT:-80}"
  if [ -n "$gw" ] && command -v socat >/dev/null; then
    if [ -f ~/logs/frontend-proxy.pid ]; then kill "$(cat ~/logs/frontend-proxy.pid)" 2>/dev/null || true; fi
    nohup socat TCP-LISTEN:8088,bind=127.0.0.1,fork,reuseaddr "TCP:${gw}:${port}" > ~/logs/frontend-proxy.log 2>&1 &
    echo $! > ~/logs/frontend-proxy.pid
    log "frontend proxy 127.0.0.1:8088 -> ${gw}:${port}"
  else
    log "frontend proxy skipped (gateway=${gw:-missing})"
  fi
else
  log "skip compose: ~/voicecoder missing"
fi

if [ -d ~/project/.git ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then start agentapi 3284 bash -c 'cd ~/project && exec agentapi server --type=claude -- claude'; else log "skip agentapi: needs ~/project and API key"; fi

sleep 3
up 8088 127.0.0.1 && log "OK   frontend (127.0.0.1:8088)" || log "DOWN frontend (127.0.0.1:8088)"
up 3284 && log "OK   agentapi (3284)" || log "DOWN agentapi (3284)"
exit 0

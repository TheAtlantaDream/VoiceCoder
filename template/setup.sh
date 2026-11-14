#!/usr/bin/env bash
# VoiceCoder workspace setup. Safe to run twice.
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
RUNTIME=${VC_RUNTIME:-native}
mkdir -p ~/bin ~/.local ~/logs
log(){ echo "[setup] $*"; }
export PATH=$HOME/bin:$HOME/.local/go/bin:$HOME/.local/node/bin:$PATH
case $(uname -m) in x86_64) GOARCH=amd64; NARCH=x64;; aarch64) GOARCH=arm64; NARCH=arm64;; esac
ORG=https://github.com/TheAtlantaDream

# 1. tools
if ! command -v cmake >/dev/null; then sudo -n apt-get update -qq && sudo -n apt-get install -y -qq cmake build-essential; fi
if [ ! -x ~/.local/go/bin/go ]; then log "installing go"; V=$(curl -s "https://go.dev/VERSION?m=text" | head -1); curl -sL https://go.dev/dl/$V.linux-$GOARCH.tar.gz | tar -C ~/.local -xz; fi
if [ ! -x ~/.local/node/bin/node ]; then log "installing node"; F=$(curl -s https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | grep "linux-$NARCH.tar.xz" | awk '{print $2}'); mkdir -p ~/.local/node; curl -sL https://nodejs.org/dist/latest-v22.x/$F | tar -xJ -C ~/.local/node --strip-components=1; fi
grep -q voicecoder-path ~/.bashrc 2>/dev/null || echo 'export PATH=$HOME/bin:$HOME/.local/go/bin:$HOME/.local/node/bin:$PATH # voicecoder-path' >> ~/.bashrc
if [ ! -x ~/bin/agentapi ]; then log "installing agentapi"; curl -sL -o ~/bin/agentapi https://github.com/coder/agentapi/releases/latest/download/agentapi-linux-$GOARCH; chmod +x ~/bin/agentapi; fi
command -v claude >/dev/null || { log "installing claude code"; npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; }

# 2. repos
sync_repo(){ if [ -d ~/$1/.git ]; then git -C ~/$1 pull --ff-only -q || log "pull skipped for $1"; else git clone -q $ORG/$2 ~/$1 || log "clone skipped for $2 (not pushed yet?)"; fi; }
sync_repo voicecoder VoiceCoder
sync_repo voicecoder-bridge voicecoder-bridge
mkdir -p ~/project
[ -d ~/project/.git ] || git -C ~/project init -q
git config --global user.email >/dev/null || { git config --global user.name "VoiceCoder User"; git config --global user.email "voicecoder@localhost"; }

# agent rules for the whole workspace: create, or append if our section is missing. Never overwrite.
mkdir -p ~/.claude
if ! grep -q "# VoiceCoder rules" ~/.claude/CLAUDE.md 2>/dev/null; then
  [ -s ~/.claude/CLAUDE.md ] && echo >> ~/.claude/CLAUDE.md
  cat >> ~/.claude/CLAUDE.md <<'RULES'
# VoiceCoder rules
<!-- PLACEHOLDER until Carter sends the final rules. Replace everything below this line. -->
- Work only inside ~/project.
- Never run git commit, git push, or any command that changes git history. The user approves changes by voice.
- Keep changes small and focused on the request.
RULES
  log "wrote VoiceCoder rules to ~/.claude/CLAUDE.md"
fi

# 3. whisper (native mode only)
if [ "$RUNTIME" = native ]; then
if [ ! -x ~/whisper.cpp/build/bin/whisper-server ]; then log "building whisper (a few minutes the first time)"; [ -d ~/whisper.cpp ] || git clone -q --depth 1 https://github.com/ggml-org/whisper.cpp ~/whisper.cpp; (cd ~/whisper.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release > ~/logs/cmake.log 2>&1 && cmake --build build -j$(nproc) --target whisper-server >> ~/logs/cmake.log 2>&1); fi
[ -f ~/whisper.cpp/models/ggml-small.en.bin ] || { log "downloading whisper model"; (cd ~/whisper.cpp && bash models/download-ggml-model.sh small.en >/dev/null 2>&1); }
fi

# 4. services
up(){ (echo > /dev/tcp/${2:-127.0.0.1}/$1) >/dev/null 2>&1; }
start(){ n=$1; p=$2; shift 2; if up $p; then log "$n already on $p"; else log "starting $n on $p"; nohup "$@" > ~/logs/$n.log 2>&1 & disown; fi; }
SVC=127.0.0.1

if [ "$RUNTIME" = compose ]; then
  SVC=host.docker.internal
  log "runtime: docker compose on host Docker"
  # docker CLI and compose plugin into the home folder
  if [ ! -x ~/bin/docker ]; then log "installing docker cli"; curl -sL https://download.docker.com/linux/static/stable/$(uname -m)/docker-28.5.1.tgz | tar -xz -C /tmp && mv /tmp/docker/docker ~/bin/; fi
  if [ ! -x ~/.docker/cli-plugins/docker-compose ]; then log "installing compose plugin"; mkdir -p ~/.docker/cli-plugins; curl -sL -o ~/.docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m); chmod +x ~/.docker/cli-plugins/docker-compose; fi
  [ -w /var/run/docker.sock ] || sudo -n chmod 666 /var/run/docker.sock
  # submodules: the repo's .gitmodules URLs are missing https://, so override them locally
  if [ -d ~/voicecoder/.git ]; then
    cd ~/voicecoder
    git submodule init -q
    git config submodule.bridge.url https://github.com/TheAtlantaDream/voicecoder-bridge
    git config submodule.frontend.url https://github.com/TheAtlantaDream/VoiceCoder-frontend
    git submodule update -q --remote || log "submodule update failed"
    # same project name for both steps, so the model lands in the volume whisper reads
    export COMPOSE_PROJECT_NAME=voicecoder
    log "downloading whisper model (model-download.sh, skips if present)"
    docker compose --profile setup run --rm model-download > ~/logs/model-download.log 2>&1 || log "model download failed, see ~/logs/model-download.log"
    log "docker compose up (first build takes several minutes)"
    docker compose up -d --build > ~/logs/compose.log 2>&1 || log "compose up failed, see ~/logs/compose.log"
    cd ~
  else
    log "skip compose: ~/voicecoder missing"
  fi
else
  log "runtime: native"
  T=$(nproc); [ $T -le 8 ] || T=8
  start whisper 8080 ~/whisper.cpp/build/bin/whisper-server -m ~/whisper.cpp/models/ggml-small.en.bin --host 127.0.0.1 --port 8080 -t $T
  if [ -d ~/voicecoder-bridge/cmd/bridge ]; then (cd ~/voicecoder-bridge && go build -o ~/bin/voicecoder-bridge ./cmd/bridge) && start bridge 8000 ~/bin/voicecoder-bridge -addr :8000 -whisper-url http://localhost:8080; fi
fi

# these always run inside the workspace
if [ -d ~/project/.git ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then start agentapi 3284 bash -c 'cd ~/project && exec agentapi server --type=claude -- claude'; else log "skip agentapi: needs ~/project and API key"; fi

sleep 3
for pr in 8080:whisper 8000:bridge; do up ${pr%%:*} $SVC && log "OK   ${pr#*:} (${pr%%:*})" || log "DOWN ${pr#*:} (${pr%%:*})"; done
[ "$RUNTIME" = compose ] && { up 80 $SVC && log "OK   frontend (80)" || log "DOWN frontend (80)"; }
for pr in 3284:agentapi; do up ${pr%%:*} && log "OK   ${pr#*:} (${pr%%:*})" || log "DOWN ${pr#*:} (${pr%%:*})"; done
exit 0

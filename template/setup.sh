#!/usr/bin/env bash
# VoiceCoder workspace setup. Safe to run twice.
set -uo pipefail
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
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
sync_repo beta-test-demo beta-test-demo
mkdir -p ~/beta-test-demo

# 3. whisper
if [ ! -x ~/whisper.cpp/build/bin/whisper-server ]; then log "building whisper (a few minutes the first time)"; [ -d ~/whisper.cpp ] || git clone -q --depth 1 https://github.com/ggml-org/whisper.cpp ~/whisper.cpp; (cd ~/whisper.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release > ~/logs/cmake.log 2>&1 && cmake --build build -j$(nproc) --target whisper-server >> ~/logs/cmake.log 2>&1); fi
[ -f ~/whisper.cpp/models/ggml-small.en.bin ] || { log "downloading whisper model"; (cd ~/whisper.cpp && bash models/download-ggml-model.sh small.en >/dev/null 2>&1); }

# 4. services
up(){ (echo > /dev/tcp/127.0.0.1/$1) >/dev/null 2>&1; }
start(){ n=$1; p=$2; shift 2; if up $p; then log "$n already on $p"; else log "starting $n on $p"; nohup "$@" > ~/logs/$n.log 2>&1 & disown; fi; }
T=$(nproc); [ $T -le 8 ] || T=8
start whisper 8080 ~/whisper.cpp/build/bin/whisper-server -m ~/whisper.cpp/models/ggml-small.en.bin --host 127.0.0.1 --port 8080 -t $T
if [ -d ~/voicecoder-bridge/cmd/bridge ]; then (cd ~/voicecoder-bridge && go build -o ~/bin/voicecoder-bridge ./cmd/bridge) && start bridge 8000 ~/bin/voicecoder-bridge -addr :8000 -whisper-url http://localhost:8080; fi
if [ -d ~/beta-test-demo/.git ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then start agentapi 3284 bash -c 'cd ~/beta-test-demo && exec agentapi server -- claude'; else log "skip agentapi: needs beta-test-demo repo and API key"; fi
if [ -f ~/voicecoder/server/go.mod ]; then (cd ~/voicecoder/server && go build -o ~/bin/voicecoder-server .) && start server 8090 ~/bin/voicecoder-server; else log "skip server 8090: voicecoder/server not pushed yet"; fi

sleep 3
for pr in 8080:whisper 8000:bridge 3284:agentapi 8090:server; do up ${pr%%:*} && log "OK   ${pr#*:} (${pr%%:*})" || log "DOWN ${pr#*:} (${pr%%:*})"; done
exit 0

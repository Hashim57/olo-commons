#!/bin/bash
# Serves the promoted Zeus version from this Mac to the cloud, as one supervised process:
#   mlx_lm.server (127.0.0.1:8008)  <-  zeus_gate.py (127.0.0.1:8009, bearer token)  <-  cloudflared tunnel (public https)
# Run by launchd (KeepAlive) after `bash zeus/mac/install-serve.sh`; can also be run by hand:
#   bash zeus/mac/zeus-serve.sh
# When the tunnel is up, the public URL is written to ~/zeus-serve.url and, if the Supabase CLI
# is logged in on this Mac, the project secrets OLO_ZEUS_URL and OLO_ZEUS_API_KEY are set so
# olo-answer starts verifying with Zeus (responses then say verifier: "zeus:default_model").
# Nothing here is committed; the token lives in ~/.zeus-gate-token and the URL in ~/zeus-serve.url.
set -uo pipefail
REPO="${ZEUS_REPO:-$HOME/olo-commons}"
LOG="$HOME/zeus-serve.log"
TOKEN_FILE="$HOME/.zeus-gate-token"
URL_FILE="$HOME/zeus-serve.url"
PROJECT_REF="${SUPABASE_PROJECT_REF:-bfldflbkebyapfagsxnr}"
MODEL_PORT=8008; GATE_PORT=8009
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
cd "$REPO" || { echo "repo not found at $REPO"; exit 1; }

[ -f "$TOKEN_FILE" ] || { echo "no token at $TOKEN_FILE; run bash zeus/mac/install-serve.sh"; exit 1; }
command -v cloudflared >/dev/null || { log "cloudflared missing (brew install cloudflared)"; exit 1; }

V="$(python3 -c 'import json; print(json.load(open("zeus/BEST.json"))["version"])' 2>/dev/null || true)"
[ -n "$V" ] || { log "no zeus/BEST.json; run python3 zeus/promote.py"; exit 1; }
[ -f "zeus/out/zeus-$V/adapters.safetensors" ] || { log "no adapter weights for $V on this Mac"; exit 1; }

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -f "$URL_FILE" "$HOME/zeus-serving.version"; }
trap cleanup EXIT INT TERM

log "serving Zeus $V"
echo "$V" > "$HOME/zeus-serving.version"
bash zeus/serve_mac.sh "$V" "$MODEL_PORT" >> "$HOME/zeus-model.log" 2>&1 &
PIDS+=($!)
python3 zeus/mac/zeus_gate.py --token-file "$TOKEN_FILE" --listen "$GATE_PORT" --upstream "$MODEL_PORT" >> "$HOME/zeus-gate.log" 2>&1 &
PIDS+=($!)

# Wait for the model to answer before opening the tunnel.
for _ in $(seq 1 120); do
  curl -sf -m 2 "http://127.0.0.1:$MODEL_PORT/v1/models" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf -m 2 "http://127.0.0.1:$MODEL_PORT/v1/models" >/dev/null 2>&1 || { log "model server did not come up; see ~/zeus-model.log"; exit 1; }

TLOG="$HOME/zeus-tunnel.log"; : > "$TLOG"
cloudflared tunnel --url "http://127.0.0.1:$GATE_PORT" --no-autoupdate >> "$TLOG" 2>&1 &
PIDS+=($!)
URL=""
for _ in $(seq 1 60); do
  URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TLOG" | head -n1 || true)"
  [ -n "$URL" ] && break
  sleep 1
done
[ -n "$URL" ] || { log "tunnel gave no URL; see $TLOG"; exit 1; }
echo "$URL/v1" > "$URL_FILE"
log "Zeus $V reachable at $URL/v1 (through the gate)"

# Tell the cloud function where Zeus is, when the Supabase CLI is logged in here.
if command -v supabase >/dev/null && supabase projects list >/dev/null 2>&1; then
  if supabase secrets set "OLO_ZEUS_URL=$URL/v1" "OLO_ZEUS_API_KEY=$(cat "$TOKEN_FILE")" --project-ref "$PROJECT_REF" >> "$LOG" 2>&1; then
    log "Supabase secrets OLO_ZEUS_URL and OLO_ZEUS_API_KEY updated"
  else
    log "could not set Supabase secrets; set OLO_ZEUS_URL=$URL/v1 and OLO_ZEUS_API_KEY (contents of $TOKEN_FILE) by hand"
  fi
else
  log "Supabase CLI not logged in; set OLO_ZEUS_URL=$URL/v1 and OLO_ZEUS_API_KEY (contents of $TOKEN_FILE) in the project secrets"
fi

# Stay up while every part is up; launchd restarts the whole thing if any part dies.
while :; do
  for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null || { log "a component exited; restarting"; exit 1; }; done
  sleep 15
done

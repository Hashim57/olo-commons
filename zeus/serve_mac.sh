#!/bin/bash
# Serve a trained Zeus adapter from an Apple Silicon Mac as an OpenAI-compatible API.
#   bash zeus/serve_mac.sh            serves the version in zeus/BEST.json on port 8008
#   bash zeus/serve_mac.sh v5 8010    serves v5 on port 8010
# The adapter must exist under zeus/out/zeus-<version>/ (the Mac keeps the weights; they are not in git).
# Endpoint: http://localhost:<port>/v1/chat/completions (what olo-answer expects as OLO_ZEUS_URL with /v1).
# To reach it from Supabase, put it behind a tunnel you control, for example:
#   cloudflared tunnel --url http://localhost:8008
# then set the Supabase secret OLO_ZEUS_URL=https://<tunnel-host>/v1 (leave OLO_ZEUS_MODEL unset: olo-answer
# sends "default_model", which mlx_lm.server maps to the adapter loaded here; any other name makes it load that model).
# Keep the tunnel private to the Edge Function (an access token on the tunnel, or OLO_ZEUS_API_KEY
# matched by a proxy in front); mlx_lm.server itself has no authentication.
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:-}"
PORT="${2:-8008}"
if [ -z "$V" ]; then
  V="$(python3 -c 'import json; print(json.load(open("zeus/BEST.json"))["version"])' 2>/dev/null || true)"
  [ -n "$V" ] || { echo "no version given and no zeus/BEST.json; run python3 zeus/promote.py first"; exit 1; }
fi
OUT="zeus/out/zeus-$V"
[ -f "$OUT/adapters.safetensors" ] || { echo "no adapter weights at $OUT (train it on this Mac first)"; exit 1; }
BASE="$(python3 -c "import json; print(json.load(open('$OUT/eval.json'))['base'])" 2>/dev/null || echo mlx-community/Qwen2.5-1.5B-Instruct-4bit)"
[ -d .zeus-venv ] || python3 -m venv .zeus-venv
. .zeus-venv/bin/activate
pip -q install mlx-lm
echo "serving Zeus $V ($BASE + $OUT) on http://localhost:$PORT/v1"
exec python3 -m mlx_lm.server --model "$BASE" --adapter-path "$OUT" --port "$PORT" --host 127.0.0.1 --temp 0.0 --max-tokens 200 --chat-template-args '{"enable_thinking":false}'

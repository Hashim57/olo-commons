#!/bin/bash
# Uploads one Zeus version to Cloudflare Workers AI and makes the Worker serve it.
#   bash zeus/cloudflare/publish.sh v6
# Run by setup.sh, and by the Mac training agent when zeus/BEST.json promotes a new version.
# Steps: export the PEFT copy if missing; upload it as the fine-tune "zeus-<v>" (uploads are
# immutable, so each version gets its own name); redeploy the Worker pointing at it with the
# version's measured scores; score the served model on the frozen eval split and record it in
# zeus/out/zeus-<v>/eval-cloudflare.json (the local and served numbers can differ).
set -euo pipefail
V="${1:?version, e.g. v6}"
cd "$(dirname "$0")"
HERE="$(pwd)"; REPO="$(cd ../.. && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
BASE_CF="@cf/mistral/mistral-7b-instruct-v0.2-lora"
OUT="$REPO/zeus/out/zeus-$V"; PEFT="$OUT-peft"; NAME="zeus-$V"
PY="$REPO/.zeus-venv/bin/python3"; [ -x "$PY" ] || PY=python3

BASE_USED="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("base",""))' "$OUT/train_summary.json" 2>/dev/null || true)"
case "$BASE_USED" in *istral-7B-Instruct-v0.2*) ;; *) echo "$V was trained on '$BASE_USED', not Mistral 7B Instruct v0.2; Cloudflare cannot serve it."; exit 1 ;; esac

if [ ! -f "$PEFT/adapter_model.safetensors" ]; then
  "$PY" "$REPO/zeus/export_peft.py" --adapter "$OUT" --out "$PEFT" --base-hf mistralai/Mistral-7B-Instruct-v0.2 --model-type mistral
fi

if npx --yes wrangler@4 ai finetune list 2>/dev/null | grep -qw "$NAME"; then
  echo "$NAME is already uploaded."
else
  echo "Uploading $NAME..."
  npx --yes wrangler@4 ai finetune create "$BASE_CF" "$NAME" "$PEFT"
fi

SCORES="$("$PY" - "$REPO" "$V" <<'PYEOF'
import json, os, sys
repo, v = sys.argv[1], sys.argv[2]
best = os.path.join(repo, "zeus", "BEST.json")
b = json.load(open(best)) if os.path.exists(best) else {}
b = b.get("cloudflare") or {}
if b.get("version") != v:
    ev = json.load(open(os.path.join(repo, "zeus", "out", f"zeus-{v}", "eval.json")))
    b = {"version": v, "label_accuracy": ev.get("label_accuracy"), "evidence_hit": ev.get("evidence_hit"), "json_valid": ev.get("json_valid"), "eval_n": ev.get("n"), "f1": ev.get("f1")}
keep = ("version", "date", "base", "label_accuracy", "evidence_hit", "json_valid", "eval_n", "f1", "promoted_at")
print(json.dumps({k: b[k] for k in keep if k in b}, separators=(",", ":")))
PYEOF
)"
# A deploy config with the values filled in (gitignored); JSON goes in a TOML literal string.
sed -e "s|^ZEUS_LORA = .*|ZEUS_LORA = \"$NAME\"|" -e "s|^ZEUS_VERSION = .*|ZEUS_VERSION = \"$V\"|" \
    -e "s|^ZEUS_SCORES = .*|ZEUS_SCORES = '$SCORES'|" wrangler.toml > wrangler.deploy.toml
npx --yes wrangler@4 deploy --config wrangler.deploy.toml
echo "The zeus Worker now serves $NAME."

URL="$(cat "$HOME/zeus-cf.url" 2>/dev/null || true)"
if [ -n "$URL" ] && [ -f "$REPO/zeus/data/eval.jsonl" ]; then
  echo "Scoring the served model on the frozen eval split..."
  "$PY" "$REPO/zeus/eval_endpoint.py" --url "$URL" --out "$OUT/eval-cloudflare.json" || echo "Served-model scoring failed; run it again later: python3 zeus/eval_endpoint.py --url $URL --out $OUT/eval-cloudflare.json"
fi

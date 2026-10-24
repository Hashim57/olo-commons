#!/bin/bash
# Publish a cloud-trained Zeus version to Cloudflare from CI (no Mac involved).
#   bash zeus/cloud/publish_ci.sh v6
# Needs CLOUDFLARE_API_TOKEN (Workers AI and Workers Scripts edit) and CLOUDFLARE_ACCOUNT_ID in the
# environment; optional ZEUS_URL (https://zeus.<you>.workers.dev/v1) and ZEUS_KEY to score the
# served model. Uploads the adapter as the fine-tune zeus-<v>, points the Worker at it with the
# version's measured scores, and writes zeus/out/zeus-<v>/eval-cloudflare.json.
set -euo pipefail
V="${1:?version}"
cd "$(dirname "$0")/../.."
PEFT="zeus/out/zeus-$V-peft"; NAME="zeus-$V"
[ -f "$PEFT/adapter_model.safetensors" ] && [ -f "$PEFT/adapter_config.json" ] || { echo "no PEFT adapter in $PEFT"; exit 1; }
W="npx --yes wrangler@4"
cd zeus/cloudflare
if $W ai finetune list 2>/dev/null | grep -qw "$NAME"; then echo "$NAME already uploaded"; else $W ai finetune create "@cf/mistral/mistral-7b-instruct-v0.2-lora" "$NAME" "../../$PEFT"; fi
SCORES="$(python3 -c 'import json; b=json.load(open("../BEST.json")).get("cloudflare") or {}; k=("version","date","base","label_accuracy","evidence_hit","json_valid","eval_n","f1"); print(json.dumps({x:b[x] for x in k if x in b}, separators=(",",":")))')"
sed -e "s|^ZEUS_LORA = .*|ZEUS_LORA = \"$NAME\"|" -e "s|^ZEUS_VERSION = .*|ZEUS_VERSION = \"$V\"|" -e "s|^ZEUS_SCORES = .*|ZEUS_SCORES = '$SCORES'|" wrangler.toml > wrangler.deploy.toml
$W deploy --config wrangler.deploy.toml
cd ../..
if [ -n "${ZEUS_URL:-}" ] && [ -n "${ZEUS_KEY:-}" ]; then
  python3 zeus/eval_endpoint.py --url "$ZEUS_URL" --out "zeus/out/zeus-$V/eval-cloudflare.json" || echo "served-model scoring failed; the Worker still serves $NAME"
fi

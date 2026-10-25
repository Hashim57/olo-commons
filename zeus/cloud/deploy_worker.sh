#!/bin/bash
# Deploy the zeus Worker code as it is in the repo, keeping the adapter and scores of the version
# in zeus/BEST.json (cloudflare). For code changes to worker.js that do not need a new adapter.
#   bash zeus/cloud/deploy_worker.sh
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in the environment. Nothing is uploaded or trained.
set -euo pipefail
cd "$(dirname "$0")/../.."
V="$(python3 -c 'import json; print((json.load(open("zeus/BEST.json")).get("cloudflare") or {}).get("version",""))')"
[ -n "$V" ] || { echo "no Cloudflare version in zeus/BEST.json"; exit 1; }
NAME="zeus-$V"
SCORES="$(python3 -c 'import json; b=json.load(open("zeus/BEST.json")).get("cloudflare") or {}; k=("version","date","base","label_accuracy","evidence_hit","json_valid","eval_n","f1"); print(json.dumps({x:b[x] for x in k if x in b}, separators=(",",":")))')"
cd zeus/cloudflare
sed -e "s|^ZEUS_LORA = .*|ZEUS_LORA = \"$NAME\"|" -e "s|^ZEUS_VERSION = .*|ZEUS_VERSION = \"$V\"|" -e "s|^ZEUS_SCORES = .*|ZEUS_SCORES = '$SCORES'|" wrangler.toml > wrangler.deploy.toml
npx --yes wrangler@4 deploy --config wrangler.deploy.toml
echo "deployed worker.js serving $NAME"

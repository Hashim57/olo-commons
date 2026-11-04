#!/bin/bash
# Deploys the zeus Worker's code without changing which Zeus version it serves.
#   DRAFT_MODEL=@google/gemini-4-argon bash zeus/cloudflare/deploy_worker.sh
# Run on the Mac, from the repo clone, after a change to worker.js. The daily cloud training only
# redeploys the Worker when a new Zeus version wins, so a code change waits for this. It writes the
# serving version from zeus/BEST.json ("cloudflare") into a copy of wrangler.toml, as publish_ci.sh does,
# so ZEUS_LORA never goes blank; keep_vars keeps DRAFT_MODEL and anything else set in the dashboard.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
W="npx --yes wrangler@4"
V="$(python3 -c 'import json; print((json.load(open("../BEST.json")).get("cloudflare") or {}).get("version",""))')"
[ -n "$V" ] || { echo "zeus/BEST.json names no Cloudflare version; nothing to deploy against."; exit 1; }
SCORES="$(python3 -c 'import json; b=json.load(open("../BEST.json")).get("cloudflare") or {}; k=("version","date","base","label_accuracy","evidence_hit","json_valid","eval_n","f1"); print(json.dumps({x:b[x] for x in k if x in b}, separators=(",",":")))')"
sed -e "s|^ZEUS_LORA = .*|ZEUS_LORA = \"zeus-$V\"|" -e "s|^ZEUS_VERSION = .*|ZEUS_VERSION = \"$V\"|" -e "s|^ZEUS_SCORES = .*|ZEUS_SCORES = '$SCORES'|" wrangler.toml > wrangler.deploy.toml
# Wrangler asks before dropping a dashboard variable it does not see here, so the writer model is
# written in too: DRAFT_MODEL=<id> bash deploy_worker.sh (left out, the Worker's default Llama is used).
if [ -n "${DRAFT_MODEL:-}" ]; then
  python3 -c 'import sys; p="wrangler.deploy.toml"; t=open(p).read(); open(p,"w").write(t.replace("[vars]\n", "[vars]\nDRAFT_MODEL = \"%s\"\n" % sys.argv[1], 1))' "$DRAFT_MODEL"
fi
if ! $W whoami 2>/dev/null | grep -qi "associated with the email\|account id"; then $W login; fi
$W deploy --config wrangler.deploy.toml
rm -f wrangler.deploy.toml
URL="$(cat "$HOME/zeus-cf.url" 2>/dev/null | sed 's|/v1$||' || true)"
[ -n "$URL" ] || URL="https://zeus.6hnz57bf82.workers.dev"
echo "Deployed. Serving: $(curl -s "$URL/health")"

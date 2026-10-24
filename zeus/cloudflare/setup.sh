#!/bin/bash
# One-time setup of Zeus on Cloudflare Workers AI. Run on the Mac, from the repo clone:
#   bash zeus/cloudflare/setup.sh
# What it does:
#   1. signs you in to Cloudflare with wrangler (a browser window opens once; free account is enough)
#   2. makes the caller key (~/.zeus-cf-token, never committed) and deploys the "zeus" Worker
#   3. stores the key as the Worker secret ZEUS_TOKEN and the Worker address in ~/zeus-cf.url
#   4. uploads the promoted Zeus adapter if one is ready (publish.sh)
#   5. points the Commons at it (Supabase secrets) if the Supabase CLI is logged in
#   6. prints the exact values for helius-olo.io's Netlify settings
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"; REPO="$(cd ../.. && pwd)"
TOKEN_FILE="$HOME/.zeus-cf-token"; URL_FILE="$HOME/zeus-cf.url"
PROJECT_REF="${SUPABASE_PROJECT_REF:-bfldflbkebyapfagsxnr}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v npx >/dev/null || { echo "Node.js is needed (brew install node)"; exit 1; }

if ! npx --yes wrangler@4 whoami 2>/dev/null | grep -qi "associated with the email\|account id"; then
  echo "Signing in to Cloudflare (a browser window opens)..."
  npx --yes wrangler@4 login
fi
ACCOUNT_ID="$(npx --yes wrangler@4 whoami 2>/dev/null | grep -Eo '[0-9a-f]{32}' | head -n1 || true)"

if [ ! -s "$TOKEN_FILE" ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(36))' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "Made the Zeus caller key at $TOKEN_FILE (never commit it)."
fi

echo "Deploying the zeus Worker..."
OUT="$(npx --yes wrangler@4 deploy 2>&1 | tee /dev/stderr)"
URL="$(printf '%s' "$OUT" | grep -Eo 'https://zeus\.[a-z0-9-]+\.workers\.dev' | head -n1 || true)"
[ -n "$URL" ] || { echo "Could not read the Worker address from wrangler's output above."; exit 1; }
echo "$URL/v1" > "$URL_FILE"
tr -d '\n' < "$TOKEN_FILE" | npx --yes wrangler@4 secret put ZEUS_TOKEN >/dev/null
echo "Worker live at $URL (key stored as the Worker secret ZEUS_TOKEN)."

# Upload the promoted version if its adapter is on this Mac.
V="$(python3 -c 'import json; print((json.load(open("'"$REPO"'/zeus/BEST.json")).get("cloudflare") or {}).get("version",""))' 2>/dev/null || true)"
if [ -n "$V" ] && { [ -f "$REPO/zeus/out/zeus-$V-peft/adapter_model.safetensors" ] || [ -f "$REPO/zeus/out/zeus-$V/adapters.safetensors" ]; }; then
  bash "$HERE/publish.sh" "$V" && echo "$V" > "$HOME/zeus-cf.version" || echo "Upload of $V did not complete; the Worker still serves the fallback writer and answers 503 for Zeus until a version is published."
else
  echo "No Cloudflare-ready Zeus adapter yet (the next training run makes one: Mistral 7B profile). Zeus answers 503 until then; callers fall back."
fi

if command -v supabase >/dev/null && supabase projects list >/dev/null 2>&1; then
  supabase secrets set --project-ref "$PROJECT_REF" \
    "OLO_ZEUS_URL=$URL/v1" "OLO_ZEUS_API_KEY=$(cat "$TOKEN_FILE")" \
    "OLO_LLM_FALLBACK_BASE_URL=$URL/v1" "OLO_LLM_FALLBACK_API_KEY=$(cat "$TOKEN_FILE")" "OLO_LLM_FALLBACK_MODEL=olo-draft" >/dev/null \
    && echo "Commons (Supabase) now verifies with Zeus on Cloudflare and falls back to the Cloudflare writer." \
    || echo "Could not set the Supabase secrets; set them by hand (values below)."
fi

cat <<VALUES

==== Paste these into Netlify for helius-olo.io (Site configuration > Environment variables) ====
ZEUS_VERIFIER_URL=$URL/v1
ZEUS_VERIFIER_KEY=$(cat "$TOKEN_FILE")
ZEUS_VERIFIER_MODEL=default_model
ZEUS_VERIFIER_FORMAT=commons
OLO_FALLBACK_BASE_URL=$URL/v1
OLO_FALLBACK_KEY=$(cat "$TOKEN_FILE")
OLO_FALLBACK_MODEL=olo-draft
==== and these into Supabase (Edge Functions > Secrets) if they were not set above ====
OLO_ZEUS_URL=$URL/v1
OLO_ZEUS_API_KEY=$(cat "$TOKEN_FILE")
OLO_LLM_FALLBACK_BASE_URL=$URL/v1
OLO_LLM_FALLBACK_API_KEY=$(cat "$TOKEN_FILE")
OLO_LLM_FALLBACK_MODEL=olo-draft
(Cloudflare account id, for reference: ${ACCOUNT_ID:-shown by: npx wrangler whoami})
VALUES

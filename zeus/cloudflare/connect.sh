#!/bin/bash
# Connects helius-olo.io (Netlify) and Olo Commons (Supabase) to the Zeus Worker with one shared key.
#   bash zeus/cloudflare/connect.sh
# Run on the Mac. Use it when answers say "checked by Zeus (backup verifier)" or the health check
# (https://helius-olo.io/api/trpc/system.health) says "zeus":"unauthorized": that is always the
# key Netlify sends not matching the Worker's ZEUS_TOKEN secret.
#
# What it does, and never prints the key:
#   1. uses the caller key in ~/.zeus-cf-token, or makes one
#   2. stores it as the Worker secret ZEUS_TOKEN (wrangler; a browser sign-in opens once)
#   3. checks the Worker accepts it (GET /v1/models, then one real Zeus verification)
#   4. sets ZEUS_VERIFIER_* and OLO_FALLBACK_* on the helius-olo.io Netlify site (netlify CLI;
#      a browser sign-in opens once). Netlify applies them on the next deploy.
#   5. sets the matching Supabase secrets for Olo Commons if the Supabase CLI is signed in
# If a step cannot run, it says so and copies the key to the clipboard for pasting by hand.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v npx >/dev/null || { echo "Node.js is needed (brew install node)"; exit 1; }

TOKEN_FILE="$HOME/.zeus-cf-token"
URL="${ZEUS_URL:-https://zeus.6hnz57bf82.workers.dev}"
NETLIFY_SITE="${NETLIFY_SITE_ID:-02527d1d-1eca-4fb5-ba35-cac8537b4b63}"   # helius-olo.io
PROJECT_REF="${SUPABASE_PROJECT_REF:-bfldflbkebyapfagsxnr}"

echo "1/5 Caller key"
if [ ! -s "$TOKEN_FILE" ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(36))' > "$TOKEN_FILE"
  echo "    made a new key at $TOKEN_FILE"
else
  echo "    using the key at $TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE"
KEY="$(tr -d '\n' < "$TOKEN_FILE")"

echo "2/5 Worker secret ZEUS_TOKEN"
if ! npx --yes wrangler@4 whoami 2>/dev/null | grep -qi "associated with the email\|account id"; then
  npx --yes wrangler@4 login
fi
printf '%s' "$KEY" | npx --yes wrangler@4 secret put ZEUS_TOKEN >/dev/null
echo "    stored"

echo "3/5 Checking the Worker accepts the key"
ok=""
for i in 1 2 3 4 5 6; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $KEY" -H 'user-agent: Olo/1.0 (+https://helius-olo.io)' "$URL/v1/models" || true)"
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 5   # a new secret can take a few seconds to reach every edge
done
[ -n "$ok" ] || { echo "    the Worker still answers $code; run this again in a minute"; exit 1; }
verdict="$(curl -s -H "authorization: Bearer $KEY" -H 'content-type: application/json' -H 'user-agent: Olo/1.0 (+https://helius-olo.io)' \
  "$URL/v1/chat/completions" \
  -d '{"model":"default_model","max_tokens":200,"temperature":0,"messages":[{"role":"user","content":"Claim: Water boils at 100 C at sea level.\nSources:\n[1] At standard atmospheric pressure (sea level), pure water boils at 100 degrees Celsius.\nAnswer as JSON with label (supported, contradicted or not_covered) and evidence."}]}' || true)"
case "$verdict" in
  *supported*|*contradicted*|*not_covered*) echo "    Zeus answered a test claim: $(printf '%s' "$verdict" | grep -Eo '"label[^,}]*' | head -n1)";;
  *) echo "    the key works; the test verification returned: $(printf '%s' "$verdict" | head -c 200)";;
esac

echo "4/5 Netlify (helius-olo.io)"
netlify_ok=""
if npx --yes netlify-cli@17 status >/dev/null 2>&1 || npx --yes netlify-cli@17 login; then
  set_env() { NETLIFY_SITE_ID="$NETLIFY_SITE" npx --yes netlify-cli@17 env:set "$1" "$2" --context production >/dev/null; }
  if set_env ZEUS_VERIFIER_URL "$URL/v1" && set_env ZEUS_VERIFIER_KEY "$KEY" && set_env ZEUS_VERIFIER_MODEL default_model \
     && set_env ZEUS_VERIFIER_FORMAT commons && set_env OLO_FALLBACK_BASE_URL "$URL/v1" && set_env OLO_FALLBACK_KEY "$KEY" \
     && set_env OLO_FALLBACK_MODEL olo-draft; then
    netlify_ok=1
    echo "    set ZEUS_VERIFIER_URL, _KEY, _MODEL, _FORMAT and OLO_FALLBACK_BASE_URL, _KEY, _MODEL"
    echo "    they take effect on the next deploy of helius-olo.io"
  fi
fi
if [ -z "$netlify_ok" ]; then
  printf '%s' "$KEY" | pbcopy 2>/dev/null || true
  cat <<HAND
    Could not set them with the Netlify CLI. The key is on the clipboard. In Netlify, helius-oloo >
    Site configuration > Environment variables, set:
      ZEUS_VERIFIER_URL=$URL/v1
      ZEUS_VERIFIER_KEY=<paste>
      ZEUS_VERIFIER_MODEL=default_model
      ZEUS_VERIFIER_FORMAT=commons
      OLO_FALLBACK_BASE_URL=$URL/v1
      OLO_FALLBACK_KEY=<paste>
      OLO_FALLBACK_MODEL=olo-draft
    then deploy.
HAND
fi

echo "5/5 Supabase (Olo Commons)"
if command -v supabase >/dev/null && supabase projects list >/dev/null 2>&1; then
  supabase secrets set --project-ref "$PROJECT_REF" \
    "OLO_ZEUS_URL=$URL/v1" "OLO_ZEUS_API_KEY=$KEY" \
    "OLO_LLM_FALLBACK_BASE_URL=$URL/v1" "OLO_LLM_FALLBACK_API_KEY=$KEY" "OLO_LLM_FALLBACK_MODEL=olo-draft" >/dev/null \
    && echo "    set OLO_ZEUS_URL, OLO_ZEUS_API_KEY and the fallback writer" \
    || echo "    could not set them; set the same five values in Supabase > Edge Functions > Secrets"
else
  echo "    Supabase CLI not signed in; skipped (Commons keeps its current settings)"
fi
echo "Done. After the next deploy, https://helius-olo.io/api/trpc/system.health should read \"zeus\":\"ok\" once an answer has been checked."

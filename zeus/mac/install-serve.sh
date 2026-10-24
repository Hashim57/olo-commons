#!/bin/bash
# Installs the Zeus serving agent (model server + authenticated gate + tunnel) as a launchd
# user agent that stays up while you are logged in. Run once from the repo clone:
#   bash zeus/mac/install-serve.sh
# Uninstall:  launchctl bootout gui/$(id -u)/com.helius.zeus-serve && rm ~/Library/LaunchAgents/com.helius.zeus-serve.plist
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
LABEL=com.helius.zeus-serve
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
TOKEN_FILE="$HOME/.zeus-gate-token"
[ "$(uname -m)" = "arm64" ] || { echo "Apple Silicon only"; exit 1; }
command -v cloudflared >/dev/null || { echo "installing cloudflared"; brew install cloudflared; }
[ -f zeus/BEST.json ] || python3 zeus/promote.py
if [ ! -f "$TOKEN_FILE" ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(36))' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "made a new gate token at $TOKEN_FILE (never commit it)"
fi
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s#__REPO__#$REPO#g" -e "s#__HOME__#$HOME#g" "zeus/mac/$LABEL.plist" > "$DEST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "Installed $LABEL. First start downloads nothing new (the base model is cached from training) and takes about a minute."
echo "Public URL: cat ~/zeus-serve.url      Logs: ~/zeus-serve.log ~/zeus-model.log ~/zeus-gate.log ~/zeus-tunnel.log"
echo "If the Supabase CLI is logged in here, OLO_ZEUS_URL and OLO_ZEUS_API_KEY are set for you on every start;"
echo "otherwise set them in the project secrets from ~/zeus-serve.url and $TOKEN_FILE."
echo "Check: curl -s -H \"Authorization: Bearer \$(cat $TOKEN_FILE)\" \$(cat ~/zeus-serve.url)/models"

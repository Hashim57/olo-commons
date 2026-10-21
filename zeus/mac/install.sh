#!/bin/bash
# Installs the Zeus training agent as a launchd user agent (runs every 30 minutes
# while you are logged in). Run once from the repo clone:  bash zeus/mac/install.sh
# Uninstall:  launchctl bootout gui/$(id -u)/com.helius.zeus-train && rm ~/Library/LaunchAgents/com.helius.zeus-train.plist
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
LABEL=com.helius.zeus-train
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
[ "$(uname -m)" = "arm64" ] || { echo "Apple Silicon only"; exit 1; }
git push --dry-run origin main >/dev/null 2>&1 || { echo "git push is not set up for this clone (run one git push from Terminal first so the keychain stores the credential)"; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s#__REPO__#$REPO#g" -e "s#__HOME__#$HOME#g" "zeus/mac/$LABEL.plist" > "$DEST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "Installed $LABEL. It checks for zeus/TRAIN_REQUEST.json every 30 minutes."
echo "Log: ~/zeus-agent.log   Training logs: ~/zeus-train-<version>.log"
echo "Status: launchctl print gui/$(id -u)/$LABEL | head -20"

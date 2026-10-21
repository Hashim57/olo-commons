#!/bin/bash
# Zeus training agent for an Apple Silicon Mac. Run by launchd every 30 minutes
# (see install.sh). Looks for a training request committed by the daily cloud
# run, trains that version on the Mac GPU, commits the results and pushes.
#
# Request format (zeus/TRAIN_REQUEST.json, written by the cloud run):
#   {"version": "v3", "requested_at": "2026-10-28T10:05:00Z", "reason": "412 train examples, no measured row near that size"}
#
# Behaviour:
#   - fetches origin/main; does nothing unless the request file exists there
#   - skips a version that already has zeus/out/zeus-<v>/eval.json or FAILED.txt
#   - runs zeus/train_mac.sh <v>, keeping the Mac awake (caffeinate) but letting the display sleep
#   - on success commits eval.json + train_summary.json; on failure commits FAILED.txt with the log tail
#   - removes the request file in the same commit and pushes (rebase and retry once if main moved)
#   - one run at a time (lock file); everything logged to ~/zeus-agent.log and ~/zeus-train-<v>.log
#
# Needs: the repo cloned at ~/olo-commons with push access stored in the macOS
# keychain (any earlier `git push` from Terminal did that). No secrets here.
set -uo pipefail

REPO="${ZEUS_REPO:-$HOME/olo-commons}"
LOG="$HOME/zeus-agent.log"
LOCK="$HOME/.zeus-agent.lock"
REQ="zeus/TRAIN_REQUEST.json"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# One instance at a time; a stale lock older than 6 hours is ignored.
if [ -e "$LOCK" ] && [ -n "$(find "$LOCK" -mmin -360 2>/dev/null)" ]; then exit 0; fi
echo $$ > "$LOCK"; trap 'rm -f "$LOCK"' EXIT

if [ ! -d "$REPO/.git" ]; then
  git clone -q https://github.com/Hashim57/olo-commons "$REPO" >> "$LOG" 2>&1 || { log "clone failed"; exit 1; }
fi
cd "$REPO" || exit 1
git fetch -q origin main >> "$LOG" 2>&1 || { log "fetch failed (offline?)"; exit 0; }

# Nothing requested: stay quiet.
git cat-file -e "origin/main:$REQ" 2>/dev/null || exit 0

# Bring the working tree to origin/main. Results from an earlier run that
# failed to push are kept (they are already committed locally).
git checkout -q main >> "$LOG" 2>&1
git pull -q --ff-only origin main >> "$LOG" 2>&1 || git merge -q --no-edit origin/main >> "$LOG" 2>&1

V=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$REQ" 2>/dev/null || true)
case "$V" in v[0-9]|v[0-9][0-9]|v[0-9][0-9][0-9]) ;; *) log "bad request version '$V'; ignoring"; exit 0 ;; esac
OUT="zeus/out/zeus-$V"
if [ -f "$OUT/eval.json" ] || [ -f "$OUT/FAILED.txt" ]; then
  log "$V already has results; removing the request"
  git rm -q "$REQ" && git commit -q -m "zeus: clear stale training request for $V" && git push -q origin main >> "$LOG" 2>&1
  exit 0
fi

log "training $V"
TLOG="$HOME/zeus-train-$V.log"
# caffeinate -i: no idle sleep while training; the display may still sleep.
if caffeinate -i bash zeus/train_mac.sh "$V" > "$TLOG" 2>&1 && [ -f "$OUT/eval.json" ]; then
  log "$V done: $(tail -n 20 "$TLOG" | grep -m1 '"label_accuracy"' || echo 'no report line')"
  git add -f "$OUT/eval.json" "$OUT/train_summary.json"
  MSG="zeus: $V results (trained on the Mac by zeus-agent)"
else
  mkdir -p "$OUT"
  { echo "train_mac.sh $V failed at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Last 40 lines of the log:"; tail -n 40 "$TLOG"; } > "$OUT/FAILED.txt"
  log "$V FAILED; see $TLOG"
  git add -f "$OUT/FAILED.txt"
  MSG="zeus: $V training failed on the Mac (see FAILED.txt)"
fi
git rm -q --cached "$REQ" 2>/dev/null; rm -f "$REQ"
git -c user.name="zeus-agent" -c user.email="zeus-agent@heliusnetwork.app" commit -q -m "$MSG" >> "$LOG" 2>&1
if ! git push -q origin main >> "$LOG" 2>&1; then
  git pull -q --rebase origin main >> "$LOG" 2>&1 && git push -q origin main >> "$LOG" 2>&1 || log "push failed; results stay local until the next run"
fi

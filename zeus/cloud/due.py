#!/usr/bin/env python3
"""Decide whether the daily run should train a new Zeus, and which version.

  python3 zeus/cloud/due.py --meta zeus/data/meta.json [--new-feedback N] [--force]

Prints one JSON line {due, version, reason} and, inside GitHub Actions, writes the
same to $GITHUB_OUTPUT. Training costs about $1.50 of GPU time, so it runs only
when there is something new to learn from:
  * accepted feedback flags became gold lines today, or
  * the training set grew by a tenth or more since the serving version, or
  * a week has passed since the last measured version (the Commons re-checks and
    grows every day, and a weekly retrain keeps Zeus on its current text).
The version is the next vN after the highest with results.
"""
import argparse
import json
import os
import sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
ZEUS = os.path.dirname(HERE)
sys.path.insert(0, ZEUS)
from request_training import highest_version  # noqa: E402


def decide(best, meta, new_feedback, today, force=False):
    """(due, reason) from the serving version, the fresh dataset meta and today's feedback count."""
    if force:
        return True, "requested by hand"
    if new_feedback > 0:
        return True, f"{new_feedback} accepted feedback flags became gold lines"
    try:
        had = int(str(best.get("train_examples", "0")).replace(",", ""))
    except ValueError:
        had = 0
    now = int(meta.get("train_total") or meta.get("train") or 0)
    if had and now >= 1.10 * had:
        return True, f"training set grew from {had:,} to {now:,}"
    try:
        last = date.fromisoformat(str(best.get("date", ""))[:10])
        if (today - last).days >= 7:
            return True, f"{(today - last).days} days since {best.get('version')}"
    except ValueError:
        return True, "no measured version yet"
    return False, f"nothing new: {now:,} examples against {had:,}, {best.get('version')} measured {best.get('date')}, no new feedback"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--meta", default=os.path.join(ZEUS, "data", "meta.json"))
    ap.add_argument("--new-feedback", type=int, default=0)
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    best = json.load(open(os.path.join(ZEUS, "BEST.json"))) if os.path.exists(os.path.join(ZEUS, "BEST.json")) else {}
    meta = json.load(open(a.meta)) if os.path.exists(a.meta) else {}
    due, reason = decide(best, meta, a.new_feedback, date.today(), a.force)
    version = f"v{highest_version() + 1}"
    out = {"due": due, "version": version, "reason": reason}
    print(json.dumps(out))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"due={'1' if due else '0'}\nversion={version}\nreason={reason}\n")


if __name__ == "__main__":
    main()

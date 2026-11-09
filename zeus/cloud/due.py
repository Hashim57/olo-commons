#!/usr/bin/env python3
"""Decide whether the daily run should train a new Zeus, and which version.

  python3 zeus/cloud/due.py --meta zeus/data/meta.json [--new-feedback N] [--force]

Prints one JSON line {due, version, reason, against} and, inside GitHub Actions, writes
due, version and reason to $GITHUB_OUTPUT. A run costs GPU time (about two hours on an
A100 at 32,000 examples), so it runs only when there is something new to learn from:
  * accepted feedback flags became gold lines today, or
  * the training set grew by a tenth or more since the last trained version, or
  * the training recipe changed: meta.json lists a train generator (rules-v1,
    hard-v1, compose-v1, ...) the last trained version was not trained with, or lacks
    one it was (the set is capped at 7,000 atoms, so a new generator that adds
    2,000 examples can fall short of the tenth and still be the whole point), or
  * a week has passed since the last trained version (the Commons re-checks and
    grows every day, and a weekly retrain keeps Zeus on its current text).
The version is the next vN after the highest with results.

"The last trained version" is the newest one with measured results (last_measured), not
the best one in BEST.json. The two were the same until v16; then v17 and v18 were trained
and measured but not promoted, BEST.json stayed at v16 (22,497 examples, no compose-v1),
and against it the growth rule and the recipe rule both answered "due" every day whatever
the data did: run 23 on 2026-11-09 trained v19 on the capped set v18 had been trained on
the day before (v18: 6,202 atoms and 154 gold lines; the 9 November build: the same rows
less 79 stubs a newer gate rule drops, and 164 gold lines). Training again on what the
last run already saw teaches nothing, so the comparison is with what was last trained.
"""
import argparse
import json
import os
import re
import sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
ZEUS = os.path.dirname(HERE)
sys.path.insert(0, ZEUS)
from request_training import highest_version  # noqa: E402


def recipe_change(had, now):
    """What differs between the generators the serving version was trained with and the fresh build's, as
    "compose-v1 added" / "hard-v1 removed", or "" when nothing differs or either side is unknown (an older
    BEST.json without the key never triggers a run by itself)."""
    if not had or not now:
        return ""
    added = sorted(set(now) - set(had))
    removed = sorted(set(had) - set(now))
    parts = ([", ".join(added) + " added"] if added else []) + ([", ".join(removed) + " removed"] if removed else [])
    return "; ".join(parts)


def decide(best, meta, new_feedback, today, force=False):
    """(due, reason) from the version a fresh build is compared with (reference(): the last trained one), the fresh
    dataset meta and today's feedback count. train_examples in a train_summary.json counts the imported corpus
    (about 1,500 VitaminC lines) and meta.json at decision time does not yet, so the growth rule asks for slightly
    more than a tenth; that errs on the side of not paying for a run."""
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
    changed = recipe_change(best.get("train_generators"), meta.get("train_generators"))
    if changed:
        return True, f"training recipe changed: {changed} (since {best.get('version')})"
    try:
        last = date.fromisoformat(str(best.get("date", ""))[:10])
        if (today - last).days >= 7:
            return True, f"{(today - last).days} days since {best.get('version')}"
    except ValueError:
        if not best.get("version"):
            return True, "no measured version yet"
        # a measured version whose date is not on record: the weekly rule cannot fire, the others have been tried
    return False, f"nothing new: {now:,} examples against {had:,}, {best.get('version')} measured {best.get('date')}, no new feedback"


def version_number(v):
    """18 from "v18"; -1 when there is none."""
    m = re.fullmatch(r"v(\d+)", str(v or "").strip())
    return int(m.group(1)) if m else -1


def last_measured(zeus_dir=ZEUS):
    """The newest version that was trained and measured, as {version, date, train_examples, train_generators},
    or {} when there is none. Measured means zeus/out/zeus-vN/eval.json exists (a failed run leaves FAILED.txt
    and no eval.json, so it is tried again). train_examples and train_generators come from its train_summary.json,
    the date from its row in STATUS.md; a key is left out when its source is missing."""
    out = os.path.join(zeus_dir, "out")
    n = -1
    if os.path.isdir(out):
        for d in os.listdir(out):
            m = re.fullmatch(r"zeus-v(\d+)", d)
            if m and os.path.exists(os.path.join(out, d, "eval.json")):
                n = max(n, int(m.group(1)))
    if n < 0:
        return {}
    last = {"version": f"v{n}"}
    try:
        with open(os.path.join(out, f"zeus-v{n}", "train_summary.json"), encoding="utf-8") as f:
            summary = json.load(f)
        if summary.get("train_examples"):
            last["train_examples"] = summary["train_examples"]
        if summary.get("train_generators"):
            last["train_generators"] = summary["train_generators"]
    except (OSError, ValueError):
        pass
    status = os.path.join(zeus_dir, "STATUS.md")
    if os.path.exists(status):
        for line in open(status, encoding="utf-8"):
            m = re.match(rf"\|\s*(\d{{4}}-\d{{2}}-\d{{2}})\s*\|\s*v{n}\s*\|", line)
            if m:
                last["date"] = m.group(1)
    return last


def reference(best, last):
    """What a fresh build is compared with: the last trained version when it is newer than the best one, with
    anything it does not record (an older train_summary.json without generators, a missing STATUS row) left
    unknown and not borrowed from the best version, whose values describe a different training set. With no
    newer measured version the best one stands, as before."""
    if not last or version_number(last.get("version")) <= version_number(best.get("version")):
        return best
    return last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--meta", default=os.path.join(ZEUS, "data", "meta.json"))
    ap.add_argument("--new-feedback", type=int, default=0)
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    best = json.load(open(os.path.join(ZEUS, "BEST.json"))) if os.path.exists(os.path.join(ZEUS, "BEST.json")) else {}
    meta = json.load(open(a.meta)) if os.path.exists(a.meta) else {}
    ref = reference(best, last_measured())
    due, reason = decide(ref, meta, a.new_feedback, date.today(), a.force)
    version = f"v{highest_version() + 1}"
    out = {"due": due, "version": version, "reason": reason, "against": ref.get("version")}
    print(json.dumps(out))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"due={'1' if due else '0'}\nversion={version}\nreason={reason}\n")


if __name__ == "__main__":
    main()

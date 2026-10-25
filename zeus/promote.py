#!/usr/bin/env python3
"""Pick the Zeus version that serves, by measured score only.

  python3 zeus/promote.py            # writes zeus/BEST.json and prints it
  python3 zeus/promote.py --dry-run  # prints what would be written

Reads every zeus/out/zeus-vN/eval.json that has a measured row in STATUS.md
and chooses the best by label accuracy, then evidence hit, then the newer
version. A version is only promoted when it is at least as good as the one
in BEST.json already (so a worse training run never replaces a better one),
unless --force is given. The page and the serving scripts read BEST.json;
nothing here trains, serves or uploads.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROW = re.compile(r"^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(v\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|")


def measured_rows(status_path):
    """{version: {date, base, train_examples, label_accuracy, evidence_hit}} from the STATUS table."""
    rows = {}
    if not os.path.exists(status_path):
        return rows
    for line in open(status_path, encoding="utf-8"):
        m = ROW.match(line)
        if m:
            rows[m.group(2)] = {"date": m.group(1), "base": m.group(3), "train_examples": m.group(4), "label_accuracy": float(m.group(5)), "evidence_hit": float(m.group(6))}
    return rows


def candidates(out_dir, rows):
    """Versions with both a STATUS row and an eval.json on disk."""
    out = []
    for v, row in rows.items():
        p = os.path.join(out_dir, f"zeus-{v}", "eval.json")
        if not os.path.exists(p):
            continue
        try:
            ev = json.load(open(p, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        ext_path = os.path.join(out_dir, f"zeus-{v}", "eval-external.json")
        held_out = None
        if os.path.exists(ext_path):
            try:
                vit = (json.load(open(ext_path, encoding="utf-8")).get("vitaminc_dev") or {})
                held_out = float(vit["label_accuracy"]) if "label_accuracy" in vit else None
            except (OSError, ValueError, TypeError):
                held_out = None
        out.append({"version": v, "date": row["date"], "base": ev.get("base") or row["base"], "train_examples": row["train_examples"],
                    "label_accuracy": float(ev.get("label_accuracy", row["label_accuracy"])), "evidence_hit": float(ev.get("evidence_hit", row["evidence_hit"])),
                    "json_valid": ev.get("json_valid"), "eval_n": ev.get("n"), "f1": ev.get("f1"), "held_out_accuracy": held_out})
    return out


def cloudflare_servable(c):
    return "mistral-7b-instruct-v0.2" in str(c.get("base", "")).lower()


def rank_key(c):
    """The frozen split first, rounded to two places because a 7B model saturates it (0.99 and 0.995 tie);
    then the held-out VitaminC accuracy, which a saturated split cannot give; then evidence hit; then the newer version."""
    return (round(c["label_accuracy"], 2), c.get("held_out_accuracy") if c.get("held_out_accuracy") is not None else -1.0, c["evidence_hit"], int(c["version"][1:]))


def choose(cands, current=None, force=False):
    """The best candidate, or the current one when nothing beats it (unless force)."""
    if not cands:
        return None
    best = max(cands, key=rank_key)
    if current and not force:
        cur = next((c for c in cands if c["version"] == current.get("version")), None)
        if cur and rank_key(best) < rank_key(cur):
            return cur
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", default=os.path.join(HERE, "STATUS.md"))
    ap.add_argument("--out-dir", default=os.path.join(HERE, "out"))
    ap.add_argument("--best", default=os.path.join(HERE, "BEST.json"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    current = None
    if os.path.exists(args.best):
        try:
            current = json.load(open(args.best, encoding="utf-8"))
        except (OSError, ValueError):
            current = None
    cands = candidates(args.out_dir, measured_rows(args.status))
    best = choose(cands, current, args.force)
    if not best:
        sys.exit("no measured version with an eval.json under zeus/out")
    record = {**best, "promoted_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "measured_versions": sorted(c["version"] for c in cands)}
    if current and current.get("version") == best["version"] and not args.force:
        record["promoted_at"] = current.get("promoted_at", record["promoted_at"])
    # The best version Cloudflare can serve (Mistral 7B Instruct v0.2 base), chosen by the same rule and
    # never demoted. This is what zeus/cloudflare/publish.sh uploads; it can differ from the overall best.
    cf_cur = (current or {}).get("cloudflare")
    cf = choose([c for c in cands if cloudflare_servable(c)], cf_cur, args.force)
    record["cloudflare"] = {k: cf[k] for k in ("version", "date", "base", "label_accuracy", "evidence_hit", "json_valid", "eval_n", "f1") if k in cf} if cf else None
    print(json.dumps(record, indent=2))
    if not args.dry_run:
        with open(args.best, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()

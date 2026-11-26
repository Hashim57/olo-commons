#!/usr/bin/env python3
"""Pick the Zeus version that serves, by measured score only.

  python3 zeus/promote.py            # writes zeus/BEST.json and prints it
  python3 zeus/promote.py --dry-run  # prints what would be written

Reads every zeus/out/zeus-vN/eval.json that has a measured row in STATUS.md
and chooses the best: a version must score at least FROZEN_FLOOR on the frozen
split, and above it the held-out VitaminC accuracy decides, then Commons eval
v3, then evidence hit, then the newer version (rank_key). A version is only promoted when it is at least as good as the one
in BEST.json already (so a worse training run never replaces a better one),
unless --force is given. The page and the serving scripts read BEST.json;
nothing here trains, serves or uploads.

  python3 zeus/promote.py --version v31 --reason "..."   # promote a measured version by hand

Since 2026-11-26 the floor reads the honest score (well_formed_accuracy): the first split without
the 17 malformed rule-made name edits it still holds, which a model trained since the name filter
rightly calls not covered. A version promoted by hand is pinned: automatic promotion keeps it until
a version trained after it outranks it, so the next scheduled run does not undo a person's choice.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROW = re.compile(r"^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(v\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|")


def well_formed_accuracy(ev, fallback=None):
    """Label accuracy on the first split without its malformed rule-made name edits. eval.json's own
    well_formed when it has one (eval.score_well_formed, since 2026-11-25); otherwise worked out exactly from
    the measured headline and by_edit's name_malformed row (correct = accuracy x n, less the malformed lines
    answered right, over the lines left); otherwise the headline, for versions measured before by_edit
    existed, whose frozen split was scored whole."""
    wf = ev.get("well_formed") or {}
    if "label_accuracy" in wf:
        return float(wf["label_accuracy"])
    acc = ev.get("label_accuracy", fallback)
    n = ev.get("n")
    bad = (ev.get("by_edit") or {}).get("name_malformed") or {}
    if acc is not None and n and bad.get("n"):
        right = round(float(acc) * n) - round(float(bad.get("accuracy", 0)) * bad["n"])
        return round(right / (n - bad["n"]), 3)
    return float(acc) if acc is not None else None


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
        held_out = eval3 = None
        if os.path.exists(ext_path):
            try:
                ext = json.load(open(ext_path, encoding="utf-8"))
                vit, e3 = ext.get("vitaminc_dev") or {}, ext.get("eval_v3") or {}
                held_out = float(vit["label_accuracy"]) if "label_accuracy" in vit else None
                eval3 = float(e3["label_accuracy"]) if "label_accuracy" in e3 else None
            except (OSError, ValueError, TypeError, AttributeError):
                held_out = eval3 = None
        # The train generators (rules-v1, hard-v1, compose-v1, ...) the version was built with, as record.py
        # copied them from meta.json into train_summary.json; due.py retrains when the recipe changes.
        gens = None
        sum_path = os.path.join(out_dir, f"zeus-{v}", "train_summary.json")
        if os.path.exists(sum_path):
            try:
                gens = json.load(open(sum_path, encoding="utf-8")).get("train_generators")
            except (OSError, ValueError, AttributeError):
                gens = None
        out.append({"version": v, "date": row["date"], "base": ev.get("base") or row["base"], "train_examples": row["train_examples"],
                    "label_accuracy": float(ev.get("label_accuracy", row["label_accuracy"])), "evidence_hit": float(ev.get("evidence_hit", row["evidence_hit"])),
                    "well_formed_accuracy": well_formed_accuracy(ev, row["label_accuracy"]),
                    "json_valid": ev.get("json_valid"), "eval_n": ev.get("n"), "f1": ev.get("f1"), "held_out_accuracy": held_out, "eval3_accuracy": eval3,
                    **({"train_generators": gens} if gens else {})})
    return out


def cloudflare_servable(c):
    return "mistral-7b-instruct-v0.2" in str(c.get("base", "")).lower()


# Since 2026-11-17 the frozen split is a floor, not the first key. Every cloud version scores 0.99 to 1.0 on it,
# so ranking by it first let one answer in 200 decide: v22 (0.995, rounded by float to 0.99) lost to v16 (1.0)
# although v22 was better on everything that still measures something (VitaminC dev 0.733 against 0.717,
# Commons eval v3 0.92 against 0.66), and Olo kept serving v16. Above the floor, versions are ranked by the
# held-out human-written claims (VitaminC dev), then the hard patterns (eval v3), then evidence hit, then age.
FROZEN_FLOOR = 0.98


def rank_key(c):
    """Whether the version clears FROZEN_FLOOR on the frozen split's honest score (well_formed_accuracy); then the held-out VitaminC accuracy; then
    Commons eval v3; then, for versions below the floor or without held-out numbers, the frozen split itself;
    then evidence hit; then the newer version."""
    ho = c.get("held_out_accuracy")
    e3 = c.get("eval3_accuracy")
    honest = c.get("well_formed_accuracy")
    honest = c["label_accuracy"] if honest is None else honest
    return (honest >= FROZEN_FLOOR - 1e-9, ho if ho is not None else -1.0, e3 if e3 is not None else -1.0,
            round(c["label_accuracy"], 3), c["evidence_hit"], int(c["version"][1:]))


def choose(cands, current=None, force=False):
    """The best candidate, or the current one when nothing beats it (unless force). When the current one
    was promoted by hand (pinned), only versions trained after it may replace it."""
    if not cands:
        return None
    pin = (current or {}).get("pinned")
    if pin and not force:
        floor_n = int(str(pin.get("version", "v0"))[1:] or 0)
        cands = [c for c in cands if int(c["version"][1:]) >= floor_n] or cands
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
    ap.add_argument("--version", help="promote this measured version by hand (pins it; see the module docstring)")
    ap.add_argument("--reason", default="", help="why, recorded in BEST.json with a hand promotion")
    args = ap.parse_args()
    current = None
    if os.path.exists(args.best):
        try:
            current = json.load(open(args.best, encoding="utf-8"))
        except (OSError, ValueError):
            current = None
    cands = candidates(args.out_dir, measured_rows(args.status))
    hand = None
    if args.version:
        hand = next((c for c in cands if c["version"] == args.version), None)
        if not hand:
            sys.exit(f"{args.version} has no measured row in STATUS.md with an eval.json; only measured versions can be promoted")
        if not args.reason.strip():
            sys.exit("a hand promotion needs --reason")
    best = hand or choose(cands, current, args.force)
    if not best:
        sys.exit("no measured version with an eval.json under zeus/out")
    record = {**best, "promoted_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "measured_versions": sorted(c["version"] for c in cands)}
    if hand:
        record["pinned"] = {"version": hand["version"], "by": "hand", "reason": args.reason.strip(), "at": record["promoted_at"]}
    elif current and current.get("pinned") and int(best["version"][1:]) >= int(str(current["pinned"].get("version", "v0"))[1:] or 0) and best["version"] == current.get("version"):
        record["pinned"] = current["pinned"]
    if current and current.get("version") == best["version"] and not args.force and not hand:
        record["promoted_at"] = current.get("promoted_at", record["promoted_at"])
    # The best version Cloudflare can serve (Mistral 7B Instruct v0.2 base), chosen by the same rule and
    # never demoted. This is what zeus/cloudflare/publish.sh uploads; it can differ from the overall best.
    cf_cur = (current or {}).get("cloudflare")
    if hand and cloudflare_servable(hand):
        cf = hand
    else:
        # a pinned overall choice pins the Cloudflare choice too, when it is servable there
        cf_pin = {**(cf_cur or {}), "pinned": current.get("pinned")} if current and current.get("pinned") and cf_cur and cf_cur.get("version") == current["pinned"].get("version") else cf_cur
        cf = choose([c for c in cands if cloudflare_servable(c)], cf_pin, args.force)
    record["cloudflare"] = {k: cf[k] for k in ("version", "date", "base", "label_accuracy", "evidence_hit", "json_valid", "eval_n", "f1") if k in cf} if cf else None
    print(json.dumps(record, indent=2))
    if not args.dry_run:
        with open(args.best, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()

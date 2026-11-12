#!/usr/bin/env python3
"""Teach Zeus: claims go out to POL Net members to be checked, and what they agree on comes back as gold.

  python3 zeus/member_checks_to_gold.py items --out items.json [--n 200] [--controls 20]
  python3 zeus/member_checks_to_gold.py gold export.json [--out zeus/data/gold/checks-<date>.jsonl]

`items` picks rule-made examples from zeus/data/train.jsonl (train side of the eval hash by
construction), removes the label, evidence and rationale, and writes the body for
POST /v1/admin/checks on the POL Net API. It adds a few hand-written gold examples as controls
(`known` carries their label): members are never told which items are controls, controls are never
exported, and the share of control answers that match is the public measure of how careful the
labelling is (GET /v1/checks/stats).

`gold` reads the answer of GET /v1/admin/checks/export (items where three verified members gave the
same label) and writes the ones that pass zeus/validate_gold.py as gold lines with kind
"member_check". Nothing here uploads, downloads or commits: a person runs the two API calls with the
admin secret (apps/polnet/DEPLOY.md), reads the output file, and commits it. Agreement between
members is evidence, not the last word; Zeus still never trains on its own labels.
"""
import argparse
import json
import os
import random
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build_dataset import stable_split  # noqa: E402
from validate_gold import check_example  # noqa: E402

DASHES = ("\u2013", "\u2014")


def read_jsonl(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def as_item(ex, known=None):
    """One example as an upload item, or None when the API would refuse it (apps/polnet api.ts, checkItemFrom)."""
    claim = " ".join(str(ex.get("claim") or "").split())
    ps = ex.get("passages") or []
    if not 10 <= len(claim) <= 600 or not 2 <= len(ps) <= 4:
        return None
    passages, seen = [], set()
    for p in ps:
        pid, source, url, text = (str(p.get(k) or "") for k in ("id", "source", "url", "text"))
        if not pid or pid in seen or not source or not url.startswith("https://") or not 40 <= len(text) <= 4000:
            return None
        seen.add(pid)
        q = {"id": pid[:64], "source": source[:60], "url": url, "text": text}
        atom = p.get("atom_id") or (ex.get("atom_id") if str(ex.get("atom_id") or "")[:8] == pid else None)
        if atom:
            q["atom_id"] = atom
        passages.append(q)
    item = {"claim": claim, "passages": passages}
    # Nothing with an em or en dash can be committed here, so do not spend people's care on it.
    if any(d in json.dumps(item, ensure_ascii=False) for d in DASHES):
        return None
    if known:
        item["known"] = known
    return item


def pick_items(train, gold, n, controls, seed):
    """n items to be checked, spread evenly over the three rule labels, plus control items from gold."""
    rng = random.Random(seed)
    by = {"supported": [], "contradicted": [], "not_covered": []}
    for ex in train:
        if ex.get("label") in by and (it := as_item(ex)):
            by[ex["label"]].append(it)
    out, claims = [], set()
    for label, rows in by.items():
        rng.shuffle(rows)
        for it in rows:
            if len([1 for x in out if x["_l"] == label]) >= (n + 2) // 3:
                break
            if it["claim"] not in claims:
                claims.add(it["claim"])
                out.append({**it, "_l": label})
    out = [{k: v for k, v in x.items() if k != "_l"} for x in out][:n]
    pool = [it for ex in gold if (it := as_item(ex, known=ex.get("label"))) and it["claim"] not in claims]
    rng.shuffle(pool)
    out += pool[:controls]
    rng.shuffle(out)
    return out


def to_gold(example, eval_share=0.1):
    """(gold line, None) for one exported example, or (None, why it is left out)."""
    ex = {k: example.get(k) for k in ("claim", "passages", "label", "evidence", "rationale")}
    ex["kind"] = "member_check"
    for k in ("check_id", "votes", "agree"):
        if k in example:
            ex[k] = example[k]
    if not isinstance(ex.get("agree"), int) or ex["agree"] < 3:
        return None, "fewer than three members agreed"
    bad = check_example(ex)
    if bad:
        return None, "; ".join(bad)
    for p in ex["passages"]:
        if p.get("atom_id") and stable_split(p["atom_id"], eval_share) == "eval":
            return None, f"passage {p['id']} is an eval atom, so it never trains"
    if any(d in json.dumps(ex, ensure_ascii=False) for d in DASHES):
        return None, "contains an em or en dash"
    return ex, None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("items")
    a.add_argument("--train", default=os.path.join(HERE, "data", "train.jsonl"))
    a.add_argument("--gold-dir", default=os.path.join(HERE, "data", "gold"))
    a.add_argument("--n", type=int, default=200)
    a.add_argument("--controls", type=int, default=20)
    a.add_argument("--seed", type=int, default=1)
    a.add_argument("--out", required=True)
    g = sub.add_parser("gold")
    g.add_argument("export")
    g.add_argument("--out")
    args = ap.parse_args(argv)

    if args.cmd == "items":
        gold = []
        for name in sorted(os.listdir(args.gold_dir)) if os.path.isdir(args.gold_dir) else []:
            # Hand-written files only: member checks are not controls for member checks.
            if name.startswith("gold-") and name.endswith(".jsonl"):
                gold += read_jsonl(os.path.join(args.gold_dir, name))
        items = pick_items(read_jsonl(args.train), gold, max(0, args.n), max(0, min(args.controls, 500 - min(args.n, 500))), args.seed)[:500]
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"items": items}, f, ensure_ascii=False)
        print(json.dumps({"items": len(items), "controls": sum(1 for x in items if "known" in x), "out": args.out}))
        return 0

    with open(args.export, encoding="utf-8") as f:
        examples = json.load(f).get("examples") or []
    kept, left = [], []
    for e in examples:
        ex, why = to_gold(e)
        if ex:
            kept.append(ex)
        else:
            left.append({"check_id": e.get("check_id"), "why": why})
    out = args.out or os.path.join(HERE, "data", "gold", f"checks-{datetime.now(timezone.utc).date().isoformat()}.jsonl")
    if kept:
        with open(out, "w", encoding="utf-8") as f:
            for ex in kept:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    print(json.dumps({"exported": len(examples), "kept": len(kept), "left_out": left, "out": out if kept else None}))
    return 0


if __name__ == "__main__":
    sys.exit(main())

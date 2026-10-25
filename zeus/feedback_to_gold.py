#!/usr/bin/env python3
"""Turn reviewed feedback flags into Zeus gold examples.

  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... python3 zeus/feedback_to_gold.py --version v7

People flag sentences in Olo's apps (functions/olo-feedback). A person reviews each
flag in the olo_feedback table and sets status = accepted (with a reviewer_note when
the note needs sharpening, and the exact evidence words in evidence_quote when the
flag did not carry them). This script reads the accepted flags that no version has
trained on yet, rebuilds each one as a gold example with the passages' real text
from the Commons, validates it exactly like hand-written gold (zeus/validate_gold.py),
writes zeus/data/gold/feedback-<date>.jsonl, and marks the rows used_in = <version>.

Why this way round: Zeus never trains on its own labels. A flag is a person's
judgement; a reviewer confirms it; only then does it become a label. Flags with
verdict_user wrong_source or unclear are kept for analysis but make no example.
Without the service key (local runs, forks) the script does nothing and exits 0.
"""
import argparse
import json
import os
import random
import sys
from datetime import datetime, timezone

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from validate_gold import check_example  # noqa: E402

LABELS = ("supported", "contradicted", "not_covered")


def rest(url, key, path, params=None, method="GET", body=None):
    h = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json", "Prefer": "return=representation"}
    r = requests.request(method, f"{url.rstrip('/')}/rest/v1/{path}", headers=h, params=params, json=body, timeout=60)
    r.raise_for_status()
    return r.json() if r.text else []


def passage_text(atom):
    """The snapshot convention: the summary, or the start of the content, at most 600 characters."""
    summary = (atom.get("summary") or "").strip()
    content = (atom.get("content") or "").strip()
    text = summary if len(summary) >= 200 or not content else (summary + " " + content).strip()
    return " ".join(text.split())[:600]


def build(flag, atoms_by_id, distractors):
    """One gold example from one accepted flag, or (None, reason)."""
    label = flag["verdict_user"]
    if label not in LABELS:
        return None, f"verdict_user {label} makes no example"
    passages = []
    for p in flag.get("passages") or []:
        a = atoms_by_id.get(p.get("atom"))
        if not a:
            continue
        passages.append({"id": a["id"][:8], "source": a.get("source_slug") or "commons", "url": a.get("url") or "", "atom_id": a["id"], "text": passage_text(a), "quote_hint": p.get("quote")})
    if not passages:
        return None, "no passage could be resolved to a Commons atom"
    # Gold needs at least two passages: add an unrelated one as a distractor, as the rule-made data does.
    while len(passages) < 2 and distractors:
        d = distractors.pop()
        if d["id"] not in {p["atom_id"] for p in passages}:
            passages.append({"id": d["id"][:8], "source": d.get("source_slug") or "commons", "url": d.get("url") or "", "atom_id": d["id"], "text": passage_text(d)})
    evidence = []
    if label in ("supported", "contradicted"):
        candidates = [flag.get("evidence_quote")] + [p.get("quote_hint") for p in passages]
        for q in [c for c in candidates if c]:
            q = " ".join(str(q).split())
            for p in passages:
                if q and q in p["text"]:
                    evidence.append({"passage": p["id"], "quote": q})
                    break
            if evidence:
                break
        if not evidence:
            return None, "no evidence quote is an exact substring of a passage (set evidence_quote on the row)"
    for p in passages:
        p.pop("quote_hint", None)
    rationale = (flag.get("reviewer_note") or flag.get("note") or {"supported": "The passage states the claim.", "contradicted": "The passage gives a different value.", "not_covered": "No passage states this claim."}[label]).strip()
    ex = {"claim": flag["claim"], "passages": passages, "label": label, "evidence": evidence, "rationale": rationale, "kind": "feedback", "feedback_id": flag["id"], "client": flag.get("client")}
    problems = check_example(ex)
    if problems:
        return None, "; ".join(problems)
    return ex, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "data", "gold"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    url, key = os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        print("feedback_to_gold: no service key in the environment; skipping (nothing changed)")
        return
    flags = rest(url, key, "olo_feedback", {"status": "eq.accepted", "used_in": "is.null", "select": "*", "order": "at.asc", "limit": "500"})
    if not flags:
        print("feedback_to_gold: no accepted flags waiting")
        return
    ids = sorted({p.get("atom") for f in flags for p in (f.get("passages") or []) if p.get("atom")})
    atoms = []
    for i in range(0, len(ids), 100):
        atoms += rest(url, key, "olo_atoms", {"id": "in.(" + ",".join(ids[i:i + 100]) + ")", "select": "id,title,summary,content,url,source_id,olo_sources(slug)"})
    for a in atoms:
        a["source_slug"] = (a.get("olo_sources") or {}).get("slug")
    atoms_by_id = {a["id"]: a for a in atoms}
    distractors = rest(url, key, "olo_atoms", {"select": "id,title,summary,content,url,olo_sources(slug)", "status": "in.(verified,candidate)", "order": "created_at.desc", "limit": "60"})
    for d in distractors:
        d["source_slug"] = (d.get("olo_sources") or {}).get("slug")
    random.Random(len(flags)).shuffle(distractors)

    built, skipped, used = [], [], []
    seen_claims = set()
    for f in flags:
        if f["claim"] in seen_claims:
            skipped.append((f["id"], "claim repeated"))
            continue
        ex, why = build(f, atoms_by_id, distractors)
        if ex:
            built.append(ex)
            used.append(f["id"])
            seen_claims.add(f["claim"])
        else:
            skipped.append((f["id"], why))
    for fid, why in skipped:
        print(f"skipped {fid}: {why}")
    if not built:
        print("feedback_to_gold: nothing could be built")
        return
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    path = os.path.join(args.out, f"feedback-{day}.jsonl")
    if args.dry_run:
        print(f"would write {len(built)} examples to {path}")
        return
    os.makedirs(args.out, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        for ex in built:
            fh.write(json.dumps(ex, ensure_ascii=False) + "\n")
    for i in range(0, len(used), 100):
        rest(url, key, "olo_feedback", {"id": "in.(" + ",".join(used[i:i + 100]) + ")"}, method="PATCH", body={"used_in": args.version})
    print(f"feedback_to_gold: {len(built)} examples -> {path}; {len(skipped)} skipped; rows marked used_in={args.version}")


if __name__ == "__main__":
    main()

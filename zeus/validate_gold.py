#!/usr/bin/env python3
"""Validate the hand-written gold examples in zeus/data/gold/*.jsonl.

Gold lines are the highest-value training data Zeus has, and they are also the
easiest to get subtly wrong: an evidence quote that is not in its passage, a
passage id that no passage carries, a not_covered example with evidence. Those
mistakes do not crash training; they quietly teach the model the wrong thing
and corrupt the evidence-hit metric. This script refuses them.

  python3 zeus/validate_gold.py            # validate zeus/data/gold, exit 1 on any problem
  python3 zeus/validate_gold.py path.jsonl # validate one file (or several)

Checks, per line: valid JSON object; claim, passages, label, evidence and
rationale present; label one of supported, contradicted, not_covered; at least
two passages, each with a unique id and a source, url and non-empty text;
evidence a list of {passage, quote} where the passage id exists and the quote
is an exact substring of that passage's text; supported and contradicted carry
at least one evidence item, not_covered carries none; no claim repeated inside
one file; no evidence quoted from an atom of the eval split (see eval_atom).
Also runnable from CI; no network.
"""
import hashlib
import json
import os
import sys

LABELS = ("supported", "contradicted", "not_covered")
REQUIRED = ("claim", "passages", "label", "evidence", "rationale")
PASSAGE_KEYS = ("id", "source", "url", "text")
# build_dataset.py's --eval-share default; tests/test_validate_gold.py checks the two agree.
EVAL_SHARE = 0.1


def eval_atom(atom_id, eval_share=EVAL_SHARE):
    """True when build_dataset.stable_split puts this atom in the eval split. Every gold file trains, so a gold
    line whose evidence is an eval atom teaches the model a sentence that eval.jsonl, eval2.jsonl or eval3.jsonl
    then scores it on. Found on 2026-11-20: three gold lines (written 24, 25 and 28 October) quoted atoms that
    the current eval splits hold. Copied here, not imported, so this script stays free of build_dataset's
    dependencies."""
    if not isinstance(atom_id, str) or len(atom_id) < 32:
        return False  # only a full atom id can be placed; the 8-character passage id cannot
    return int(hashlib.sha256(atom_id.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF < eval_share


def check_example(ex):
    """Return a list of problems with one example (empty when it is valid)."""
    bad = []
    if not isinstance(ex, dict):
        return ["line is not a JSON object"]
    for k in REQUIRED:
        if k not in ex:
            bad.append(f"missing key {k}")
    if bad:
        return bad
    if not isinstance(ex["claim"], str) or len(ex["claim"].strip()) < 10:
        bad.append("claim must be a sentence of at least 10 characters")
    if ex["label"] not in LABELS:
        bad.append(f"label {ex['label']!r} not in {LABELS}")
    if not isinstance(ex["rationale"], str) or not ex["rationale"].strip():
        bad.append("rationale must be a non-empty string")
    ps = ex["passages"]
    if not isinstance(ps, list) or len(ps) < 2:
        bad.append("need at least two passages")
        ps = ps if isinstance(ps, list) else []
    texts, ids, eval_ids = {}, set(), set()
    for i, p in enumerate(ps):
        if not isinstance(p, dict):
            bad.append(f"passage {i} is not an object")
            continue
        for k in PASSAGE_KEYS:
            if not isinstance(p.get(k), str) or not p.get(k).strip():
                bad.append(f"passage {i} lacks {k}")
        pid = p.get("id")
        if pid in ids:
            bad.append(f"passage id {pid!r} repeated")
        ids.add(pid)
        if isinstance(p.get("url"), str) and not p["url"].startswith("https://"):
            bad.append(f"passage {pid!r} url is not https")
        texts[pid] = p.get("text") or ""
        if eval_atom(p.get("atom_id")):
            eval_ids.add(pid)
    ev = ex["evidence"]
    if not isinstance(ev, list):
        bad.append("evidence must be a list")
        ev = []
    if ex["label"] == "not_covered" and ev:
        bad.append("not_covered must have empty evidence")
    if ex["label"] in ("supported", "contradicted") and not ev:
        bad.append(f"{ex['label']} needs at least one evidence item")
    for j, e in enumerate(ev):
        if not isinstance(e, dict) or not isinstance(e.get("passage"), str) or not isinstance(e.get("quote"), str):
            bad.append(f"evidence {j} must be an object with passage and quote strings")
            continue
        if e["passage"] not in texts:
            bad.append(f"evidence {j} names passage {e['passage']!r} which is not in passages")
        elif not e["quote"].strip():
            bad.append(f"evidence {j} quote is empty")
        elif e["quote"] not in texts[e["passage"]]:
            bad.append(f"evidence {j} quote is not an exact substring of passage {e['passage']!r}")
        elif e["passage"] in eval_ids:
            bad.append(f"evidence {j} quotes passage {e['passage']!r}, an atom of the eval split (it would train on what eval scores)")
    return bad


def check_file(path):
    """Return (number of valid examples, list of 'line N: problem' strings)."""
    problems, n_ok, seen = [], 0, set()
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                ex = json.loads(line)
            except json.JSONDecodeError as err:
                problems.append(f"line {n}: not JSON ({err.msg})")
                continue
            bad = check_example(ex)
            if not bad and isinstance(ex, dict):
                key = (ex["claim"].strip().lower(), ex["label"])
                if key in seen:
                    bad = ["same claim and label already in this file"]
                seen.add(key)
            if bad:
                problems.extend(f"line {n}: {b}" for b in bad)
            else:
                n_ok += 1
    return n_ok, problems


def main(argv):
    paths = argv[1:]
    if not paths:
        gold = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "gold")
        paths = sorted(os.path.join(gold, p) for p in os.listdir(gold) if p.endswith(".jsonl")) if os.path.isdir(gold) else []
    total, failed = 0, 0
    for p in paths:
        n_ok, problems = check_file(p)
        total += n_ok
        for msg in problems:
            print(f"{p}: {msg}")
        failed += len(problems)
        print(f"{p}: {n_ok} valid example(s)" + (f", {len(problems)} problem(s)" if problems else ""))
    print(f"gold: {total} valid example(s) in {len(paths)} file(s)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

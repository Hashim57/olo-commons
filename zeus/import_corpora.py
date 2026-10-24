#!/usr/bin/env python3
"""Bring open fact-checking corpora into the Zeus task format.

Rule-made contradictions are the ceiling of the Commons-only dataset
(contradicted F1 sat at 0.66 for three versions). Human-written claim and
evidence pairs are the fix, and the open corpora below were written for exactly
this task. Each example becomes a Zeus line (claim, passages with provenance,
label, evidence, rationale) and is written under zeus/data/imported/, which the
train scripts pick up next to data/gold/. Nothing imported ever enters the
frozen eval split.

  python3 zeus/import_corpora.py --corpus vitaminc --n 1500 [--seed 7] [--real-only]
  python3 zeus/import_corpora.py --corpus vitaminc --split dev --n 300 --out zeus/data/imported/vitaminc-eval.jsonl

Corpora (licence first, code second; a corpus is listed only when its licence
allows redistribution in a training set that may serve a commercial product):

  vitaminc   Schuster et al., NAACL 2021. 370k claim and evidence pairs from
             Wikipedia revisions, labels SUPPORTS / REFUTES / NOT ENOUGH INFO.
             Licence: CC BY-SA 3.0 (Wikipedia-derived; LICENSE file in the zip).
             Download: https://raw.githubusercontent.com/TalSchuster/talschuster.github.io/master/static/vitaminc.zip

Not imported, and why:
  scifact        CC BY-NC 2.0 (non-commercial), so it cannot feed a model that
                 serves helius-olo.io. Revisit if the licence changes.
  climate-fever  No licence is stated with the data (the authors ask for a
                 citation only), so it is left out until one is.
  fever          Evidence is given as (page, sentence id) pairs that need the
                 full Wikipedia dump to resolve; VitaminC already carries
                 FEVER-derived pairs with the sentences inline.
"""
import argparse
import hashlib
import io
import json
import os
import random
import re
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "data", "cache")
LABELS = {"SUPPORTS": "supported", "REFUTES": "contradicted", "NOT ENOUGH INFO": "not_covered"}
RATIONALE = {"supported": "The passage states the claim directly.",
             "contradicted": "The passage gives a different value or relation.",
             "not_covered": "The passage is on the topic but does not settle the claim."}

CORPORA = {
    "vitaminc": {
        "url": "https://raw.githubusercontent.com/TalSchuster/talschuster.github.io/master/static/vitaminc.zip",
        "licence": "CC BY-SA 3.0",
        "attribution": "VitaminC (Schuster, Fisch and Barzilay, NAACL 2021), Wikipedia text under CC BY-SA",
        "files": {"train": "vitaminc/train.jsonl", "dev": "vitaminc/dev.jsonl", "test": "vitaminc/test.jsonl"},
    },
}


def detok(s):
    """VitaminC text is tokenised ("guests ." , "( BPI )"). Put the spacing back."""
    s = re.sub(r"\s+([.,;:!?%)\]])", r"\1", s or "")
    s = re.sub(r"([(\[])\s+", r"\1", s)
    s = re.sub(r"\s+'s\b", "'s", s)
    s = re.sub(r"``\s*|\s*''", '"', s)
    s = s.replace(" n't", "n't").replace("�", " ")
    s = re.sub(r"\$\s+(?=\d)", "$", s)
    return re.sub(r"\s+", " ", s).strip()


def page_name(page):
    """VitaminC page titles carry bracket tokens: 'Puss in Boots -LRB-2011 film-RRB-'."""
    return (page or "").replace("-LRB-", "(").replace("-RRB-", ")").replace("-LSB-", "[").replace("-RSB-", "]").strip()


def quote_of(text, limit=160):
    """A quote is an exact substring of the passage; cut at a word boundary."""
    if len(text) <= limit:
        return text
    cut = text.rfind(" ", 0, limit)
    return text[: cut if cut > 40 else limit]


def passage_id(unique_id):
    return "v" + hashlib.sha256(unique_id.encode()).hexdigest()[:7]


def to_example(row, distractors, rng):
    """One VitaminC row -> one Zeus example. distractors: list of other rows for the two extra passages."""
    label = LABELS.get(row.get("label"))
    if not label:
        return None
    claim, evidence = detok(row.get("claim", "")), detok(row.get("evidence", ""))
    if len(claim) < 15 or len(evidence) < 30:
        return None
    page = page_name(row.get("page"))
    rev = row.get("wiki_revision_id") or ""
    url = f"https://en.wikipedia.org/w/index.php?title={page.replace(' ', '_')}" + (f"&oldid={rev}" if rev else "")
    pid = passage_id(row["unique_id"])
    main = {"id": pid, "source": "wikipedia", "url": url, "title": page, "text": evidence, "revision": rev, "corpus": "vitaminc"}
    others, seen = [], {pid}
    for d in rng.sample(distractors, k=min(12, len(distractors))):
        dp = page_name(d.get("page"))
        did = passage_id(d["unique_id"])
        if did in seen or d.get("case_id") == row.get("case_id") or dp == page or len(detok(d.get("evidence", ""))) < 30:
            continue
        seen.add(did)
        others.append({"id": did, "source": "wikipedia", "url": f"https://en.wikipedia.org/w/index.php?title={dp.replace(' ', '_')}", "title": dp, "text": detok(d.get("evidence", "")), "corpus": "vitaminc"})
        if len(others) == 2:
            break
    if len(others) < 2:
        return None
    passages = [main] + others
    rng.shuffle(passages)
    evidence_out = [] if label == "not_covered" else [{"passage": pid, "quote": quote_of(evidence)}]
    return {"claim": claim, "passages": passages, "label": label, "evidence": evidence_out, "rationale": RATIONALE[label],
            "kind": "vitaminc:" + str(row.get("revision_type") or "real"), "case_id": row.get("case_id"), "unique_id": row["unique_id"],
            "licence": CORPORA["vitaminc"]["licence"], "attribution": CORPORA["vitaminc"]["attribution"]}


def balanced_sample(rows, n, rng):
    """Equal numbers per label (as far as the corpus allows), in a stable shuffled order."""
    by = {}
    for r in rows:
        by.setdefault(r.get("label"), []).append(r)
    for k in by:
        rng.shuffle(by[k])
    out, per = [], max(1, n // max(1, len(by)))
    for k in sorted(by):
        out.extend(by[k][:per])
    rng.shuffle(out)
    return out[:n]


def fetch(corpus):
    meta = CORPORA[corpus]
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, corpus + ".zip")
    if not os.path.exists(path):
        print(f"downloading {meta['url']}", file=sys.stderr)
        with urllib.request.urlopen(meta["url"], timeout=120) as r, open(path, "wb") as f:
            f.write(r.read())
    return path


def load_rows(corpus, split, path=None):
    meta = CORPORA[corpus]
    z = zipfile.ZipFile(path or fetch(corpus))
    name = meta["files"][split]
    rows = []
    with z.open(name) as f:
        for line in io.TextIOWrapper(f, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def convert(rows, n, seed=7, real_only=False):
    rng = random.Random(seed)
    if real_only:
        rows = [r for r in rows if r.get("revision_type") == "real"]
    picked = balanced_sample(rows, n, rng)
    pool = rng.sample(rows, k=min(5000, len(rows)))
    out = []
    for r in picked:
        ex = to_example(r, pool, rng)
        if ex:
            out.append(ex)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="vitaminc", choices=sorted(CORPORA))
    ap.add_argument("--split", default="train", choices=["train", "dev", "test"])
    ap.add_argument("--n", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--real-only", action="store_true", help="skip the synthetic (FEVER-derived) revisions")
    ap.add_argument("--zip", help="use an already downloaded zip instead of fetching")
    ap.add_argument("--out")
    args = ap.parse_args()
    rows = load_rows(args.corpus, args.split, args.zip)
    examples = convert(rows, args.n, args.seed, args.real_only)
    out = args.out or os.path.join(HERE, "data", "imported", f"{args.corpus}.jsonl")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        for ex in examples:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    by = {}
    for ex in examples:
        by[ex["label"]] = by.get(ex["label"], 0) + 1
    print(json.dumps({"corpus": args.corpus, "split": args.split, "written": len(examples), "by_label": by, "out": out, "licence": CORPORA[args.corpus]["licence"]}))


if __name__ == "__main__":
    main()

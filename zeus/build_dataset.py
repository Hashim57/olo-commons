#!/usr/bin/env python3
"""Build the Zeus training and eval sets from Olo Commons.

Pulls atoms through the public olo_export RPC (read-only, anon key), then makes
claim verification examples three ways: supported, contradicted (one fact
changed by a rule), not_covered (passages from unrelated atoms). Provenance is
kept on every passage. The eval split is chosen by a stable hash of the atom id,
so atoms never move between splits as the Commons grows.

Usage:
  python zeus/build_dataset.py --supabase-url https://X.supabase.co --anon-key KEY \
      [--out zeus/data] [--max-atoms 5000] [--eval-share 0.1]
"""
import argparse, hashlib, json, os, random, re, sys
from datetime import datetime, timezone
import requests

YEAR_RE = re.compile(r"\b(1[5-9]\d\d|20[0-3]\d)\b")
NUM_RE = re.compile(r"\b(\d{2,}(?:[.,]\d+)?)\b")
SENT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z])")


def fetch_atoms(url, key, max_atoms):
    atoms, after = [], "1970-01-01T00:00:00Z"
    h = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    while len(atoms) < max_atoms:
        r = requests.post(f"{url}/rest/v1/rpc/olo_export", headers=h, json={"p_after": after, "p_limit": 500}, timeout=60)
        r.raise_for_status()
        page, nxt = export_page(r.json())
        if not page:
            break
        atoms.extend(page)
        if not nxt or nxt == after or len(page) < 500:
            break
        after = nxt
    return atoms[:max_atoms]


def export_page(body):
    """olo_export returns {"atoms": [...], "next_after": ts, "licence_note": ...}.
    Older builds returned a bare list. Accept both; return (atoms, next_after)."""
    if isinstance(body, dict):
        atoms = body.get("atoms") or []
        return atoms, body.get("next_after") or (atoms[-1].get("created_at") if atoms else None)
    if isinstance(body, list):
        return body, (body[-1].get("created_at") if body else None)
    return [], None


def sentences(text):
    text = re.sub(r"\s+", " ", text or "").strip()
    return [s.strip() for s in SENT_RE.split(text) if 40 <= len(s.strip()) <= 300]


def stable_split(atom_id, eval_share):
    v = int(hashlib.sha256(atom_id.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return "eval" if v < eval_share else "train"


def passage(a, text=None):
    return {"id": a["id"][:8], "source": a.get("source") or a.get("source_slug") or "", "url": a.get("url", ""), "text": (text or a.get("summary") or a.get("content") or "")[:900]}


# Pairs of words whose swap reverses the meaning of a sentence without touching
# any number or name. These make the negatives a model cannot solve by spotting
# an unfamiliar digit. Only whole words are swapped, case preserved.
FLIPS = [("before", "after"), ("increase", "decrease"), ("increased", "decreased"), ("increases", "decreases"),
         ("higher", "lower"), ("highest", "lowest"), ("larger", "smaller"), ("largest", "smallest"), ("more", "fewer"),
         ("north", "south"), ("east", "west"), ("northern", "southern"), ("eastern", "western"),
         ("first", "last"), ("earliest", "latest"), ("oldest", "youngest"), ("older", "younger"),
         ("above", "below"), ("inside", "outside"), ("positive", "negative"), ("rise", "fall"), ("rising", "falling"),
         ("born", "died"), ("founded", "dissolved"), ("began", "ended"), ("opened", "closed"), ("won", "lost"),
         ("supports", "contradicts"), ("confirmed", "rejected"), ("accepted", "rejected"), ("always", "never"),
         ("male", "female"), ("son", "daughter"), ("brother", "sister"), ("father", "mother"), ("king", "queen"),
         ("can", "cannot"), ("is", "is not"), ("was", "was not"), ("are", "are not"), ("were", "were not")]
FLIP_MAP = {}
for _a, _b in FLIPS:
    FLIP_MAP.setdefault(_a, _b)
    FLIP_MAP.setdefault(_b, _a)


def flip_relation(sentence, rng):
    """Swap one relation word for its opposite. Returns (new_sentence, what_changed) or None."""
    words = re.findall(r"[A-Za-z]+(?: not)?", sentence)
    cands = [w for w in words if w.lower() in FLIP_MAP]
    if not cands:
        return None
    w = rng.choice(cands)
    repl = FLIP_MAP[w.lower()]
    if w[0].isupper():
        repl = repl[0].upper() + repl[1:]
    new = re.sub(r"\b" + re.escape(w) + r"\b(?! not)", repl, sentence, count=1)
    if new == sentence:
        return None
    return new, f"relation {w} -> {repl}"


def contradict(sentence, rng, other_titles, prefer_relation=False):
    """Change exactly one fact by rule. Returns (new_sentence, what_changed) or None.
    Half the time (or always with prefer_relation) a relation flip is tried first,
    so the contradicted set is not only changed digits."""
    if prefer_relation or rng.random() < 0.5:
        f = flip_relation(sentence, rng)
        if f:
            return f
    years = YEAR_RE.findall(sentence)
    if years:
        y = rng.choice(years)
        ny = str(int(y) + rng.choice([-7, -3, 2, 5, 11]))
        return sentence.replace(y, ny, 1), f"year {y} -> {ny}"
    nums = [n for n in NUM_RE.findall(sentence) if not YEAR_RE.fullmatch(n)]
    if nums:
        n = rng.choice(nums)
        try:
            base = float(n.replace(",", ""))
            nn = str(int(base * rng.choice([0.5, 2, 3]))) if base == int(base) else f"{base * 2:.1f}"
            return sentence.replace(n, nn, 1), f"number {n} -> {nn}"
        except ValueError:
            pass
    caps = re.findall(r"\b[A-Z][a-z]{3,}(?: [A-Z][a-z]{3,})?\b", sentence)
    if caps and other_titles:
        c = rng.choice(caps)
        t = rng.choice(other_titles)
        if t and t != c:
            return sentence.replace(c, t, 1), f"name {c} -> {t}"
    return flip_relation(sentence, rng)


def build(atoms, eval_share, seed=7):
    rng = random.Random(seed)
    usable = [a for a in atoms if sentences(a.get("summary") or a.get("content") or "")]
    titles = [a.get("title", "") for a in usable if a.get("title")]
    out = {"train": [], "eval": []}
    for a in usable:
        split = stable_split(a["id"], eval_share)
        sents = sentences(a.get("summary") or a.get("content") or "")
        claim = rng.choice(sents)
        others = rng.sample([o for o in usable if o["id"] != a["id"]], k=min(2, len(usable) - 1))
        # supported
        out[split].append({"claim": claim, "passages": [passage(a)] + [passage(o) for o in others], "label": "supported",
                           "evidence": [{"passage": a["id"][:8], "quote": claim[:160]}],
                           "rationale": "The passage states the claim directly.", "atom_id": a["id"]})
        # contradicted
        c = contradict(claim, rng, [t for t in titles if t != a.get("title")])
        if c:
            out[split].append({"claim": c[0], "passages": [passage(a)] + [passage(o) for o in others], "label": "contradicted",
                               "evidence": [{"passage": a["id"][:8], "quote": claim[:160]}],
                               "rationale": f"The passage gives a different value ({c[1]}).", "atom_id": a["id"]})
        # not covered
        far = rng.sample([o for o in usable if o["id"] != a["id"]], k=min(3, len(usable) - 1))
        out[split].append({"claim": claim, "passages": [passage(o) for o in far], "label": "not_covered", "evidence": [],
                           "rationale": "None of the passages mention this.", "atom_id": a["id"]})
    for k in out:
        rng.shuffle(out[k])
    return out


def count_gold(gold_dir):
    """(number of gold files, number of valid gold examples). A gold line counts
    only if it parses and carries claim, passages, label and evidence."""
    files = n = 0
    for p in sorted(os.listdir(gold_dir)) if os.path.isdir(gold_dir) else []:
        if not p.endswith(".jsonl"):
            continue
        files += 1
        for line in open(os.path.join(gold_dir, p), encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                ex = json.loads(line)
            except json.JSONDecodeError:
                continue
            if all(k in ex for k in ("claim", "passages", "label", "evidence")) and ex["label"] in ("supported", "contradicted", "not_covered"):
                n += 1
    return files, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--supabase-url", default=os.environ.get("SUPABASE_URL", "https://bfldflbkebyapfagsxnr.supabase.co"))
    ap.add_argument("--anon-key", default=os.environ.get("SUPABASE_ANON_KEY"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--max-atoms", type=int, default=5000)
    ap.add_argument("--eval-share", type=float, default=0.1)
    args = ap.parse_args()
    if not args.anon_key:
        sys.exit("anon key required (--anon-key or SUPABASE_ANON_KEY); it is the public read key, not a secret")
    atoms = fetch_atoms(args.supabase_url, args.anon_key, args.max_atoms)
    data = build(atoms, args.eval_share)
    os.makedirs(args.out, exist_ok=True)
    for split in ("train", "eval"):
        with open(os.path.join(args.out, f"{split}.jsonl"), "w") as f:
            for ex in data[split]:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    gold_files, n_gold = count_gold(os.path.join(args.out, "gold"))
    by_label = {l: sum(1 for ex in data["train"] if ex["label"] == l) for l in ("supported", "contradicted", "not_covered")}
    meta = {"built_at": datetime.now(timezone.utc).isoformat(), "atoms": len(atoms), "train": len(data["train"]), "eval": len(data["eval"]),
            "gold_files": gold_files, "gold": n_gold, "train_total": len(data["train"]) + n_gold, "train_by_label": by_label}
    with open(os.path.join(args.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    print(json.dumps(meta))


if __name__ == "__main__":
    main()

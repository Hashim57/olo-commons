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
  python zeus/build_dataset.py --snapshot commons.json      # offline, from the snapshot branch

The offline snapshot (git show origin/snapshot:commons.json, also served by
jsDelivr) holds each atom's id, title, text (the summary, at most 600
characters), url, source, licence and date. Built from it, the examples use the
same atom ids and so the same frozen eval split, but shorter passages than a
live build, and meta.json says "from": "snapshot" so the counts are not mistaken
for a live build. The cloud training job always builds from the live export.
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


def fetch_atoms_keyless(export_url, max_atoms):
    """The same pages through olo-query's keyless export (GET ?export=1), so a cloud job needs no key."""
    atoms, after = [], "1970-01-01T00:00:00Z"
    while len(atoms) < max_atoms:
        r = requests.get(export_url, params={"export": 1, "after": after, "limit": 500}, timeout=60)
        r.raise_for_status()
        page, nxt = export_page(r.json())
        if not page:
            break
        atoms.extend(page)
        if not nxt or nxt == after or len(page) < 500:
            break
        after = nxt
    return atoms[:max_atoms]


def atoms_from_snapshot(snap):
    """Atoms (the export's shape) from the offline snapshot's compact rows: {"fields": [...], "atoms": [[...], ...]}.
    text becomes summary; there is no content and no created_at."""
    fields = snap.get("fields") or []
    out = []
    for row in snap.get("atoms") or []:
        a = dict(zip(fields, row))
        if not a.get("id") or not a.get("text"):
            continue
        out.append({"id": a["id"], "title": a.get("title") or "", "summary": a["text"], "content": "", "url": a.get("url") or "",
                    "source": a.get("source") or "", "licence": a.get("licence"), "published_at": a.get("published_at")})
    return out


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


STOP = set("""about above after again also among an and any are because been before being between both but by can could did does
during each from further had has have having here into its itself just more most much near only other over same should some such
than that their them then there these they this those through under until very was were what when where which while with would
your years year first after known used called including""".split())
WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]{3,}")


def content_words(text):
    """Lower-cased words of four letters or more that carry meaning (stop words dropped)."""
    return {w.lower() for w in WORD_RE.findall(text or "") if w.lower() not in STOP}


def near_misses(claim, a, pool, k=3, max_cover=0.6):
    """Atoms that share words with the claim but do not cover it: the hard kind of
    not_covered, where topic matching would wrongly say supported. Ranked by how
    many claim words they share. An atom is refused when its text holds more than
    max_cover of the claim's content words (it might really support the claim),
    or when it is the claim's own atom. Returns [] when nothing shares a word."""
    cw = content_words(claim)
    if not cw:
        return []
    scored = []
    for o in pool:
        if o["id"] == a["id"]:
            continue
        text = (o.get("summary") or o.get("content") or "")
        if claim[:60] in text:
            continue
        shared = len(cw & content_words(text + " " + (o.get("title") or "")))
        if shared == 0 or shared / len(cw) > max_cover:
            continue
        scored.append((shared, o["id"], o))
    scored.sort(key=lambda t: (-t[0], t[1]))
    return [o for _, _, o in scored[:k]]


def build(atoms, eval_share, seed=7, near_miss=True):
    rng = random.Random(seed)
    # Near-miss negatives use their own generator and go to train only, so the
    # frozen eval split stays byte-identical to earlier builds and scores stay
    # comparable across versions.
    hard_rng = random.Random(seed + 1)
    order_rng = random.Random(seed + 3)
    usable = [a for a in atoms if sentences(a.get("summary") or a.get("content") or "")]
    titles = [a.get("title", "") for a in usable if a.get("title")]
    out = {"train": [], "eval": []}
    hard = []
    for a in usable:
        split = stable_split(a["id"], eval_share)
        sents = sentences(a.get("summary") or a.get("content") or "")
        claim = rng.choice(sents)
        others = rng.sample([o for o in usable if o["id"] != a["id"]], k=min(2, len(usable) - 1))
        # The true passage used to come first in every example, and eval2 showed Zeus had learnt
        # that (41 percent when it comes last, v8). Train passages are shuffled with their own
        # generator; the frozen eval split keeps the old order so its scores stay comparable.
        def ordered(ps):
            if split == "train":
                ps = list(ps)
                order_rng.shuffle(ps)
            return ps
        # supported
        out[split].append({"claim": claim, "passages": ordered([passage(a)] + [passage(o) for o in others]), "label": "supported",
                           "evidence": [{"passage": a["id"][:8], "quote": claim[:160]}],
                           "rationale": "The passage states the claim directly.", "atom_id": a["id"]})
        # contradicted
        c = contradict(claim, rng, [t for t in titles if t != a.get("title")])
        if c:
            out[split].append({"claim": c[0], "passages": ordered([passage(a)] + [passage(o) for o in others]), "label": "contradicted",
                               "evidence": [{"passage": a["id"][:8], "quote": claim[:160]}],
                               "rationale": f"The passage gives a different value ({c[1]}).", "atom_id": a["id"]})
        # not covered
        far = rng.sample([o for o in usable if o["id"] != a["id"]], k=min(3, len(usable) - 1))
        out[split].append({"claim": claim, "passages": [passage(o) for o in far], "label": "not_covered", "evidence": [],
                           "rationale": "None of the passages mention this.", "atom_id": a["id"]})
        # not covered, near miss: related passages that still do not state the claim
        if near_miss and split == "train":
            near = near_misses(claim, a, usable)
            if near:
                hard_rng.shuffle(near)
                hard.append({"claim": claim, "passages": [passage(o) for o in near], "label": "not_covered", "evidence": [],
                                   "rationale": "The passages are on a related topic, but none of them states this claim.",
                                   "atom_id": a["id"], "kind": "near_miss"})
    for k in out:
        rng.shuffle(out[k])
    # Insert near misses after the shuffle, with their own generator, so the main
    # generator's draws (and so the eval split and the plain train order) do not move.
    for ex in hard:
        out["train"].insert(hard_rng.randrange(len(out["train"]) + 1), ex)
    return out


def build_eval2(atoms, eval_share, seed=7):
    """The harder, versioned eval split (eval2.jsonl), over the same eval atoms as the frozen
    split and nothing else, so it never overlaps training. Three patterns a 7B model does
    not get for free from the rule-made split: near-miss not_covered (passages on the
    topic that do not state the claim), relation-flip contradictions (both terms of the
    comparison present, one word changed), and supported claims whose true passage comes
    last among four, so passage order gives nothing away. Its own generator (seed + 2)
    leaves the frozen split and the training order untouched."""
    rng = random.Random(seed + 2)
    usable = [a for a in atoms if sentences(a.get("summary") or a.get("content") or "")]
    titles = [a.get("title", "") for a in usable if a.get("title")]
    out = []
    for a in usable:
        if stable_split(a["id"], eval_share) != "eval":
            continue
        sents = sentences(a.get("summary") or a.get("content") or "")
        claim = rng.choice(sents)
        near = near_misses(claim, a, usable)
        if near:
            out.append({"claim": claim, "passages": [passage(o) for o in near], "label": "not_covered", "evidence": [],
                        "rationale": "The passages are on a related topic, but none of them states this claim.", "atom_id": a["id"], "kind": "near_miss"})
        c = contradict(claim, rng, [t for t in titles if t != a.get("title")], prefer_relation=True)
        if c and c[1].startswith("relation"):
            others = rng.sample([o for o in usable if o["id"] != a["id"]], k=min(2, len(usable) - 1))
            ps = [passage(a)] + [passage(o) for o in others]
            rng.shuffle(ps)
            out.append({"claim": c[0], "passages": ps, "label": "contradicted", "evidence": [{"passage": a["id"][:8], "quote": claim[:160]}],
                        "rationale": f"The passage says the opposite ({c[1]}).", "atom_id": a["id"], "kind": "relation_flip"})
        distractors = rng.sample([o for o in usable if o["id"] != a["id"]], k=min(3, len(usable) - 1))
        out.append({"claim": claim, "passages": [passage(o) for o in distractors] + [passage(a)], "label": "supported",
                    "evidence": [{"passage": a["id"][:8], "quote": claim[:160]}], "rationale": "The last passage states the claim directly.",
                    "atom_id": a["id"], "kind": "true_passage_last"})
    rng.shuffle(out)
    return out


def count_gold(gold_dir, skip_eval=False):
    """(number of files, number of valid examples) in a directory of jsonl files.
    A line counts only if it parses and carries claim, passages, label and
    evidence. With skip_eval, files named *-eval.jsonl (held-out imported sets)
    are left out, since they never train."""
    files = n = 0
    for p in sorted(os.listdir(gold_dir)) if os.path.isdir(gold_dir) else []:
        if not p.endswith(".jsonl") or (skip_eval and p.endswith("-eval.jsonl")):
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
    ap.add_argument("--no-near-miss", action="store_true", help="leave out the near-miss not_covered examples (train only)")
    ap.add_argument("--snapshot", help="build offline from a copy of the snapshot branch's commons.json instead of the live Commons")
    args = ap.parse_args()
    # With the public anon key, read through PostgREST; without it, through the keyless export;
    # with --snapshot, from the offline file (no network).
    if args.snapshot:
        with open(args.snapshot, encoding="utf-8") as f:
            atoms = atoms_from_snapshot(json.load(f))[: args.max_atoms]
    elif args.anon_key:
        atoms = fetch_atoms(args.supabase_url, args.anon_key, args.max_atoms)
    else:
        atoms = fetch_atoms_keyless(f"{args.supabase_url}/functions/v1/olo-query", args.max_atoms)
    data = build(atoms, args.eval_share, near_miss=not args.no_near_miss)
    data["eval2"] = build_eval2(atoms, args.eval_share)
    os.makedirs(args.out, exist_ok=True)
    for split in ("train", "eval", "eval2"):
        with open(os.path.join(args.out, f"{split}.jsonl"), "w") as f:
            for ex in data[split]:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    # eval3: its own module and generator, over the eval atoms only (see zeus/eval3.py and DATA_CARD.md).
    import eval3
    ev3 = eval3.build_eval3(atoms, args.eval_share)
    with open(os.path.join(args.out, "eval3.jsonl"), "w", encoding="utf-8") as f:
        f.write(eval3.dumps(ev3))
    with open(os.path.join(args.out, "eval3.manifest.json"), "w") as f:
        json.dump(eval3.manifest(ev3, args.eval_share, "snapshot" if args.snapshot else "live"), f, indent=2)
    gold_files, n_gold = count_gold(os.path.join(args.out, "gold"))
    imported_files, n_imported = count_gold(os.path.join(args.out, "imported"), skip_eval=True)
    by_label = {l: sum(1 for ex in data["train"] if ex["label"] == l) for l in ("supported", "contradicted", "not_covered")}
    meta = {"built_at": datetime.now(timezone.utc).isoformat(), "atoms": len(atoms), "train": len(data["train"]), "eval": len(data["eval"]), "eval2": len(data["eval2"]),
            "eval3": len(ev3), "eval3_version": eval3.EVAL3_VERSION,
            "gold_files": gold_files, "gold": n_gold, "imported_files": imported_files, "imported": n_imported,
            "train_total": len(data["train"]) + n_gold + n_imported, "train_by_label": by_label,
            "train_near_miss": sum(1 for ex in data["train"] if ex.get("kind") == "near_miss"),
            "from": "snapshot" if args.snapshot else "live"}
    with open(os.path.join(args.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    print(json.dumps(meta))


if __name__ == "__main__":
    main()

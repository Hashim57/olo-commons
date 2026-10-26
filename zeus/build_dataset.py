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



# ---------------------------------------------------------------------------
# Harder train negatives (generator "hard-v1"). Train split only.
#
# The rule-made negatives in build() change one token, and their not_covered
# passages come from unrelated atoms. What VitaminC tests is closer: minimal,
# contrastive edits of a single fact, and claims that sit right next to a
# passage without being stated by it. The generators below make that kind of
# example from the claim's own atom: every hard example keeps the true passage
# among its passages, and each atom gives a contrastive set (a supported
# sentence and its edited twins over the very same passages), so the model has
# to look at the edit rather than at the topic.
#
# They run after build() and never draw from its generators, so eval.jsonl and
# eval2.jsonl stay byte-identical, and --no-hard-negatives reproduces the train
# split of earlier builds exactly. Each atom draws from its own generator,
# seeded by its id, so its hard examples do not move when other atoms are added
# (only its two distractor passages can). Every hard example carries
# "generator": HARD_NEGATIVES_VERSION; bump it when a rule changes, so a
# training run says which generator made its data (meta.json records it too).
# ---------------------------------------------------------------------------
HARD_NEGATIVES_VERSION = "hard-v1"
MAX_YEAR = 2026  # a fixed bound for shifted years (not today's date), so builds are deterministic

# Antonym pairs that FLIPS does not have. Symmetric pairs flip both ways; one-way
# pairs flip left to right only (their right side already flips to something else,
# or the reverse reads badly). Only lower-case occurrences are flipped, so names
# such as "Upper Silesia" or "Major League" are never touched.
EXTRA_FLIPS = [("rose", "fell"), ("rises", "falls"), ("risen", "fallen"), ("grew", "shrank"), ("growing", "shrinking"),
               ("gained", "lost"), ("earlier", "later"),
               ("win", "lose"), ("wins", "loses"), ("winning", "losing"), ("winner", "loser"),
               ("allow", "forbid"), ("allows", "forbids"), ("permitted", "prohibited"), ("legal", "illegal"),
               ("maximum", "minimum"), ("longer", "shorter"), ("longest", "shortest"), ("faster", "slower"),
               ("fastest", "slowest"), ("stronger", "weaker"), ("strongest", "weakest"), ("heavier", "lighter"),
               ("wider", "narrower"), ("deeper", "shallower"), ("warmer", "cooler"), ("hotter", "colder"),
               ("improved", "worsened"), ("improves", "worsens"), ("improve", "worsen"),
               ("enhances", "impairs"), ("enhanced", "impaired"), ("enhance", "impair"),
               ("upregulated", "downregulated"), ("upregulation", "downregulation"), ("upregulates", "downregulates"),
               ("activates", "inhibits"), ("activated", "inhibited"), ("activation", "inhibition"), ("activate", "inhibit"),
               ("promotes", "suppresses"), ("promoted", "suppressed"), ("promote", "suppress"),
               ("presence", "absence"), ("majority", "minority"), ("successful", "unsuccessful"),
               ("efficient", "inefficient"), ("effective", "ineffective"), ("sufficient", "insufficient"),
               ("stable", "unstable"), ("consistent", "inconsistent"), ("complete", "incomplete"),
               ("imports", "exports"), ("imported", "exported"), ("major", "minor"), ("public", "private"),
               ("urban", "rural"), ("internal", "external"), ("indoor", "outdoor"), ("upstream", "downstream"),
               ("ascending", "descending"), ("beneficial", "harmful"), ("advantage", "disadvantage"),
               ("strengthened", "weakened"), ("strengthen", "weaken"), ("accelerated", "slowed"),
               ("overestimated", "underestimated"), ("overestimate", "underestimate"), ("surplus", "deficit"),
               ("victory", "defeat"), ("predecessor", "successor"), ("preceded", "followed"),
               ("senior", "junior"), ("acute", "chronic"), ("benign", "malignant"), ("dominant", "recessive"),
               ("hydrophobic", "hydrophilic"), ("aerobic", "anaerobic"), ("voluntary", "mandatory"),
               ("declined", "rose"), ("declining", "rising"), ("richer", "poorer")]
EXTRA_ONE_WAY = [("early", "late"), ("less", "more"), ("upper", "lower"), ("approved", "rejected"), ("defeated", "lost to"),
                 ("reduced", "increased"), ("reduces", "increases"), ("reduce", "increase"), ("reduction", "increase"),
                 ("northeast", "southwest"), ("northwest", "southeast"), ("southeast", "northwest"), ("southwest", "northeast")]
EXTRA_FLIP_MAP = {}
for _a, _b in EXTRA_FLIPS:
    EXTRA_FLIP_MAP.setdefault(_a, _b)
    EXTRA_FLIP_MAP.setdefault(_b, _a)
for _a, _b in EXTRA_ONE_WAY:
    EXTRA_FLIP_MAP.setdefault(_a, _b)
# never re-flip a word that FLIPS already flips: those negatives exist already
EXTRA_FLIP_MAP = {k: v for k, v in EXTRA_FLIP_MAP.items() if k not in FLIP_MAP}

NEGATORS = {"not", "no", "never", "neither", "nor", "none", "without", "cannot", "nobody", "nothing", "nowhere"}
HEDGES = {"may", "might", "could", "would", "can", "whether", "if", "possibly", "perhaps", "probably", "likely", "unlikely",
          "hypothesis", "hypothesized", "hypothesised", "hypothesize", "suggest", "suggests", "suggested", "speculated", "or"}
ENGLISH_MARKERS = {"the", "of", "and", "is", "was", "with", "that", "for", "were", "are", "has", "by"}
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
# a sentence that asks or supposes rather than asserts ("we test whether X improves Y"): flipping it does not contradict the passage
UNASSERTED_RE = re.compile(r"\b(whether|if|hypothes\w*)\b", re.I)
CAP_SPAN_RE = re.compile(r"\b[A-Z][a-z]{2,}(?: [A-Z][a-z]{2,}){0,2}\b")
NUM_TOKEN_RE = re.compile(r"(?<![\w.,/=\-])(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)(?![\w/\-]|[.,]\d)")


def _quote_spans(s):
    """Character ranges inside double or curly quotes. Edits are never made there:
    a flip inside a quotation changes what someone said, not the fact."""
    return [(m.start(), m.end()) for m in re.finditer(r'"[^"]*"|\u201c[^\u201d]*\u201d|\u2018[^\u2019]*\u2019', s)]


def _in_quote(s, start, end):
    return any(a <= start and end <= b for a, b in _quote_spans(s))


def _words(text):
    return re.findall(r"[a-z]+(?:'[a-z]+)?", (text or "").lower())


def _negated(text):
    return any(w in NEGATORS or w.endswith("n't") for w in _words(text))


def _blocked_before(s, start, k=3):
    """True when one of the k words before position start negates or hedges it
    ("did not increase", "may increase", "increase or decrease"): an edit there does
    not reliably change the truth."""
    return any(w in NEGATORS or w in HEDGES or w.endswith("n't") for w in _words(s[:start])[-k:])


def _norm(text):
    return re.sub(r"\s+", " ", (text or "").lower()).strip(" .")


def _in_any(phrase, texts):
    p = _norm(phrase)
    return bool(p) and any(p in _norm(t) for t in texts)


def _absent(word, texts):
    """True when word (or its stem, so "humans" also catches "human") occurs in none of texts."""
    w = word.lower()
    stem = re.sub(r"(ies|es|s|ed|d)$", "", w) if len(w) > 5 else w
    pat = re.compile(r"\b" + re.escape(stem if len(stem) >= 4 else w), re.I)
    return not any(pat.search(t or "") for t in texts)


def _window(s, start, end, k=2):
    """The span s[start:end] with k words of context on each side."""
    return " ".join(s[:start].split()[-k:] + [s[start:end]] + s[end:].split()[:k])


def _english(s):
    return len(set(_words(s)) & ENGLISH_MARKERS) >= 2


def _contra_ok(s, new, start, new_end, texts):
    """A contradiction counts only when it changed the sentence, the edit is not inside a
    quotation, and neither the new claim nor the edited span with two words of context on
    each side is written in any passage (else a passage might state both, and the label
    would be noise). start and new_end delimit the edit in new."""
    return (new != s and not _in_quote(new, start, max(new_end, start + 1)) and not _in_quote(s, start, start + 1)
            and not _in_any(new, texts) and not _in_any(_window(new, start, new_end), texts))


def _apply(s, start, end, repl):
    return s[:start] + repl + s[end:], start + len(repl)


def hard_antonym_flip(s, texts, rng):
    """One lower-case word swapped for its antonym from EXTRA_FLIPS (rose -> fell, allow -> forbid,
    activates -> inhibits, earlier -> later). Refused when the antonym is already in the sentence
    (it may hold too), when a negation or hedge comes just before, or inside a quotation."""
    lower = s.lower()
    cands = [m for m in re.finditer(r"(?<![\w-])[a-z]+(?![\w-])", s) if m.group(0) in EXTRA_FLIP_MAP
             and not re.search(r"\b" + re.escape(EXTRA_FLIP_MAP[m.group(0)]) + r"\b", lower) and not _blocked_before(s, m.start())
             and not (m.group(0).startswith("allow") and s[m.end():m.end() + 4] == " for")
             and not re.search(r"[a-z]\s[A-Z][a-z]+\s$", s[:m.start()])]  # "Ulmus minor", "Asia Minor": part of a name
    rng.shuffle(cands)
    for m in cands:
        repl = EXTRA_FLIP_MAP[m.group(0)]
        new, ne = _apply(s, m.start(), m.end(), repl)
        if _contra_ok(s, new, m.start(), ne, texts):
            return new, f"{m.group(0)} -> {repl}"
    return None


CHANGE_VERBS = re.compile(r"\b(increased|decreased|rose|fell|grew|declined|dropped|reduced|improved|went|risen|fallen|climbed|changed|increase|decrease|rise|fall|growth|decline)\b", re.I)
VAL = r"\$?\d[\d,]*(?:\.\d+)?%?"
NAME = r"(?!(?:The|This|That|These|Those|Its|Their|Each|Our|Such|Both|All|Most|One)\b)[A-Z][a-z]{2,}(?: [A-Z][a-z]{2,}){0,2}"


def hard_order_swap(s, texts, rng):
    """Two values or names that both stay in the sentence trade places, so nothing new appears
    and only the order carries the fact: "rose from 10 to 20" -> "rose from 20 to 10",
    "10 and 20, respectively" -> "20 and 10, respectively", "A is larger than B" -> "B is larger than A"."""
    pats = []
    m = re.search(r"\bfrom (" + VAL + r") to (" + VAL + r")(?![\w])", s)
    if m and CHANGE_VERBS.search(s) and m.group(1) != m.group(2):
        pats.append((m, "from-to"))
    m = re.search(r"\b(" + VAL + r") and (" + VAL + r")(?: [a-z]+)?,? respectively\b", s)  # an optional unit: "12 and 19 days, respectively"
    if m and m.group(1) != m.group(2):
        pats.append((m, "respectively"))
    m = re.search(r"\b(" + NAME + r") (?:is|was|are|were) (?:\w+er|more \w+|less \w+) than (?:the )?(" + NAME + r")\b", s)
    if m and not set(m.group(1).split()) & set(m.group(2).split()):
        pats.append((m, "comparison"))
    rng.shuffle(pats)
    for m, what in pats:
        a, b = m.group(1), m.group(2)
        new = s[:m.start(1)] + b + s[m.end(1):m.start(2)] + a + s[m.end(2):]
        if not _blocked_before(s, m.start(1)) and _contra_ok(s, new, m.start(1), m.end(2), texts):
            return new, f"order swapped ({what}): {a} and {b}"
    return None


AUX_NOT_RE = re.compile(r"\b(is|was|are|were|has|have|had|does|do|did|will|could|should|can) not (?!only\b|just\b|merely\b|necessarily\b|least\b|all\b|always\b|until\b|yet\b|even\b|to\b)(?=[a-z])")
CONTRACTIONS = {"isn't": "is", "wasn't": "was", "aren't": "are", "weren't": "were", "hasn't": "has", "haven't": "have", "hadn't": "had",
                "doesn't": "does", "didn't": "did", "won't": "will", "can't": "can", "couldn't": "could"}
IRREGULAR_PP = {"been", "become", "done", "gone", "made", "seen", "shown", "taken", "given", "found", "won", "held", "led", "built",
                "written", "known", "grown", "begun", "brought", "kept", "lost", "met", "paid", "sold", "told", "thought"}
NOT_AFTER_AUX = {"also", "still", "now", "then", "often", "always", "usually", "soon", "already", "since", "the", "a", "an", "its",
                 "their", "his", "her", "been", "seen", "even", "ten", "children", "women", "men", "eleven", "seven", "garden", "kitchen"}


def hard_negation(s, texts, rng):
    """Insert or remove one negation, grammatically: "has been" -> "has not been",
    "will open" -> "will not open", "did not win" -> "did win", "wasn't" -> "was".
    Insertion only into a sentence with no negation at all; removal only when the sentence
    has exactly one (so no double negatives). Hedged sentences are left alone."""
    ws = _words(s)
    if any(w in HEDGES for w in ws):
        return None
    n_neg = sum(1 for w in ws if w in NEGATORS or w.endswith("n't"))
    edits = []
    if n_neg == 0:
        for m in re.finditer(r"\b(has|have|had|will) ([a-z]+)\b", s):
            aux, nxt = m.group(1), m.group(2)
            if nxt in NOT_AFTER_AUX and nxt != "been":
                continue
            if aux == "will" or nxt in IRREGULAR_PP or nxt.endswith("ed"):
                edits.append((m.start(2), m.start(2), "not ", f"{aux} -> {aux} not"))
    elif n_neg == 1:
        m = AUX_NOT_RE.search(s)
        if m:
            edits.append((m.end(1), m.end(1) + 4, "", f"{m.group(1)} not -> {m.group(1)}"))
        for c, base in CONTRACTIONS.items():
            for m in re.finditer(r"\b" + re.escape(c) + r"(?![\w'])", s, re.I):
                if m.group(0).islower():
                    edits.append((m.start(), m.end(), base, f"{c} -> {base}"))
    rng.shuffle(edits)
    for start, end, repl, what in edits:
        new, ne = _apply(s, start, end, repl)
        if _contra_ok(s, new, start, ne, texts):
            return new, f"negation {what}"
    return None


def _fmt_like(orig, value):
    """value written the way orig was (thousands commas, decimal places)."""
    if "." in orig:
        return f"{value:.{len(orig.split('.')[1])}f}"
    v = int(round(value))
    return f"{v:,}" if "," in orig else str(v)


def _digits(tok):
    return len(tok.replace(",", "").split(".")[0])


def hard_value_shift(s, texts, rng):
    """A year, month or number changed to a plausible neighbour rather than an absurd one: a year
    by one to three (never past MAX_YEAR), a month to one of the three on either side, a number by
    a fifth to a half of itself with the same number of digits (a percentage stays at most 100).
    The new value must appear in no passage, so the claim cannot be another stated fact."""
    edits = []
    for m in YEAR_RE.finditer(s):
        if s[m.end():m.end() + 1] in ("-", "\u2013", "/", "s") or s[max(0, m.start() - 1):m.start()] in ("-", "\u2013", "/"):
            continue  # ranges (1990-1995) and decades (1990s) are left alone
        y = int(m.group(0))
        for d in rng.sample([-3, -2, -1, 1, 2, 3], 6):
            if y + d <= MAX_YEAR:
                edits.append((m.start(), m.end(), str(y + d), f"year {y} -> {y + d}"))
                break
    for m in re.finditer(r"\b(" + "|".join(MONTHS) + r")\b(?= \d| of \d)", s):
        if m.group(0) == "May":
            continue
        nm = MONTHS[(MONTHS.index(m.group(0)) + rng.choice([-3, -2, -1, 1, 2, 3])) % 12]
        edits.append((m.start(), m.end(), nm, f"month {m.group(0)} -> {nm}"))
    for m in NUM_TOKEN_RE.finditer(s):
        tok = m.group(1)
        if YEAR_RE.fullmatch(tok):
            continue
        prev = s[:m.start()].split()[-1:]
        nxt = s[m.end():].split()[:1]
        if prev and prev[0][:1].isupper() and m.start() > len(prev[0]) + 1:
            continue  # "Apollo 11", "Chapter 12": an identifier, not a quantity
        if (prev and (prev[0].endswith("=") or prev[0].strip(",.") in MONTHS)) or (nxt and (nxt[0].startswith("=") or nxt[0].strip(",.") in MONTHS)):
            continue  # "t = 2", "24 February": a variable or a day of the month
        if re.match(r"%? ?(CI|confidence)\b", s[m.end():]):
            continue  # the level of a confidence interval, not a result
        v = float(tok.replace(",", ""))
        if v < 2:
            continue
        pct = s[m.end():m.end() + 1] == "%" or s[m.end():m.end() + 8] == " percent"
        nv = None
        if v < 10 and "." not in tok:
            nv = rng.choice([x for x in (v - 2, v - 1, v + 1, v + 2) if x >= 2 and x != v])
        else:
            plain = tok.replace(",", "").split(".")[0]
            zeros = min(len(plain) - len(plain.rstrip("0")), len(plain) - 1) if "." not in tok else 0
            for f in rng.sample([0.5, 0.6, 0.7, 0.8, 1.25, 1.4, 1.5, 1.8], 8):
                cand = v * f if "." in tok else round(v * f / 10 ** zeros) * 10 ** zeros
                if cand != v and _digits(_fmt_like(tok, cand)) == _digits(tok) and not (pct and cand > 100):
                    nv = cand
                    break
        if nv is None:
            continue
        new_tok = _fmt_like(tok, nv)
        if new_tok != tok:
            edits.append((m.start(1), m.end(1), new_tok, f"number {tok} -> {new_tok}"))
    rng.shuffle(edits)
    for start, end, repl, what in edits:
        if any(re.search(r"(?<![\w.,])" + re.escape(repl) + r"(?!\w|[.,]\d)", t) for t in texts):
            continue
        new, ne = _apply(s, start, end, repl)
        if _contra_ok(s, new, start, ne, texts):
            return new, what
    return None


# A name is only swapped in a slot that marks its kind: the word before it. "in Warsaw" and
# "in Paris" are both places, "by Hart" and "by Curie" both agents.
SLOT_WORDS = {"in", "at", "by", "from", "near", "to", "with", "against", "under", "than", "between"}


def _name_slots(text):
    """(name, slot word, start, end) for each clean capitalised name in text: right after a slot word,
    not glued to a hyphen or digit, and not part of a longer capitalised run ("Liga Nacional de ...")."""
    out = []
    for m in CAP_SPAN_RE.finditer(text):
        name, before, after = m.group(0), text[:m.start()], text[m.end():]
        prev = before.split()[-1:] if before.endswith(" ") else []
        nxt = after.split()[:1]
        if not prev or prev[0] not in SLOT_WORDS or name.split()[0] in MONTHS:
            continue
        if after[:1] in ("-", "'", "\u2019") or (nxt and (nxt[0][:1].isupper() or nxt[0][:1].isdigit() or nxt[0] in ("de", "of", "del", "la"))):
            continue
        out.append((name, prev[0], m.start(), m.end()))
    return out


def hard_entity_swap(s, own_text, texts, rng):
    """A year or a name in the sentence swapped for another of the same kind that the SAME passage
    mentions elsewhere: the hardest substitution, because the new value is on topic and really is in
    the passage. Names are matched by their slot (the same preposition before both, e.g. "in Warsaw"
    and "in Paris"), the same number of words, and no shared word."""
    edits = []
    years_s = set(YEAR_RE.findall(s))
    for y in sorted(years_s):
        for z in sorted(set(YEAR_RE.findall(own_text)) - years_s):
            for m in re.finditer(r"(?<![\w\-\u2013/])" + y + r"(?![\w\-\u2013/])", s):
                edits.append((m.start(), m.end(), z, f"year {y} -> {z} (from the same passage)"))
    others = {}
    for name, slot, _, _ in _name_slots(own_text.replace(s, " . ")):
        others.setdefault((slot, len(name.split())), set()).add(name)
    for span, slot, start, end in _name_slots(s):
        for o in sorted(others.get((slot, len(span.split())), ())):
            if o not in s and not set(o.split()) & set(span.split()):
                edits.append((start, end, o, f"name {span} -> {o} (from the same passage)"))
    rng.shuffle(edits)
    for start, end, repl, what in edits[:12]:
        new, ne = _apply(s, start, end, repl)
        if not _blocked_before(s, start) and _contra_ok(s, new, start, ne, texts):
            return new, what
    return None


def hard_quantifier(s, texts, rng):
    """A quantifier turned to its opposite: "all X" -> "no X", "all of the" -> "none of the",
    "none of" -> "all of", "most X" -> "few X". Fixed phrases (at all, after all, all but, the most)
    are left alone."""
    edits = []
    for m in re.finditer(r"\b[Aa]ll (?=of\b)", s):
        edits.append((m.start(), m.start() + 3, "none", "all of -> none of"))
    # "All X ..." and "Most X ..." only as the subject at the start of the sentence, where "No X" and
    # "Few X" read naturally ("across all levels" -> "across no levels" would not)
    m = re.match(r"All (?!but\b|over\b)(?=[a-z]+s\b)", s)
    if m:
        edits.append((0, 3, "no", "all -> no"))
    for m in re.finditer(r"\b[Nn]one of\b", s):
        edits.append((m.start(), m.start() + 4, "all", "none of -> all of"))
    for m in re.finditer(r"\b[Mm]ost (?=of the\b)", s):
        if _words(s[:m.start()])[-1:] not in (["the"], ["a"], ["at"]):
            edits.append((m.start(), m.start() + 4, "few", "most of -> few of"))
    m = re.match(r"Most (?=[a-z]+s\b)", s)
    if m and not s[5:].split()[0].endswith("ous"):
        edits.append((0, 4, "few", "most -> few"))
    rng.shuffle(edits)
    for start, end, repl, what in edits:
        if s[start].isupper():
            repl = repl.capitalize()
        new, ne = _apply(s, start, end, repl)
        if not _blocked_before(s, start, k=2) and _contra_ok(s, new, start, ne, texts):
            return new, f"quantifier {what}"
    return None


# not_covered twins keep the sentence's people, places and things but say something
# about them that no passage states. Every content word the edit adds must be absent
# from every passage of the example (so the claim is not accidentally entailed), and
# the sentence must carry no negation (so a strengthening cannot turn into a flip).
MODAL_SHIFTS = [("may", "will"), ("might", "will"), ("is expected to", "has been shown to"), ("are expected to", "have been shown to"),
                ("was expected to", "was shown to"), ("were expected to", "were shown to"), ("was proposed", "was adopted"),
                ("were proposed", "were adopted"), ("has been proposed", "has been adopted"), ("have been proposed", "have been adopted"),
                ("suggests that", "proves that"), ("suggest that", "prove that"), ("suggested that", "proved that"),
                ("is associated with", "causes"), ("are associated with", "cause"), ("was associated with", "caused"),
                ("were associated with", "caused"), ("is linked to", "causes"), ("are linked to", "cause"), ("was linked to", "caused"),
                ("were linked to", "caused"), ("is correlated with", "causes"), ("are correlated with", "cause"),
                ("is designed to", "has been shown to"), ("are designed to", "have been shown to"),
                ("a potential", "a proven"), ("as potential", "as proven"), ("a possible", "a proven")]
SCOPE_SHIFTS = [("in mice", "in humans"), ("in rats", "in humans"), ("in animals", "in humans"), ("in animal models", "in humans"),
                ("in vitro", "in patients"), ("in cell lines", "in patients"), ("in adults", "in children"), ("in children", "in adults"),
                ("in women", "in men"), ("in men", "in women"), ("in Europe", "worldwide"), ("in the United States", "worldwide")]
# Each relation shift applies only when its context word is in the sentence, so "produced by" becomes
# "directed by" for a film and never for a car.
FILM_MUSIC = r"\b(film|movie|album|song|single|series|episode|documentary|play|opera|musical|show|soundtrack|video)s?\b"
MEDICAL = r"\b(patients?|disease|infection|cancer|disorder|symptoms|syndrome|condition|drug|therapy|clinical)\b"
BAND_GROUP = r"\bmember of (the )?([\w-]+ ){0,3}(band|party|group|club|society|team|committee|association|organi[sz]ation|movement|collective|duo|trio)s?\b"
COUNTRIES = ["France", "Germany", "Spain", "Italy", "Portugal", "Poland", "Sweden", "Norway", "Finland", "Denmark", "Austria", "Greece",
             "Ireland", "Belgium", "Iceland", "Switzerland", "Canada", "Mexico", "Brazil", "Argentina", "Chile", "Peru", "Colombia",
             "China", "Japan", "India", "Pakistan", "Indonesia", "Vietnam", "Thailand", "Australia", "Egypt", "Nigeria", "Kenya",
             "Ethiopia", "Turkey", "Iran", "Russia", "Ukraine", "Romania", "Hungary", "Morocco"]
RELATION_SHIFTS = [("directed by", "produced by", FILM_MUSIC), ("produced by", "directed by", FILM_MUSIC),
                   ("written by", "directed by", FILM_MUSIC), ("composed by", "performed by", FILM_MUSIC),
                   ("performed by", "composed by", FILM_MUSIC), ("designed by", "built by", r"\b(building|bridge|church|house|tower|ship|station|hall|stadium|museum)\b"),
                   ("built by", "designed by", r"\b(building|bridge|church|house|tower|ship|station|hall|stadium|museum)\b"),
                   ("founded by", "funded by", None), ("funded by", "founded by", None), ("studied at", "taught at", None),
                   ("taught at", "studied at", None), ("was nominated for", "won", None), ("were nominated for", "won", None),
                   ("member of", "founder of", BAND_GROUP), ("treats", "prevents", MEDICAL), ("reduces", "eliminates", None),
                   ("detects", "predicts", None), ("detect", "predict", None)]
# Added clauses only go on sentences that report a finding (research) or an event (everything else),
# so the clause reads as a plausible extra detail rather than as noise a model could spot by its oddness.
ADDONS_RESEARCH = [", a result later replicated in a second independent cohort", ", according to a later independent review",
                   ", a finding that held in every subgroup analysed"]
ADDONS_GENERAL = [", according to a later independent review", " despite strong public opposition", " after years of delays",
                  " with support from the national government"]
FINDING_RE = re.compile(r"\b(found|find|finds|showed|shows|show|demonstrated|demonstrates|revealed|reveals|observed|improved|improves|reduced|reduces|increased|increases|achieved|achieves|outperformed|outperforms|associated)\b")
EVENT_RE = re.compile(r"\b(founded|opened|built|released|elected|formed|established|published|launched|signed|appointed|completed|introduced|created|began|premiered|inaugurated|constructed|acquired)\b")
RESEARCH_SOURCES = {"arxiv", "pubmed"}


def _nc_ok(s, new, added, texts):
    """A not_covered edit counts only when it changed the sentence, the new claim is in no passage,
    and every content word it added (there must be one) is absent from all passages."""
    words = [w for w in content_words(added) if len(w) >= 4]
    return new != s and bool(words) and not _in_any(new, texts) and all(_absent(w, texts) for w in words)


def _phrase_edits(s, table, rng):
    out = [(m.start(), m.end(), dst, src) for src, dst in table for m in re.finditer(r"\b" + re.escape(src) + r"\b", s)]
    rng.shuffle(out)
    return out


def hard_modal_shift(s, texts, rng):
    """A hedge, plan or correlation stated as certain, done or causal: "may reduce" -> "will reduce",
    "is associated with" -> "causes", "was proposed" -> "was adopted", "suggests that" -> "proves that".
    The passage says less than the claim, so it does not cover it."""
    if _negated(s):
        return None
    for start, end, dst, src in _phrase_edits(s, MODAL_SHIFTS, rng):
        if _in_quote(s, start, end):
            continue
        new, _ = _apply(s, start, end, dst)
        if dst == "will":
            nxt = s[end:].split()[:1]
            # "may" as a modal: lower case, after the subject, before a bare verb
            if start > 0 and nxt and re.fullmatch(r"[a-z]+", nxt[0]) and new != s and not _in_any(new, texts) and _absent("will", texts):
                return new, f"modal {src} -> {dst}"
        elif _nc_ok(s, new, dst, texts):
            return new, f"modal {src} -> {dst}"
    return None


def hard_scope_shift(s, texts, rng):
    """The finding carried to a group or place the passage never mentions: "in mice" -> "in humans",
    "in adults" -> "in children", "in France" -> "in France and Japan" (the added country is in no passage)."""
    if _negated(s):
        return None
    edits = _phrase_edits(s, SCOPE_SHIFTS, rng)
    for m in re.finditer(r"\b(in|across|throughout) (" + "|".join(COUNTRIES) + r")\b(?![\u2019'])(?! [A-Z])", s):
        absent = [c for c in COUNTRIES if c != m.group(2) and _absent(c, texts)]
        if absent:
            edits.append((m.start(2), m.end(2), f"{m.group(2)} and {rng.choice(absent)}", m.group(2)))
    for start, end, dst, src in edits:
        prev, after = _words(s[:start])[-2:], s[end:]
        if "only" in prev or "exclusively" in prev or _in_quote(s, start, end):
            continue
        if re.match(r" [A-Z\d]", after) or (" and " in dst and re.match(r" (and|or)\b", after)):
            continue
        if dst == "worldwide" and not re.match(r"[.;]|$|, [a-z]| (where|since|for|by|until|from)\b", after):
            continue  # "in the United States Army", "in Australia and New Zealand": the place is part of something longer
        new, _ = _apply(s, start, end, dst)
        if _nc_ok(s, new, dst[len(src):] if dst.startswith(src) else dst, texts):
            return new, f"scope {src} -> {dst}"
    return None


def hard_relation_shift(s, texts, rng):
    """The same people and things in a different relation that the passage neither states nor rules
    out: "directed by" -> "produced by", "studied at" -> "taught at", "was nominated for" -> "won",
    "treats" -> "prevents"."""
    if _negated(s):
        return None
    ctxs = {src: ctx for src, dst, ctx in RELATION_SHIFTS}
    for start, end, dst, src in _phrase_edits(s, [(a, b) for a, b, _ in RELATION_SHIFTS], rng):
        ctx = ctxs[src]
        # the context word must sit right before the phrase ("a 1958 film directed by"); for "member of"
        # and "treats" it may be anywhere in the sentence ("treats X as Y" is never a treatment)
        near = s if src in ("member of", "treats") else " ".join(s[:start].split()[-4:])
        if _in_quote(s, start, end) or (ctx and not re.search(ctx, near, re.I)) or (src == "treats" and re.search(r"\bas\b", s[end:])):
            continue
        new, _ = _apply(s, start, end, dst)
        if _nc_ok(s, new, dst, texts):
            return new, f"relation {src} -> {dst}"
    return None


def hard_added_clause(s, texts, rng, source=""):
    """The true sentence plus a qualifier or clause no passage supports ("..., according to a later
    independent review", "... in a randomized controlled trial"). The first part is covered, the
    added part is not, so the whole claim is not_covered."""
    if not re.search(r"[A-Za-z0-9)]\.$", s) or len(s) > 240 or _negated(s) or _quote_spans(s):
        return None
    pool = ADDONS_RESEARCH if source in RESEARCH_SOURCES else ADDONS_GENERAL
    if not (FINDING_RE if source in RESEARCH_SOURCES else EVENT_RE).search(s):
        return None
    for add in rng.sample(pool, len(pool)):
        new = s[:-1] + add + "."
        if _nc_ok(s, new, add, texts):
            return new, "added:" + add.lstrip(", ")
    return None


CONTRA_GENERATORS = ["antonym_flip", "order_swap", "negation", "value_shift", "entity_swap", "quantifier"]
NC_GENERATORS = ["modal_shift", "scope_shift", "relation_shift", "added_clause"]
HARD_RATIONALE = {
    "antonym_flip": "The passage says the opposite ({}).",
    "order_swap": "The passage gives the same values or names the other way round ({}).",
    "negation": "The passage states the reverse of the claim ({}).",
    "value_shift": "The passage gives a different value ({}).",
    "entity_swap": "The passage gives a different one, though both appear in it ({}).",
    "quantifier": "The passage gives the opposite quantity ({}).",
    "modal_shift": "The passage states this only as possible, planned or associated; the claim states it as certain, done or causal.",
    "scope_shift": "The passage is about a different group or place; it says nothing about the one in the claim.",
    "relation_shift": "The passage names the same people and things but does not state this relation between them.",
    "added_clause": "The passage supports the first part of the claim, but nothing in it supports the added part.",
}


def run_hard_generator(name, s, own_text, texts, rng, source=""):
    """One named hard generator on sentence s: (new_claim, what_changed) or None."""
    if name == "entity_swap":
        return hard_entity_swap(s, own_text, texts, rng)
    if name == "added_clause":
        return hard_added_clause(s, texts, rng, source)
    return globals()["hard_" + name](s, texts, rng)


def hard_examples_for_atom(a, sents, distractors, rng, taken=()):
    """The contrastive set for one atom: a sentence s as supported, plus up to one contradicted and
    one not_covered twin of s, all over the same passages (the atom and its distractors, in one
    shuffled order). Sentences already used as a supported claim are tried last. Contradicted twins
    quote s, an exact substring of the atom's passage; not_covered twins carry no evidence. Returns []
    when no rule applies cleanly."""
    own = passage(a)
    if not own["text"]:
        return []
    ps = [own] + [passage(o) for o in distractors]
    rng.shuffle(ps)
    texts = [p["text"] for p in ps]
    cands = [x for x in sents if x in own["text"] and _english(x)]
    rng.shuffle(cands)
    cands.sort(key=lambda x: x in taken)
    best = None
    for s in cands:
        got = []
        for family in (CONTRA_GENERATORS, NC_GENERATORS):
            if family is CONTRA_GENERATORS and UNASSERTED_RE.search(s):
                continue
            for name in rng.sample(family, len(family)):
                r = run_hard_generator(name, s, own["text"], texts, rng, a.get("source") or "")
                if r:
                    got.append((name, r))
                    break
        if got and (best is None or len(got) > len(best[1])):
            best = (s, got)
        if len(got) == 2:
            break
    if not best:
        return []
    s, got = best
    base = {"passages": ps, "atom_id": a["id"], "pair": f"{a['id']}:{HARD_NEGATIVES_VERSION}", "generator": HARD_NEGATIVES_VERSION}
    out = [dict(base, claim=s, label="supported", evidence=[{"passage": own["id"], "quote": s}],
                rationale="The passage states the claim directly.", kind="hard_twin_supported")]
    for name, (new, what) in got:
        if name in CONTRA_GENERATORS:
            out.append(dict(base, claim=new, label="contradicted", evidence=[{"passage": own["id"], "quote": s}],
                            rationale=HARD_RATIONALE[name].format(what), kind="hard_" + name, edit=what))
        else:
            out.append(dict(base, claim=new, label="not_covered", evidence=[], rationale=HARD_RATIONALE[name], kind="hard_" + name, edit=what))
    return out


def add_hard_negatives(train, atoms, eval_share, seed=7):
    """Insert the hard-v1 contrastive sets into train (in place) and return them. Train atoms only,
    and distractor passages from train atoms only. Each atom draws from a generator seeded by its id;
    insertion positions come from their own generator (seed + 5). Nothing here draws from build()'s
    generators, so the frozen eval split, eval2 and the order of the existing train examples stay put."""
    usable = [a for a in atoms if sentences(a.get("summary") or a.get("content") or "")]
    pool = [a for a in usable if stable_split(a["id"], eval_share) == "train"]
    taken = {}
    for ex in train:
        if ex.get("label") == "supported":
            taken.setdefault(ex.get("atom_id"), set()).add(ex["claim"])
    hard, seen = [], set()
    for i, a in enumerate(pool):
        if len(pool) < 3:
            break
        if a["id"] in seen:
            continue  # an atom listed twice (the snapshot has a few) gives one contrastive set, not two copies
        seen.add(a["id"])
        rng = random.Random(f"{seed}:{HARD_NEGATIVES_VERSION}:{a['id']}")
        picks = rng.sample(range(len(pool) - 1), 2)
        distractors = [pool[j if j < i else j + 1] for j in picks]
        sents = sentences(a.get("summary") or a.get("content") or "")
        hard.extend(hard_examples_for_atom(a, sents, distractors, rng, taken.get(a["id"], set())))
    ins = random.Random(seed + 5)
    for ex in hard:
        train.insert(ins.randrange(len(train) + 1), ex)
    return hard


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--supabase-url", default=os.environ.get("SUPABASE_URL", "https://bfldflbkebyapfagsxnr.supabase.co"))
    ap.add_argument("--anon-key", default=os.environ.get("SUPABASE_ANON_KEY"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--max-atoms", type=int, default=5000)
    ap.add_argument("--eval-share", type=float, default=0.1)
    ap.add_argument("--no-near-miss", action="store_true", help="leave out the near-miss not_covered examples (train only)")
    ap.add_argument("--no-hard-negatives", action="store_true", help=f"leave out the {HARD_NEGATIVES_VERSION} contrastive train negatives (train only; eval is never affected)")
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
    hard = [] if args.no_hard_negatives else add_hard_negatives(data["train"], atoms, args.eval_share)
    data["eval2"] = build_eval2(atoms, args.eval_share)
    os.makedirs(args.out, exist_ok=True)
    for split in ("train", "eval", "eval2"):
        with open(os.path.join(args.out, f"{split}.jsonl"), "w") as f:
            for ex in data[split]:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    gold_files, n_gold = count_gold(os.path.join(args.out, "gold"))
    imported_files, n_imported = count_gold(os.path.join(args.out, "imported"), skip_eval=True)
    by_label = {l: sum(1 for ex in data["train"] if ex["label"] == l) for l in ("supported", "contradicted", "not_covered")}
    meta = {"built_at": datetime.now(timezone.utc).isoformat(), "atoms": len(atoms), "train": len(data["train"]), "eval": len(data["eval"]), "eval2": len(data["eval2"]),
            "gold_files": gold_files, "gold": n_gold, "imported_files": imported_files, "imported": n_imported,
            "train_total": len(data["train"]) + n_gold + n_imported, "train_by_label": by_label,
            "train_near_miss": sum(1 for ex in data["train"] if ex.get("kind") == "near_miss"),
            "from": "snapshot" if args.snapshot else "live"}
    # which generators made the train split, so a training run can say what it trained on
    meta["train_generators"] = ["rules-v1"] + ([] if args.no_hard_negatives else [HARD_NEGATIVES_VERSION])
    meta["train_hard_by_kind"] = {k: sum(1 for ex in hard if ex["kind"] == k) for k in sorted({ex["kind"] for ex in hard})}
    with open(os.path.join(args.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    print(json.dumps(meta))


if __name__ == "__main__":
    main()

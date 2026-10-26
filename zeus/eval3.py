#!/usr/bin/env python3
"""eval3: the third frozen Commons eval split, versioned (eval3.jsonl plus eval3.manifest.json).

Built only over the frozen eval atoms (the same stable hash of the atom id as eval.jsonl and
eval2.jsonl), and every passage in it also comes from an eval atom, so no training atom's text
appears in it at all. It has its own generator (this module), seeded by the atom id and the
version string, never by the run time or by the order atoms arrive in, so the same export always
gives the same bytes, and eval.jsonl and eval2.jsonl are not touched.

Six patterns, each tagged in the line's `kind` so a score can be reported per pattern. They are
made by rule in the style of the hand-made gold patterns (zeus/data/gold), never copied from
them: gold trains, this split only measures.

  near_miss_names   not_covered   the claim's atom with the claim sentence removed, plus near-miss
                                  atoms; every name in the claim is in the passages, the claim is not
  relation_flip     contradicted  one strict opposite flipped (higher/lower, north/south, first/last,
                                  always/never ...), lowercase only so names are never touched;
                                  both terms of the comparison stay in the passage; passages shuffled
  before_after      contradicted  before/after, earlier/later, earliest/latest flipped
  modal_shift       not_covered   "may", "might" or "can" in the passage becomes "will" in the claim:
                                  the passage says it is possible, not that it happens
  two_passage       supported     two sentences from two different atoms joined into one claim, so
                                  neither passage alone supports it
  paraphrase_decade supported     "in 1863" restated as "in the 1860s", which the year entails

Versioning: EVAL3_VERSION names the generator. Any change to what this module writes for the same
atoms must bump it (eval3-v2, ...), so a score on eval3-v1 is never silently compared with one on
a different split. zeus/tests/test_eval3.py pins the output for a fixed synthetic export to a hash
and fails when the bytes change under an unchanged version. The manifest records the version, the
atom-hash rule, the eval share, counts per pattern and label, and the sha256 of eval3.jsonl; the
content hash also moves when the Commons grows (new eval atoms), the version only when the rules do.
"""
import hashlib
import json
import random
import re

from build_dataset import STOP, content_words, near_misses, passage, sentences, stable_split

EVAL3_VERSION = "eval3-v1"
SPLIT_RULE = "eval when int(sha256(atom_id).hexdigest()[:8], 16) / 0xFFFFFFFF < eval_share (build_dataset.stable_split)"
PATTERNS = ("near_miss_names", "relation_flip", "before_after", "modal_shift", "two_passage", "paraphrase_decade")

# Strict opposites only: swapping one of these reverses the statement. Event verbs (born/died,
# opened/closed, won/lost) are left out on purpose: "born in Warsaw" turned into "died in Warsaw"
# is not stated by the passage, but it is not contradicted by it either. Negations (is/is not,
# can/cannot) are left out too, so the pattern measures reading a relation, not spotting "not".
RELATION_PAIRS = [("higher", "lower"), ("highest", "lowest"), ("larger", "smaller"), ("largest", "smallest"),
                  ("longer", "shorter"), ("longest", "shortest"), ("increase", "decrease"), ("increased", "decreased"),
                  ("increases", "decreases"), ("increasing", "decreasing"), ("north", "south"), ("east", "west"),
                  ("northern", "southern"), ("eastern", "western"), ("first", "last"), ("oldest", "youngest"),
                  ("older", "younger"), ("above", "below"), ("inside", "outside"), ("positive", "negative"),
                  ("always", "never"), ("maximum", "minimum"), ("male", "female")]
TEMPORAL_PAIRS = [("before", "after"), ("earlier", "later"), ("earliest", "latest")]
OPENER_SKIP = {"it", "its", "he", "she", "his", "her", "they", "their", "them", "this", "these", "those", "that", "such", "both",
                 "we", "our", "us", "you", "i", "here", "however", "thus", "therefore", "moreover", "furthermore",
                 "additionally", "second", "third", "finally", "more", "also", "hence", "consequently", "instead",
                 "similarly", "specifically", "overall", "then", "yet", "still", "besides", "meanwhile", "to"}
FIRST_PERSON_RE = re.compile(r"\b(we|our|us)\b", re.I)
FUNCTION_START = {"the", "a", "an", "in", "on", "at", "of", "for", "from", "by", "with", "after", "before", "during", "as", "when", "while", "since", "there"}
COMMON_START = FUNCTION_START | STOP | {"despite", "however", "although", "recent", "many", "several", "we", "our", "here",
                                      "one", "two", "all", "no", "unlike", "like", "using", "following", "according"}
MODAL_RE = re.compile(r"\b(may|might|can) (?!not\b|be able\b|also be\b)([a-z]{3,})\b")
DECADE_RE = re.compile(r"\bin (1[5-9]\d\d|20[0-3]\d)\b")
END_RE = re.compile(r"[.!?][\"')\]]?$")
NAME_RE = re.compile(r"\b[A-Z][A-Za-z'-]+")


def _pairs_map(pairs):
    m = {}
    for a, b in pairs:
        m.setdefault(a, b)
        m.setdefault(b, a)
    return m


RELATION_MAP = _pairs_map(RELATION_PAIRS)
TEMPORAL_MAP = _pairs_map(TEMPORAL_PAIRS)


def atom_rng(atom_id, pattern):
    """The generator for one atom and one pattern: seeded by the version, the pattern and the atom id only."""
    return random.Random(int(hashlib.sha256(f"{EVAL3_VERSION}:{pattern}:{atom_id}".encode()).hexdigest()[:16], 16))


def _text(a):
    return a.get("summary") or a.get("content") or ""


def _starts_with_pronoun(s):
    first = s.split()[0].lower().strip(",;:'\"") if s.split() else ""
    return first in OPENER_SKIP


def claim_sentences(text):
    """The sentences a claim may be made from: complete (ending in . ! or ?, so a summary cut at its
    length limit never gives half a sentence), at least six words, and not opening with a pronoun
    or a linking word whose referent would be missing from a one-sentence claim ("It", "However",
    "Here"), and not written in the first person (an abstract's "we" has no referent in a claim).
    Catalogue lines (several colons, or opening with a number such as "47 pages : 31 cm") and
    lower-case description fragments are not sentences and are left out."""
    return [s for s in sentences(text) if END_RE.search(s) and len(s.split()) >= 6 and not _starts_with_pronoun(s)
            and s.count(":") <= 1 and (s[0].isupper() or s[0] in "\"'") and not FIRST_PERSON_RE.search(s)]


def _quotable(a):
    """Claim sentences of the atom that are an exact substring of its passage text, so an evidence quote always is."""
    pt = passage(a)["text"]
    return [s for s in claim_sentences(_text(a)) if s in pt]


def flip_word(sentence, table, rng):
    """Swap one lowercase whole word found in `table` for its opposite. Returns (new, "a -> b") or None.
    Capitalised words are never swapped: mid-sentence they are names (North Carolina, First World War)."""
    cands = sorted({w for w in re.findall(r"\b[a-z]+\b", sentence) if w in table})
    if not cands:
        return None
    w = rng.choice(cands)
    new = re.sub(r"\b" + re.escape(w) + r"\b", table[w], sentence, count=1)
    return (new, f"{w} -> {table[w]}") if new != sentence else None


def claim_names(s, context=""):
    """Capitalised words of a sentence. The sentence's first word counts only when it is also written
    with a capital somewhere mid-sentence in `context` (the atom's text and title), so "Thoreau" is a
    name and "Large" or "The" is not."""
    names = NAME_RE.findall(s)
    if names and s.startswith(names[0]):
        first = names[0]
        if not re.search(r"[^.!?\s]\s+" + re.escape(first) + r"\b", context):
            names = names[1:]
    return names


def _distractors(rng, pool, exclude, k):
    cands = [o for o in pool if o["id"] not in exclude]
    return rng.sample(cands, k=min(k, len(cands)))


def _line(claim, ps, label, evidence, rationale, atom_id, kind, rng):
    ps = list(ps)
    rng.shuffle(ps)
    return {"claim": claim, "passages": ps, "label": label, "evidence": evidence, "rationale": rationale,
            "atom_id": atom_id, "kind": kind, "version": EVAL3_VERSION}


def near_miss_names(a, pool, max_cover=0.5):
    rng = atom_rng(a["id"], "near_miss_names")
    norm = re.sub(r"\s+", " ", _text(a)).strip()
    sents = claim_sentences(norm)
    rng.shuffle(sents)
    for s in sents:
        rest = re.sub(r"\s+", " ", norm.replace(s, " ", 1)).strip()
        names = claim_names(s, (a.get("title") or "") + ". " + norm)
        cw = content_words(s)
        if len(rest) < 40 or not names or not cw or s[:60] in rest:
            continue
        if len(cw & content_words(rest + " " + (a.get("title") or ""))) / len(cw) > max_cover:
            continue  # the rest of the atom may restate the claim
        own = passage(a, rest)
        near = [o for o in near_misses(s, a, pool, k=2) if s[:60] not in passage(o)["text"]]
        ps = [own] + [passage(o) for o in near]
        if len(ps) < 2:
            ps += [passage(o) for o in _distractors(rng, pool, {a["id"]}, 1)]
        joined = " ".join(p["text"] for p in ps)
        if len(ps) < 2 or s in joined or not all(re.search(r"\b" + re.escape(n) + r"\b", joined) for n in names):
            continue
        return _line(s, ps, "not_covered", [], "The passages name everything in the claim, but none of them states it.", a["id"], "near_miss_names", rng)
    return None


def _flip_line(a, pool, table, kind, rationale):
    rng = atom_rng(a["id"], kind)
    sents = _quotable(a)
    rng.shuffle(sents)
    pt = passage(a)["text"]
    for s in sents:
        f = flip_word(s, table, rng)
        if not f or f[0] in pt:
            continue
        ps = [passage(a)] + [passage(o) for o in _distractors(rng, pool, {a["id"]}, 2)]
        return _line(f[0], ps, "contradicted", [{"passage": a["id"][:8], "quote": s}], rationale.format(f[1]), a["id"], kind, rng)
    return None


def relation_flip(a, pool):
    return _flip_line(a, pool, RELATION_MAP, "relation_flip", "The passage states the opposite relation ({}).")


def before_after(a, pool):
    return _flip_line(a, pool, TEMPORAL_MAP, "before_after", "The passage gives the opposite order in time ({}).")


def modal_shift(a, pool):
    rng = atom_rng(a["id"], "modal_shift")
    sents = _quotable(a)
    rng.shuffle(sents)
    pt = passage(a)["text"]
    for s in sents:
        m = MODAL_RE.search(s)
        if not m:
            continue
        claim = s[:m.start(1)] + "will" + s[m.end(1):]
        if claim in pt:
            continue
        ps = [passage(a)] + [passage(o) for o in _distractors(rng, pool, {a["id"]}, 2)]
        return _line(claim, ps, "not_covered", [], f"The passage says this {m.group(1)} happen, not that it will.", a["id"], "modal_shift", rng)
    return None


def _lower_first(s):
    """Lower-case the first word of the second half of a joined claim when it is a common word, never a name."""
    w = s.split(" ", 1)
    return (w[0].lower() + (" " + w[1] if len(w) > 1 else "")) if w[0].lower() in COMMON_START else s


def two_passage(a, pool):
    """Two lead sentences (the first claim sentence of each atom, which usually names its own subject)
    from two atoms of the same source (so the same language and register), joined into one claim."""
    # Made for one eval atom in four (chosen by a hash of the id), so this pattern, which almost
    # every atom allows, does not swamp the others.
    if int(hashlib.sha256(f"{EVAL3_VERSION}:two_passage_gate:{a['id']}".encode()).hexdigest()[:8], 16) % 4:
        return None
    rng = atom_rng(a["id"], "two_passage")
    mine = _quotable(a)
    if not mine or not mine[0].endswith(".") or len(mine[0].split()) < 8:
        return None
    s1 = mine[0]
    partners = [o for o in pool if o["id"] != a["id"] and o.get("source") == a.get("source")]
    rng.shuffle(partners)
    for b in partners:
        theirs = _quotable(b)
        if not theirs or len(theirs[0].split()) < 8 or theirs[0] in _text(a) or s1 in _text(b):
            continue
        s2 = theirs[0]
        claim = s1[:-1] + ", and " + _lower_first(s2)
        ps = [passage(a), passage(b)] + [passage(o) for o in _distractors(rng, pool, {a["id"], b["id"]}, 1)]
        ev = [{"passage": a["id"][:8], "quote": s1}, {"passage": b["id"][:8], "quote": s2}]
        return _line(claim, ps, "supported", ev, "Each half of the claim is stated by a different passage, and both are needed.", a["id"], "two_passage", rng)
    return None


def paraphrase_decade(a, pool):
    rng = atom_rng(a["id"], "paraphrase_decade")
    sents = _quotable(a)
    rng.shuffle(sents)
    pt = passage(a)["text"]
    for s in sents:
        m = DECADE_RE.search(s)
        if not m:
            continue
        decade = m.group(1)[:3] + "0s"
        claim = s[:m.start()] + f"in the {decade}" + s[m.end():]
        if claim in pt:
            continue
        ps = [passage(a)] + [passage(o) for o in _distractors(rng, pool, {a["id"]}, 2)]
        return _line(claim, ps, "supported", [{"passage": a["id"][:8], "quote": s}],
                     f"The passage gives the year {m.group(1)}, which falls in the {decade}.", a["id"], "paraphrase_decade", rng)
    return None


GENERATORS = (near_miss_names, relation_flip, before_after, modal_shift, two_passage, paraphrase_decade)


def eval_pool(atoms, eval_share):
    """The frozen eval atoms with at least one usable sentence, in id order (so input order never matters)."""
    seen, pool = set(), []
    for a in sorted(atoms, key=lambda a: a["id"]):
        if a["id"] in seen or stable_split(a["id"], eval_share) != "eval" or not sentences(_text(a)):
            continue
        seen.add(a["id"])
        pool.append(a)
    return pool


def build_eval3(atoms, eval_share):
    """The eval3 lines for an export: every pattern the rules allow for every eval atom, ordered by a
    hash of (version, atom id, pattern), so the order is fixed without a run-time generator."""
    pool = eval_pool(atoms, eval_share)
    out = []
    for a in pool:
        for gen in GENERATORS:
            ex = gen(a, pool)
            if ex:
                out.append(ex)
    out.sort(key=lambda ex: hashlib.sha256(f"{EVAL3_VERSION}:{ex['atom_id']}:{ex['kind']}".encode()).hexdigest())
    return out


def dumps(lines):
    """The exact bytes eval3.jsonl holds (one JSON object per line, as build_dataset writes every split)."""
    return "".join(json.dumps(ex, ensure_ascii=False) + "\n" for ex in lines)


def manifest(lines, eval_share, source):
    return {"version": EVAL3_VERSION, "generator": "zeus/eval3.py", "split_rule": SPLIT_RULE, "eval_share": eval_share,
            "from": source, "atoms": len({ex["atom_id"] for ex in lines}), "lines": len(lines),
            "by_pattern": {k: sum(1 for ex in lines if ex["kind"] == k) for k in PATTERNS},
            "by_label": {l: sum(1 for ex in lines if ex["label"] == l) for l in ("supported", "contradicted", "not_covered")},
            "sha256": hashlib.sha256(dumps(lines).encode("utf-8")).hexdigest(),
            "note": "frozen; never trained on; a change to the generator bumps the version"}

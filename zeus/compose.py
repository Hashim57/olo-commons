"""Composed train examples (generator "compose-v1"). Train split only.

Why: on the frozen eval3 split, v16 scored 0.0 on two_passage (59 claims whose halves come from two
different passages, all supported) and 0.18 on paraphrase_decade (a year restated as its decade). It
answered not_covered or contradicted to almost all of them. The train split had taught that a
supported claim is one sentence quoted from one passage: every rule-made supported example (and
every hard-v1 twin) is exactly that. Only the gold set (a few dozen lines) had compound claims.

What this module adds, over train atoms only, with train distractors only:

  compose_supported      supported     a sentence from atom A and a sentence from atom B in one claim,
                                       with A and B both among the passages; evidence quotes both
  compose_missing_half   not_covered   the same kind of claim, but B is not among the passages: half
                                       of it is stated, half is not, so the whole is not covered
  compose_false_half     contradicted  the same kind of claim with B's half edited by a hard-v1
                                       contradiction rule, B among the passages; evidence quotes B
  century_supported      supported     "in 1863" restated as "in the 19th century", which the year entails
  century_wrong          contradicted  the same sentence with the century one off ("in the 18th century")
  decade_supported       supported     "in 1863" restated as the part of its decade it falls in ("early in the
                                       1860s", "during the early 1860s", "in the mid-1860s" for 1865), which
                                       the year entails (compose-v2)
  decade_wrong           contradicted  the same sentence moved to the wrong part of the decade ("late in the
                                       1860s") or to the decade before or after ("in the early 1870s")

The three composed kinds come as a contrastive set over the same two sentences, so "the claim is
long and joins two facts" never predicts the label by itself; the century and decade pairs likewise.

Kept apart from eval3 on purpose. eval3 joins two lead sentences with ", and " and restates "in 1863"
as "in the 1860s", the bare decade; this module never uses ", and " as the joint (it uses "; ",
", while ", " Also, ", " In addition, ") and never writes the bare decade: compose-v1 restated years
as centuries only, and a gain on eval3 was to measure transfer of the skill. It did not transfer:
paraphrase_decade on eval3 went 0.18 (v16), 0.6 (v18), 0.438 (v20), 0.25 (v22), the one pattern
still far from the ceiling while the gold set has carried a dozen decade paraphrases since 9
November. compose-v2 teaches the decade directly, but always as a third of it ("early", "mid",
"late") with the phrasing drawn from several templates, so eval3's "in the 1860s" is still a form
the model has never seen in a rule-made example; from v23 on, eval3 paraphrase_decade measures a
taught skill under a new template, not transfer, and STATUS.md says so. The module never reads eval
atoms, and it draws from its own generators (seeded by the atom id and the version), so eval.jsonl,
eval2.jsonl, eval3.jsonl and the order of the earlier train examples are unchanged; --no-compose
reproduces the train split without it. Bump COMPOSE_VERSION when a rule changes (compose-v2 reseeds
the earlier kinds too, so v23 draws different two-passage and century pairs than v22 did).
"""
import hashlib
import random
import re

from build_dataset import _english, passage, sentences, stable_split

COMPOSE_VERSION = "compose-v2"
JOINTS = ("; ", ", while ", " Also, ", " In addition, ")
YEAR_RE = re.compile(r"\bin (1[0-9]\d\d|20[0-9]\d)\b(?!\s*[-\u2013\u2014/]\s*\d)")
# words that may start the second half in lower case (anything else, likely a name, keeps its capital)
LOWER_OK = {"the", "a", "an", "it", "its", "this", "these", "those", "there", "in", "on", "at", "after", "before",
            "during", "since", "from", "as", "by", "for", "with", "according", "between", "when", "while", "he", "she", "they"}
ONE_IN = 5  # one train atom in ONE_IN starts a composed set, so the new kinds stay a small share of train


def _rng(atom_id, what):
    return random.Random(f"{COMPOSE_VERSION}:{what}:{atom_id}")


def _gate(atom_id, what, n):
    return int(hashlib.sha256(f"{COMPOSE_VERSION}:{what}:{atom_id}".encode()).hexdigest()[:8], 16) % n == 0


def _text(a):
    return a.get("summary") or a.get("content") or ""


def _usable(a):
    """Complete sentences of the atom that are exact substrings of its passage, long enough to state a fact."""
    pt = passage(a)["text"]
    return [s for s in sentences(_text(a)) if s in pt and s.endswith(".") and 8 <= len(s.split()) <= 40]


def ordinal(n):
    return f"{n}{'th' if 10 <= n % 100 <= 20 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')}"


def century_of(year):
    """The century a year falls in, counting 1801 to 1900 as the 19th. None for a year ending in 00,
    which readers place in either century, so no claim is made from it."""
    return None if year % 100 == 0 else year // 100 + 1


def join(s1, s2, joint):
    """One claim from two sentences. "; " and ", while " join them into one sentence (s1 loses its
    full stop); " Also, " and " In addition, " start a second sentence after s1."""
    if joint in ("; ", ", while "):
        return s1[:-1] + joint + _lower(s2)
    return s1 + joint + _lower(s2)


def _lower(s):
    w = s.split(" ", 1)
    return (w[0].lower() + (" " + w[1] if len(w) > 1 else "")) if w[0].lower() in LOWER_OK else s


def composed_set(a, b, others, rng, contra):
    """Up to three examples over sentence s1 of a and s2 of b: supported, not_covered (b missing) and,
    when a hard-v1 rule can edit s2 cleanly, contradicted. `contra(s, texts, rng)` returns (new, what) or None."""
    s1s, s2s = _usable(a), _usable(b)
    if not s1s or not s2s or len(others) < 2:
        return []
    s1, s2 = rng.choice(s1s), rng.choice(s2s)
    pa, pb = passage(a), passage(b)
    if s1 in pb["text"] or s2 in pa["text"]:
        return []
    # The English joints only between two English sentences; "; " reads in any language.
    joint = rng.choice(JOINTS) if _english(s1) and _english(s2) else "; "
    claim = join(s1, s2, joint)
    base = {"atom_id": a["id"], "generator": COMPOSE_VERSION, "pair": f"{a['id']}:{b['id']}:{COMPOSE_VERSION}"}
    with_b = [pa, pb, passage(others[0])]
    rng.shuffle(with_b)
    out = [dict(base, claim=claim, passages=with_b, label="supported",
                evidence=[{"passage": pa["id"], "quote": s1}, {"passage": pb["id"], "quote": s2}],
                rationale="Each part of the claim is stated by a different passage, and both are needed.", kind="compose_supported")]
    without_b = [pa, passage(others[0]), passage(others[1])]
    rng.shuffle(without_b)
    out.append(dict(base, claim=claim, passages=without_b, label="not_covered", evidence=[],
                    rationale="One passage states the first part of the claim; no passage states the second.", kind="compose_missing_half"))
    got = contra(s2, [p["text"] for p in with_b], rng)
    if got:
        new, what = got
        out.append(dict(base, claim=join(s1, new, joint), passages=with_b, label="contradicted",
                        evidence=[{"passage": pb["id"], "quote": s2}],
                        rationale=f"The first part is stated, but the second part is contradicted by the passage ({what}).",
                        kind="compose_false_half", edit=what))
    return out


def century_pair(a, others, rng):
    """A sentence with "in YYYY" restated as its century (supported) and as the century before or after (contradicted)."""
    sents = [s for s in _usable(a) if YEAR_RE.search(s)]
    if not sents or not others:
        return []
    s = rng.choice(sents)
    m = YEAR_RE.search(s)
    year = int(m.group(1))
    c = century_of(year)
    if c is None:
        return []
    wrong = c - 1 if c >= 21 else c + rng.choice((-1, 1))  # never a century that has not begun
    good = s[:m.start()] + f"in the {ordinal(c)} century" + s[m.end():]
    bad = s[:m.start()] + f"in the {ordinal(wrong)} century" + s[m.end():]
    own = passage(a)
    ps = [own] + [passage(o) for o in others[:2]]
    rng.shuffle(ps)
    base = {"atom_id": a["id"], "generator": COMPOSE_VERSION, "passages": ps, "pair": f"{a['id']}:century:{COMPOSE_VERSION}"}
    return [dict(base, claim=good, label="supported", evidence=[{"passage": own["id"], "quote": s}],
                 rationale=f"The passage gives the year {year}, which falls in the {ordinal(c)} century.", kind="century_supported"),
            dict(base, claim=bad, label="contradicted", evidence=[{"passage": own["id"], "quote": s}],
                 rationale=f"The passage gives the year {year}, which falls in the {ordinal(c)} century, not the {ordinal(wrong)}.",
                 kind="century_wrong", edit=f"{year} -> {ordinal(wrong)} century")]


# The three parts of a decade, by the last digit of the year, and the three ways a claim may say each
# (chosen by one index, so the supported and the contradicted claim of a pair use the same wording):
# the bare decade ("in the 1860s", eval3's form) is never among them.
DECADE_PARTS = ((0, 3, "early"), (4, 6, "mid"), (7, 9, "late"))
DECADE_PHRASES = {
    "early": ("in the early {decade}", "early in the {decade}", "during the early {decade}"),
    "mid": ("in the mid-{decade}", "in the middle of the {decade}", "during the mid-{decade}"),
    "late": ("in the late {decade}", "late in the {decade}", "during the late {decade}"),
}


def decade_part(year):
    """"early", "mid" or "late" for the third of its decade a year falls in: 1860 to 1863 early, 1864 to 1866 mid, 1867 to 1869 late."""
    d = year % 10
    return next(name for lo, hi, name in DECADE_PARTS if lo <= d <= hi)


def decade_name(year, part):
    """The part of a decade as a noun phrase, for a rationale: "early 1860s", "mid-1860s", "late 1860s"."""
    decade = f"{year // 10 * 10}s"
    return f"mid-{decade}" if part == "mid" else f"{part} {decade}"


def decade_phrase(year, part, template):
    """"in 1863" as a part of its decade, in wording number `template` (0 to 2): decade_phrase(1863, "early", 0) is
    "in the early 1860s", decade_phrase(1865, "mid", 1) is "in the middle of the 1860s"."""
    return DECADE_PHRASES[part][template].format(decade=f"{year // 10 * 10}s")


def decade_pair(a, others, rng, now_decade=2020):
    """A sentence with "in YYYY" restated as the part of its decade the year falls in (supported) and as the
    wrong part of the decade or the wrong decade (contradicted). The decade after now_decade is never claimed."""
    sents = [s for s in _usable(a) if YEAR_RE.search(s)]
    if not sents or not others:
        return []
    s = rng.choice(sents)
    m = YEAR_RE.search(s)
    year = int(m.group(1))
    part = decade_part(year)
    template = rng.randrange(3)
    good = s[:m.start()] + decade_phrase(year, part, template) + s[m.end():]
    if rng.random() < 0.5:
        wrong_part = rng.choice([name for _, _, name in DECADE_PARTS if name != part])
        bad = s[:m.start()] + decade_phrase(year, wrong_part, template) + s[m.end():]
        what = f"{year} -> {decade_name(year, wrong_part)}"
        why = f"The passage gives the year {year}, which is the {decade_name(year, part)}, not the {decade_name(year, wrong_part)}."
    else:
        step = -10 if year // 10 * 10 >= now_decade else rng.choice((-10, 10))  # never a decade that has not begun
        wrong_year = year + step
        bad = s[:m.start()] + decade_phrase(wrong_year, part, template) + s[m.end():]
        what = f"{year} -> {decade_name(wrong_year, part)}"
        why = f"The passage gives the year {year}, which falls in the {year // 10 * 10}s, not the {wrong_year // 10 * 10}s."
    own = passage(a)
    ps = [own] + [passage(o) for o in others[:2]]
    rng.shuffle(ps)
    base = {"atom_id": a["id"], "generator": COMPOSE_VERSION, "passages": ps, "pair": f"{a['id']}:decade:{COMPOSE_VERSION}"}
    return [dict(base, claim=good, label="supported", evidence=[{"passage": own["id"], "quote": s}],
                 rationale=f"The passage gives the year {year}, which is the {decade_name(year, part)}.", kind="decade_supported"),
            dict(base, claim=bad, label="contradicted", evidence=[{"passage": own["id"], "quote": s}],
                 rationale=why, kind="decade_wrong", edit=what)]


def add_composed(train, atoms, eval_share, contra, seed=7):
    """Insert the compose-v1 examples into train (in place) and return them. Train atoms only.
    Partners for a composed claim come from the same source (same language and register)."""
    seen, pool = set(), []
    for a in sorted(atoms, key=lambda x: x["id"]):
        if a["id"] in seen or stable_split(a["id"], eval_share) != "train" or not _usable(a):
            continue
        seen.add(a["id"])
        pool.append(a)
    by_source = {}
    for a in pool:
        by_source.setdefault(a.get("source") or "", []).append(a)
    made = []
    for a in pool:
        if _gate(a["id"], "compose", ONE_IN):
            rng = _rng(a["id"], "compose")
            mates = [o for o in by_source[a.get("source") or ""] if o["id"] != a["id"]]
            if mates:
                b = rng.choice(mates)
                others = rng.sample([o for o in pool if o["id"] not in (a["id"], b["id"])], k=min(2, len(pool) - 2))
                made.extend(composed_set(a, b, others, rng, contra))
        if _gate(a["id"], "century", 2):
            rng = _rng(a["id"], "century")
            others = rng.sample([o for o in pool if o["id"] != a["id"]], k=min(2, len(pool) - 1))
            made.extend(century_pair(a, others, rng))
        if _gate(a["id"], "decade", 2):
            rng = _rng(a["id"], "decade")
            others = rng.sample([o for o in pool if o["id"] != a["id"]], k=min(2, len(pool) - 1))
            made.extend(decade_pair(a, others, rng))
    ins = random.Random(f"{seed}:{COMPOSE_VERSION}:insert")
    for ex in made:
        train.insert(ins.randrange(len(train) + 1), ex)
    return made

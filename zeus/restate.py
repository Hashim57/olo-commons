"""Restated supported claims (generator "restate-v1"). Train split only.

Why: in the answer eval of 26 November 2026 (70 questions, v22 serving) about 17 of the 22 sentences Zeus
hid were stated by their passage in other words: "36.19 seconds" where the passage has "36.19", "eight RCTs"
against "Eight RCTs", a date or a number written another way, a bracketed aside left out. A plain rule-made
supported row is a sentence copied from its passage, so the model can learn "supported means I can find the
claim word for word" and call a restatement not covered. The mistake pool agrees: of the 338 rows v32 and v33
got wrong, 88 are supported claims answered not covered.

What this module adds: for a share of the plain rule-made supported rows (claim copied from a passage, its
evidence the same words), one more supported row whose claim says the same thing written differently, by
exactly one of these rewrites:

  restate_date       "July 2, 1991" <-> "2 July 1991"
  restate_percent    "38 percent" / "38 per cent" <-> "38%"
  restate_thousands  "84,000" -> "84000"
  restate_ordinal    "the fifth" -> "the 5th" (third to tenth; "first" and "second" are left alone, "second"
                     being also a unit of time)
  restate_count      "eight trials" -> "8 trials" (two to twelve, before a plural noun)
  restate_aside      a bracketed aside of at most 60 characters left out ("(born 1948)"); the claim says less
                     than the passage, never more, so it is still supported

Passages, evidence and label are those of the source row: the evidence still quotes the passage's own words,
which now differ from the claim's. Each rewrite only changes how a fact is written, never which fact, so a
row is never label noise; a rewrite that leaves the claim unchanged, or that the passage already contains
word for word, is not used. The source row stays in the set, so the pair teaches "same fact, either way".
Train atoms only (the rows come from the train split); eval, eval2 and eval3 are unchanged, and
--no-restate reproduces the train split without it. Bump RESTATE_VERSION when a rule changes.
"""
import random
import re

RESTATE_VERSION = "restate-v1"
MAX_ROWS = 1500
MAX_ASIDE = 200   # the aside rule applies to most Wikidata one-liners ("(born 1964)"); capped so the kinds stay mixed

MONTHS = "January|February|March|April|May|June|July|August|September|October|November|December"
ORDINALS = {"third": "3rd", "fourth": "4th", "fifth": "5th", "sixth": "6th", "seventh": "7th", "eighth": "8th", "ninth": "9th", "tenth": "10th"}
COUNTS = {"two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"}

_MDY = re.compile(rf"\b({MONTHS}) (\d{{1,2}}), (\d{{4}})\b")
_DMY = re.compile(rf"\b(\d{{1,2}}) ({MONTHS}) (\d{{4}})\b")
_PCT_WORD = re.compile(r"\b(\d+(?:\.\d+)?) ?(?:per cent|percent)\b")
_PCT_SIGN = re.compile(r"\b(\d+(?:\.\d+)?)%")
_THOUSANDS = re.compile(r"(?<![\d,.])(\d{1,3}),(\d{3})(?![\d,])")
_ORD = re.compile(r"\bthe (" + "|".join(ORDINALS) + r")\b", re.I)
_COUNT = re.compile(r"\b(" + "|".join(COUNTS) + r") ([a-z]+s)\b", re.I)
# words ending in s that are not plural nouns, so "one of the two was chosen" is not rewritten
NOT_PLURAL = {"was", "is", "has", "does", "this", "thus", "its", "his", "hers", "ours", "yours", "theirs", "us", "as", "yes", "plus", "always", "perhaps", "whereas", "unless", "across", "less", "various", "previous", "famous", "towards", "afterwards", "besides", "sometimes", "nevertheless"}
_ASIDE = re.compile(r" \(([^()]{1,60})\)")


def _date(c):
    if _MDY.search(c):
        return _MDY.sub(lambda m: f"{int(m.group(2))} {m.group(1)} {m.group(3)}", c, count=1)
    if _DMY.search(c):
        return _DMY.sub(lambda m: f"{m.group(2)} {int(m.group(1))}, {m.group(3)}", c, count=1)
    return None


def _percent(c):
    if _PCT_WORD.search(c):
        return _PCT_WORD.sub(lambda m: f"{m.group(1)}%", c, count=1)
    if _PCT_SIGN.search(c):
        return _PCT_SIGN.sub(lambda m: f"{m.group(1)} percent", c, count=1)
    return None


def _thousands(c):
    return _THOUSANDS.sub(lambda m: m.group(1) + m.group(2), c, count=1) if _THOUSANDS.search(c) else None


def _ordinal(c):
    m = _ORD.search(c)
    if not m:
        return None
    word = m.group(1)
    return c[:m.start(1)] + ORDINALS[word.lower()] + c[m.end(1):]


def _count(c):
    m = next((m for m in _COUNT.finditer(c) if m.group(2).lower() not in NOT_PLURAL and not m.group(2).lower().endswith(("ss", "us", "ous"))), None)
    if not m:
        return None
    return c[:m.start(1)] + COUNTS[m.group(1).lower()] + c[m.end(1):]


def _aside(c):
    m = _ASIDE.search(c)
    if not m:
        return None
    out = c[:m.start()] + c[m.end():]
    return out if len(out) >= 30 else None


RULES = [("restate_date", _date), ("restate_percent", _percent), ("restate_thousands", _thousands),
         ("restate_ordinal", _ordinal), ("restate_count", _count), ("restate_aside", _aside)]


def restatements(claim):
    """Every (kind, rewritten claim) the rules give for one claim; a rule that changes nothing gives nothing."""
    out = []
    for kind, fn in RULES:
        new = fn(claim)
        if new and new != claim:
            out.append((kind, new))
    return out


def _plain_supported(ex):
    """A plain rule-made supported row: no generator, one quote that is the claim itself, copied from a passage."""
    if ex.get("label") != "supported" or ex.get("generator") or len(ex.get("evidence") or []) != 1:
        return False
    q = ex["evidence"][0].get("quote", "")
    return q == ex.get("claim") and any(q in p.get("text", "") for p in ex.get("passages") or [])


def add_restated(train, seed=0, max_rows=MAX_ROWS):
    """Append restate-v1 rows to train (in place) and return them. One rewrite per source row, the kind chosen
    with an rng seeded by `seed` among the rules that apply (the aside rule only when no other applies, and at most
    MAX_ASIDE times), so kinds stay mixed; at most max_rows rows."""
    rng = random.Random(f"{RESTATE_VERSION}:{seed}")
    added = []
    for ex in list(train):
        if len(added) >= max_rows:
            break
        if not _plain_supported(ex):
            continue
        options = [(k, c) for k, c in restatements(ex["claim"]) if not any(c in p.get("text", "") for p in ex["passages"])]
        asides = sum(1 for r in added if r["kind"] == "restate_aside")
        if len(options) > 1 or asides >= MAX_ASIDE:
            options = [o for o in options if o[0] != "restate_aside"]   # prefer a rewrite that changes how a fact is written
        if not options:
            continue
        kind, claim = rng.choice(options)
        added.append({**{k: v for k, v in ex.items() if k not in ("claim", "rationale", "kind")},
                      "claim": claim, "kind": kind, "generator": RESTATE_VERSION,
                      "rationale": "The passage states the same fact, written differently."})
    train.extend(added)
    return added

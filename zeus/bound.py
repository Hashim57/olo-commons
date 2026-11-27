"""Bounded-number claims (generator "bound-v1"). Train split only.

Why: on held-out VitaminC dev, the human-written test Zeus is promoted on, v34 called 47 of 100
contradicted claims "not covered", and every version since v23 has called 35 to 52 of them so; v22 called
19. Most of those claims put a bound on a number the passage gives exactly: "There are more than 570
confirmed cases" against "the number of laboratory-confirmed cases stands at 561", "After more than 89
league games" against "After 89 league games", "before he was 15 years old" against "when he was only
eighteen". The passage decides each one by a comparison, and nothing rule-made in the train split has
ever asked for that comparison: a rule-made contradiction changes the passage's number to another
number, so the model can learn "the claim's number is not in the passage" as the sign of a
contradiction, and a bound ("more than 570") whose number is nowhere in the passage then reads as
"not covered". The same reading costs supported claims (27 of 100 VitaminC supported claims answered
not covered in v34) and the RAGTruth items of LLM-AggreFact (171 of 333 answered not covered).

What this module adds: for a share of the plain rule-made supported rows (claim copied from a passage),
a pair of rows whose claim puts a bound on one exact number of the sentence, the same wording in both,
one bound the number meets and one it does not:

  bound_supported     supported     "561 cases" -> "more than 500 cases" or "fewer than 600 cases"
  bound_wrong         contradicted  "561 cases" -> "more than 600 cases" or "fewer than 500 cases"

Both quote the passage sentence as evidence and say the comparison in the rationale ("The passage
gives 561, which is more than 500."). The label never depends on the bound's wording or on whether its
number appears in the passage, only on the comparison, so the pair teaches exactly that.

What is never rewritten, so a row is never label noise: a number the passage itself hedges or bounds
("about 500", "over 500", "up to 500", "500 or more", "between 400 and 500", a range "400-500"); a
year (1000 to 2100 written without a comma); a number before a currency symbol; a number that is part
of a name ("Apollo 11 missions" is excluded because the number must follow a lower-case word, a comma,
a bracket or the start of the sentence, never a capitalised word); a number that appears twice in the
sentence; a number after a determiner that would make the bound ungrammatical ("the 3 teams"); and any
sentence with a negation or a hedge ("not", "never", "may", "estimated", "expected"), whose meaning a
bound could flip. Passages, evidence and the source row are unchanged. Train atoms only (the rows come
from the train split); eval, eval2 and eval3 are unchanged, and --no-bound reproduces the train split
without it. Bump BOUND_VERSION when a rule changes.
"""
import math
import random
import re

from build_dataset import passage, stable_split

BOUND_VERSION = "bound-v1"
MAX_PAIRS = 600          # at most 1,200 rows, so a focused pass still fits the hour (recipe.py FOCUS_CAPS)

# a number (with optional thousands commas or a decimal part), then a plural word or a percent sign
_NUM_NOUN = re.compile(r"(?<![\w.,$£€#/+-])(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?) ([a-z]+s)\b")
_NUM_PCT = re.compile(r"(?<![\w.,$£€#/+-])(\d+(?:\.\d+)?)(%| percent\b| per cent\b)")
# the word before the number: these already bound or hedge it, or would make a bound ungrammatical
BEFORE_NO = {"about", "around", "approximately", "roughly", "nearly", "almost", "some", "over", "under", "than",
             "least", "most", "up", "to", "between", "and", "or", "within", "only", "just", "exactly", "precisely",
             "the", "these", "those", "its", "his", "her", "their", "our", "my", "your", "all", "top", "first",
             "last", "next", "every", "each", "another", "other", "no", "from", "by", "per", "x", "times",
             "number", "no.", "nos.", "page", "pages", "chapter", "section", "route", "highway", "season", "episode",
             "volume", "vol.", "level", "grade", "class", "type", "version", "series", "model", "size", "a", "an",
             "plus", "minus", "less", "more", "fewer", "below", "above", "beyond", "past", "excess", "upwards",
             "final", "remaining", "previous", "following", "record", "same", "initial", "original", "further", "extra"}
AFTER_NO = re.compile(r"^\s*(?:or more|or fewer|or less|or so|and over|and up|plus|\+|-|\u2013|\u2014|to \d|or \d|and \d|x\b|times\b)", re.I)
# sentences whose meaning a bound could flip, or whose numbers are not stated as fact
SENTENCE_NO = re.compile(r"\b(?:not|no|never|none|neither|nor|without|may|might|could|would|should|estimated|estimate|"
                         r"expected|projected|planned|proposed|predicted|forecast|approximately|about|around|roughly|"
                         r"nearly|almost|up to|at least|at most|more than|fewer than|less than|over|under|between|"
                         r"median|ranked|rank|ranking|aged|age|ages|born|died|old|excess|exceed|exceeds|exceeded|exceeding|"
                         r"confidence|credible|CI|significance|significant|p)\b", re.I)
# plural words that are not counted things, or where a bound reads wrongly
NOUN_NO = {"was", "is", "has", "does", "this", "thus", "its", "his", "hers", "ours", "yours", "theirs", "us", "as",
           "yes", "plus", "always", "perhaps", "whereas", "unless", "across", "less", "various", "previous", "famous",
           "towards", "afterwards", "besides", "sometimes", "nevertheless", "series", "species", "means", "news",
           "isotopes", "times", "ones", "others", "pounds", "dollars", "euros", "pence", "cents", "yens", "rupees",
           "decibels", "degrees", "hours", "minutes", "seconds", "bits", "bytes", "versions", "editions", "draws",
           "losses", "wins", "ties", "odds", "ends", "ranks", "places", "positions", "chapters", "stories", "floors"}
_WORD_BEFORE = re.compile(r"([A-Za-z.]+)\s*$")


EN_WORDS = {"the", "of", "and", "in", "a", "an", "to", "was", "is", "were", "are", "has", "had", "have", "for", "with",
            "by", "from", "at", "on", "that", "this", "its", "his", "her", "their", "during", "after", "before"}
NOT_EN_WORDS = {"de", "la", "el", "los", "las", "del", "y", "en", "un", "una", "le", "les", "des", "du", "et", "der", "die",
                "das", "und", "het", "een", "da", "do", "na", "em", "il", "di", "che", "och", "som", "og"}


def _is_english(s):
    """At least two common English words and none of the common words of the other languages the Commons holds."""
    words = set(re.findall(r"[a-z]+", s.lower()))
    return len(words & EN_WORDS) >= 2 and not (words & NOT_EN_WORDS)


def _value(s):
    return float(s.replace(",", ""))


def _fmt(v, like):
    """v written the way the original number was: thousands commas when it had them, no decimals."""
    n = int(v)
    return f"{n:,}" if "," in like else str(n)


def _step(n):
    """A round step for bounds near n: 1 below 20, then 5 or 10 to one digit less than n's."""
    if n < 20:
        return 1
    if n < 100:
        return 5
    return 10 ** (len(str(int(n))) - 2) * (5 if str(int(n))[0] in "1234" else 10)


def bounds(n, rng):
    """(low, high): round numbers with low < n < high, each a few steps away, both above zero."""
    st = _step(n)
    low = math.floor((n - st * rng.randint(1, 3)) / st) * st
    high = math.ceil((n + st * rng.randint(1, 3)) / st) * st
    if low >= n:
        low -= st
    if high <= n:
        high += st
    return (low if low > 0 else None), high


def _candidate(claim):
    """The (start, end, number text, unit text, is_percent) of the one number in the claim a bound can be put
    on, or None. Exactly one candidate, so the claim is never ambiguous about which number is bounded."""
    if SENTENCE_NO.search(claim) or not _is_english(claim):
        return None
    if re.search(r"\d[ .]\d{3}\b", claim):
        return None   # thousands written with a space or a dot ("2 555", "52.046"): the number is not what it seems
    found = []
    for m in _NUM_NOUN.finditer(claim):
        noun = m.group(2).lower()
        if noun in NOUN_NO or noun.endswith(("ss", "us", "ous")):
            continue
        found.append((m.start(1), m.end(1), m.group(1), noun, False, m.end()))
    for m in _NUM_PCT.finditer(claim):
        found.append((m.start(1), m.end(1), m.group(1), m.group(2), True, m.end()))
    if len(found) != 1:
        return None
    start, end, num, unit, pct, tail = found[0]
    v = _value(num)
    if v < 2 or (1000 <= v <= 2100 and "," not in num) or (pct and v >= 90):
        return None   # a share of 90% or more leaves no room for a round bound above it below 100%
    numbers = re.findall(r"\d[\d,]*(?:\.\d+)?", claim)
    if numbers.count(num) != 1:
        return None
    before = claim[:start]
    if before and not re.search(r"(?:^|[\s,;:])$", before):
        return None   # also never right after "(": a figure in brackets is usually a conversion of the one before
    w = _WORD_BEFORE.search(before)
    if w:
        word = w.group(1)
        if word.lower() in BEFORE_NO:
            return None
        if word[0].isupper() and len(before.split()) > 1:
            return None   # after a capitalised word that is not the sentence's first: likely a name ("Apollo 11 missions")
    if re.match(r"\s*\([^)]*\d", claim[tail:]):
        return None   # a conversion follows ("25 miles (40 km)"): bounding one figure would leave the other exact
    if AFTER_NO.search(claim[tail:]):
        return None
    return start, end, num, unit, pct


def bound_pair(claim, rng):
    """(supported claim, contradicted claim, rationale supported, rationale contradicted, number) for one claim,
    or None when no number in it can be bounded safely. Both claims use the same wording; only the bound moves."""
    c = _candidate(claim)
    if not c:
        return None
    start, end, num, unit, pct = c
    v = _value(num)
    low, high = bounds(v, rng)
    if pct and high >= 100:
        return None
    up_words = ("more than", "over")
    down_words = ("less than", "under") if pct else ("fewer than", "under", "less than")
    shown = num
    if low is not None and rng.random() < 0.5:
        word = rng.choice(up_words)
        good, bad = low, high          # more than low: true; more than high: false
        up = True
    else:
        word = rng.choice(down_words)
        if low is None:
            return None                # no positive bound below the number, so no false "fewer than"
        good, bad = high, low          # fewer than high: true; fewer than low: false
        up = False
    lead = word[0].upper() + word[1:] if start == 0 else word   # a bound that starts the sentence takes its capital
    sup = claim[:start] + f"{lead} {_fmt(good, num)}" + claim[end:]
    con = claim[:start] + f"{lead} {_fmt(bad, num)}" + claim[end:]
    if sup == claim or con == claim or sup == con:
        return None
    unit_txt = "%" if pct else ""
    gtxt, btxt = _fmt(good, num) + unit_txt, _fmt(bad, num) + unit_txt
    if up:
        r_sup = f"The passage gives {shown}{unit_txt}, which is more than {gtxt}."
        r_con = f"The passage gives {shown}{unit_txt}, which is not more than {btxt}."
    else:
        r_sup = f"The passage gives {shown}{unit_txt}, which is less than {gtxt}."
        r_con = f"The passage gives {shown}{unit_txt}, which is not less than {btxt}."
    return sup, con, r_sup, r_con, num


def make_pair(sentence, own, others, rng, extra=None):
    """The two rows (supported, contradicted) bounding one number of `sentence`, a sentence of passage `own`,
    shown with `others` as the other passages; or [] when no number in it can be bounded safely or a bounded
    claim is already in a passage word for word. `extra` fields (generator metadata) go on both rows."""
    got = bound_pair(sentence, rng)
    if not got:
        return []
    sup, con, r_sup, r_con, num = got
    ps = [own] + list(others)
    if any(sup in p.get("text", "") or con in p.get("text", "") for p in ps):
        return []
    rng.shuffle(ps)
    base = {**(extra or {}), "generator": BOUND_VERSION, "passages": ps, "evidence": [{"passage": own["id"], "quote": sentence}],
            "pair": f"{own['id']}:bound:{BOUND_VERSION}"}
    return [dict(base, claim=sup, label="supported", kind="bound_supported", rationale=r_sup),
            dict(base, claim=con, label="contradicted", kind="bound_wrong", rationale=r_con, edit=f"{num} -> bound")]


def add_bounded(train, atoms, eval_share, seed=7, max_pairs=MAX_PAIRS):
    """Insert bound-v1 pairs over train atoms into train (in place) and return them: for each train atom, the
    first of its complete sentences with a number that can be bounded, the atom's passage and two other train
    atoms' passages; at most max_pairs pairs. Train atoms only, so eval, eval2 and eval3 do not change."""
    import compose
    pool, seen = [], set()
    for a in sorted(atoms, key=lambda x: x["id"]):
        if a["id"] in seen or stable_split(a["id"], eval_share) != "train":
            continue
        seen.add(a["id"])
        pool.append(a)
    made = []
    for a in pool:
        if len(made) >= 2 * max_pairs:
            break
        rng = random.Random(f"{BOUND_VERSION}:{seed}:{a['id']}")
        own = passage(a)
        for s in compose._usable(a):
            if not _candidate(s):
                continue
            others = [passage(o) for o in rng.sample(pool, k=min(3, len(pool))) if o["id"] != a["id"]][:2]
            pair = make_pair(s, own, others, rng, {"atom_id": a["id"]})
            if pair:
                made.extend(pair)
                break
    ins = random.Random(f"{seed}:{BOUND_VERSION}:insert")
    for ex in made:
        train.insert(ins.randrange(len(train) + 1), ex)
    return made

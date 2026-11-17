"""Long-document train examples (generator "longdoc-v1"). Train split only.

Why: v23, the first version measured on LLM-AggreFact, scored 54.2 percent balanced accuracy, where always
giving the same answer scores 50. On four of its eleven datasets (XSum summaries, two TofuEval sets of
meeting and media summaries, Wice) it scored exactly 50.0: one answer for every claim. LLM-AggreFact gives
one document of up to 12,000 characters (a news article, a transcript, a RAG answer) and a claim that is
often a summary sentence. Every passage Zeus had ever trained on was cut at 900 characters (passage() in
build_dataset.py), so it had never had to find a fact inside a long text, and on one it falls back to a
default answer. No LLM-AggreFact text is used here: its test split stays a held-out measurement.

What this module adds, over train atoms only:

  long_supported         supported     one long document (several atoms of one source, joined), a claim that
                                       is a sentence of an atom placed in the middle of it; evidence quotes it
  long_contradicted      contradicted  the same sentence edited by a hard-v1 contradiction rule
  long_missing           not_covered   a sentence of an atom of the same source that is not in the document
  long_summary_supported supported     two sentences of two different atoms of the document joined as one
                                       summary-like claim; evidence quotes both
  long_summary_missing   not_covered   one sentence of the document joined with one from outside it: half
                                       stated, half not

The five kinds come as a contrastive set over the same document, so "the passage is long" never predicts
the label. One passage only, as LLM-AggreFact gives. Documents are at most DOC_CHARS characters, so prompt,
document and answer fit the trainer's 2,048 tokens. The module never reads eval atoms and draws from its
own generators (seeded by the atom id and the version), so eval, eval2, eval3 and the order of the earlier
train examples are unchanged; --no-longdoc reproduces the train split without it. Bump LONGDOC_VERSION when
a rule changes.
"""
import hashlib
import random

from build_dataset import stable_split
from compose import JOINTS, _english, _text, _usable, join

LONGDOC_VERSION = "longdoc-v1"
ONE_IN = 12          # one train atom in ONE_IN anchors a document, so long examples stay a small share of train
DOC_ATOMS = (5, 9)   # atoms per document, inclusive
DOC_CHARS = 6000     # longest document
ATOM_CHARS = 1400    # longest single atom inside a document


def _rng(atom_id, what):
    return random.Random(f"{LONGDOC_VERSION}:{what}:{atom_id}")


def _gate(atom_id, n):
    return int(hashlib.sha256(f"{LONGDOC_VERSION}:anchor:{atom_id}".encode()).hexdigest()[:8], 16) % n == 0


def _piece(a):
    """The atom's text as it appears in a document: its summary or content, cut at a sentence end before ATOM_CHARS."""
    t = " ".join(_text(a).split())
    if len(t) <= ATOM_CHARS:
        return t
    cut = t.rfind(". ", 0, ATOM_CHARS)
    return t[: cut + 1] if cut > 200 else t[:ATOM_CHARS]


def build_document(anchor, mates, rng):
    """(text, members): the anchor and some mates of the same source joined by blank lines, the anchor never
    first or last, at most DOC_CHARS. members are the atoms whose text is in the document, in order."""
    want = rng.randint(*DOC_ATOMS) - 1
    chosen = rng.sample(mates, k=min(want, len(mates)))
    if len(chosen) < 2:
        return None, []
    pos = rng.randint(1, len(chosen) - 1)
    order = chosen[:pos] + [anchor] + chosen[pos:]
    parts, members, size = [], [], 0
    for a in order:
        p = _piece(a)
        if not p:
            continue
        if size + len(p) + 2 > DOC_CHARS:
            if a is anchor:
                return None, []
            continue
        parts.append(p)
        members.append(a)
        size += len(p) + 2
    if anchor not in members or members[0] is anchor or len(members) < 3:
        return None, []
    return "\n\n".join(parts), members


def longdoc_set(anchor, mates, outsiders, rng, contra):
    """Up to five examples over one long document anchored on `anchor`. `contra(s, texts, rng)` is the hard-v1
    contradiction (build_dataset.compose_contra)."""
    text, members = build_document(anchor, mates, rng)
    if not text:
        return []
    s_list = [s for s in _usable(anchor) if s in text]
    if not s_list:
        return []
    s = rng.choice(s_list)
    doc = {"id": "d1", "source": anchor.get("source") or "", "url": anchor.get("url", ""), "text": text}
    base = {"atom_id": anchor["id"], "generator": LONGDOC_VERSION, "doc_atoms": [m["id"] for m in members]}
    out = [dict(base, claim=s, passages=[doc], label="supported", evidence=[{"passage": "d1", "quote": s}],
                rationale="The document states the claim in one of its paragraphs.", kind="long_supported")]
    got = contra(s, [text], rng)
    if got:
        new, what = got
        out.append(dict(base, claim=new, passages=[doc], label="contradicted", evidence=[{"passage": "d1", "quote": s}],
                        rationale=f"The document says otherwise in one of its paragraphs ({what}).", kind="long_contradicted", edit=what))
    outside = [x for o in outsiders for x in _usable(o) if x not in text]
    if outside:
        out.append(dict(base, claim=rng.choice(outside), passages=[doc], label="not_covered", evidence=[],
                        rationale="The document is on related matters but nowhere states this.", kind="long_missing"))
    other = [x for m in members if m is not anchor for x in _usable(m) if x in text and x != s]
    if other:
        s2 = rng.choice(other)
        joint = rng.choice(JOINTS) if _english(s) and _english(s2) else "; "
        out.append(dict(base, claim=join(s, s2, joint), passages=[doc], label="supported",
                        evidence=[{"passage": "d1", "quote": s}, {"passage": "d1", "quote": s2}],
                        rationale="Both parts of the claim are stated, in different paragraphs of the document.", kind="long_summary_supported"))
    if outside:
        x = rng.choice(outside)
        joint = rng.choice(JOINTS) if _english(s) and _english(x) else "; "
        out.append(dict(base, claim=join(s, x, joint), passages=[doc], label="not_covered", evidence=[],
                        rationale="The document states the first part of the claim but not the second.", kind="long_summary_missing"))
    return out


def add_longdoc(train, atoms, eval_share, contra, seed=7):
    """Insert the longdoc-v1 examples into train (in place) and return them. Train atoms only; a document's
    atoms come from one source (one language and register), the outside sentences from the same source."""
    seen, pool = set(), []
    for a in sorted(atoms, key=lambda x: x["id"]):
        if a["id"] in seen or stable_split(a["id"], eval_share) != "train" or not _text(a):
            continue
        seen.add(a["id"])
        pool.append(a)
    by_source = {}
    for a in pool:
        by_source.setdefault(a.get("source") or "", []).append(a)
    made = []
    for a in pool:
        if not _gate(a["id"], ONE_IN) or not _usable(a):
            continue
        rng = _rng(a["id"], "doc")
        mates = [o for o in by_source[a.get("source") or ""] if o["id"] != a["id"]]
        if len(mates) < DOC_ATOMS[0]:
            continue
        candidates = rng.sample(mates, k=min(40, len(mates)))
        made.extend(longdoc_set(a, candidates[:20], candidates[20:], rng, contra))
    ins = random.Random(f"{seed}:{LONGDOC_VERSION}:insert")
    for ex in made:
        train.insert(ins.randrange(len(train) + 1), ex)
    return made

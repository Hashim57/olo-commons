"""Atom quality rules shared with the ingester, so Zeus trains on the same Commons the ingester would keep.

Two rules, ported line for line from functions/olo-ingest/text.ts (isStub, with isLinkNotice) and
functions/olo-ingest/sources.ts (wikidataHousekeeping); tests/text_test.ts and
zeus/tests/test_quality.py hold the same examples so the two stay in step.

Why here as well: the Commons stored stubs before the ingester had the gate
(a third of the archive_org atoms on 2026-11-03: "new book new book", "Author:
X Author: X") and Wikidata categories and templates ("Category:Buildings in
Trapani: Wikimedia category"). Until sql/010 has removed them, and in any older
snapshot, build_dataset.py would turn 104 of them into claims and passages
("conway game bots murder conway game bots murder" as a supported claim).
usable_atoms() drops them, and drops an atom id seen twice (the keyless export
repeated the last atom of every page before export.ts kept the cursor's
microseconds), before any split is made.
"""
import re

WORD_RE = re.compile(r"[^\W\d_]{2,}")

STUB_MIN_DISTINCT = 6       # fewer different words than this is a label, not a description
STUB_REPEAT_DISTINCT = 12   # below this many different words, a text made mostly of repeats is a stub...
STUB_REPEAT_RATIO = 0.4     # ...when fewer than this share of its words are distinct
STUB_MIN_REST = 40          # characters the body must still have once the title and the authors are taken out
STUB_LINK_REST = 160        # characters a body holding a link, an email address or a domain must have once those are taken out

# Links, email addresses and bare domains, the parts of a body that point elsewhere (LINK_RE in text.ts).
LINK_RE = re.compile(r"https?://\S+|www\.\S+|[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|\b[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.(?:com|org|net|info|ir|io|co|edu|gov|me|tk|ru|de|uk)\b(?:/\S*)?")

NAMESPACE_RE = re.compile(r"^(Category|Template|Module|Wikipedia|Portal|Help|MediaWiki|File|Draft|Book|Wikidata|Property|Lexeme):", re.I)
PAGE_KIND_RE = re.compile(r"^Wikimedia (category|disambiguation page|list article|template|project page|internal item|module|navigational template|KML file|set index article|permanent duplicate item|human name disambiguation page)\b|^(taxonomy|navigational|infobox|stub|citation) template$", re.I)


def clean(s):
    return " ".join(str(s or "").split())


def words(s):
    return WORD_RE.findall(str(s or "").lower())


def is_link_notice(body):
    """True when a body is a pointer, not a description: it holds a link, an email address or a domain, and
    once those are taken out (and a text written twice is read once) fewer than STUB_LINK_REST characters are
    left ("for details please visit ketabpedia.com", stored 21 times under different archive_org items)."""
    b = clean(body)
    if not LINK_RE.search(b):
        return False
    rest = clean(LINK_RE.sub(" ", b))
    h = (len(rest) - 1) // 2
    if len(rest) > 20 and rest[h] == " " and rest[:h] == rest[h + 1:]:
        rest = rest[:h]
    return len(rest) < STUB_LINK_REST


def is_stub(title, summary, content, authors=None):
    """True when an atom carries no knowledge: a label, one line repeated, or nothing beyond its title and authors."""
    s, c = clean(summary), clean(content)
    body = c if len(c) >= len(s) else s
    if not body:
        return True
    w = words(body)
    distinct = len(set(w))
    if distinct < STUB_MIN_DISTINCT:
        return True
    if distinct < STUB_REPEAT_DISTINCT and distinct / len(w) < STUB_REPEAT_RATIO:
        return True
    if is_link_notice(body):
        return True
    rest = " " + body.lower() + " "
    for name in [title] + list(authors or []):
        n = clean(name).lower()
        if len(n) >= 3:
            rest = rest.replace(n, " ")
    return len(clean(rest)) < STUB_MIN_REST


def wikidata_housekeeping(label, desc):
    """True for a Wikidata item that describes a Wikimedia page (category, template, disambiguation page) and not a thing in the world."""
    return bool(NAMESPACE_RE.search(str(label or "")) or PAGE_KIND_RE.search(str(desc or "").strip()))


def wikidata_description(a):
    """The description part of a wikidata atom's summary, which the connector writes as "<label>: <description>."."""
    title, summary = str(a.get("title") or ""), str(a.get("summary") or "")
    desc = summary[len(title) + 2:] if summary.startswith(title + ": ") else summary
    return desc.rstrip(".").strip()


def usable_atoms(atoms):
    """The atoms a build should see: each id once, no stubs, no Wikidata housekeeping items.
    Returns (kept, counts) with counts = {"duplicate": n, "stub": n, "housekeeping": n}."""
    seen, kept = set(), []
    counts = {"duplicate": 0, "stub": 0, "housekeeping": 0}
    for a in atoms:
        aid = a.get("id")
        if aid in seen:
            counts["duplicate"] += 1
            continue
        seen.add(aid)
        if is_stub(a.get("title"), a.get("summary"), a.get("content"), a.get("authors")):
            counts["stub"] += 1
            continue
        if (a.get("source") or a.get("source_slug")) == "wikidata" and wikidata_housekeeping(a.get("title"), wikidata_description(a)):
            counts["housekeeping"] += 1
            continue
        kept.append(a)
    return kept, counts

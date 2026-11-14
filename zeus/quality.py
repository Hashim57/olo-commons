"""Atom quality rules shared with the ingester, so Zeus trains on the same Commons the ingester would keep.

Three rules, ported line for line from functions/olo-ingest/text.ts (isStub, with isLinkNotice, isRightsNotice,
isCatalogueRecord, isShelfMark and withoutPhysicalDescription) and
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

# An email address anywhere in a text (EMAIL_RE in text.ts).
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")

RIGHTS_MAX_WORDS = 60   # a body with more words than this says something beyond its legal standing

# The words of a sentence about an item's legal standing or the origin of its record, not about the item (RIGHTS_RE in text.ts).
RIGHTS_RE = re.compile(r"\b(?:public domain|copyright(?:ed)?|all rights reserved|no known (?:copyright )?restrictions|metadata|crossref|source url|full record)\b", re.I)

CATALOGUE_MIN_LABELS = 3            # a body with fewer "Label: value" fields than this is read as prose
CATALOGUE_MAX_WORDS_PER_LABEL = 5   # ...and one with more words than this per field is prose with headings (a structured abstract)

# "Label: " fields: a capitalised word, up to three more words, a colon and a space (LABEL_RE in text.ts).
LABEL_RE = re.compile(r"(?:^|\s)(?:[A-Z][\w'\u2019.-]*(?: (?:[a-z]+|[A-Z][\w'\u2019.-]*)){0,3}): (?=\S)")

SHELF_MIN_SEGMENTS = 5            # a body divided into fewer parts than this is read as prose
SHELF_MAX_WORDS_PER_SEGMENT = 4   # ...and one with a part longer than this holds a sentence, not a shelf mark

# Separators between the parts of a shelf mark or a path: a spaced dash of any length, a bar, a slash, a chevron or a double colon (SEGMENT_RE in text.ts).
SEGMENT_RE = re.compile(r"\s(?:[\u2013\u2014-]|\||/|>|\u00bb|::)\s")

# A library catalogue's physical description at the start of a body ("ix, 203 pages : 24 cm") and its standard notes (PHYSICAL_RE and CATALOGUE_NOTES_RE in text.ts).
PHYSICAL_RE = re.compile(r"^(?:[xivlc]+, )?(?:\d+ (?:p\.|pages?|v\.|volumes?|leaves)|volumes?|\d+ (?:volume|guide|portfolio) \((?:unpaged|\d+ p\.?)\))(?: of plates)?[^A-Za-z0-9]*(?:(?:ill\.?|illustrations|col\.|colou?r|maps?|ports?\.?|facsims?\.?|music|charts?|plates)[^A-Za-z0-9]*)*(?:\d+(?: x \d+)? cm\.?)?", re.I)
CATALOGUE_NOTES_RE = re.compile(r"\bIncludes? (?:bibliographical references?|bibliography|bibliographies|index(?:es)?|discography|filmography)(?: \((?:p\.|pages?)? ?[\d, -]+\))?(?: and index(?:es)?)?\.?|\bBibliography: (?:p\.|pages?) [\d, -]+\.?", re.I)

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


def oncely(s):
    """A text written twice in a row ("X X"), read once; anything else unchanged."""
    h = (len(s) - 1) // 2
    return s[:h] if len(s) > 40 and s[h] == " " and s[:h] == s[h + 1:] else s


def is_rights_notice(body):
    """True when a body is a rights notice, not a description: every sentence says where the item stands legally or
    where its record came from, at most RIGHTS_MAX_WORDS words in all ("This paper is in the public domain in USA.
    Metadata comes from the CrossRef API, see full record in the source URL below.", the fixed description of the
    Internet Archive's journal scans uploaded from CrossRef records; 2 archive_org atoms on the 2026-11-11 snapshot,
    no atom of any other source)."""
    b = oncely(clean(body))
    if not b or len(words(b)) > RIGHTS_MAX_WORDS:
        return False
    sentences = [x.strip() for x in re.split(r"[.!?]\s+", b) if x.strip()]
    return bool(sentences) and all(RIGHTS_RE.search(x) for x in sentences)


def is_catalogue_record(body):
    """True when a body is a catalogue record, not a description: at least CATALOGUE_MIN_LABELS "Label: value"
    fields with at most CATALOGUE_MAX_WORDS_PER_LABEL words per field. Delpher newspaper issues ("Title: Algemeen
    Handelsblad Datum: 22-05-1861 Editie: Dag Plaats van uitgave: Amsterdam ...") and Indian gazettes ("Gazette
    Type: Extraordinary Date: 2022-05-26 Department: ...") were 365 of the 999 archive_org atoms on the 2026-11-07
    snapshot; no atom of any other source matched (the closest, an abstract written as a list of citations, has
    6.6 words per label; a structured abstract has 19 or more)."""
    b = oncely(clean(body))
    labels = len(LABEL_RE.findall(b))
    if labels < CATALOGUE_MIN_LABELS:
        return False
    return len(words(b)) / labels <= CATALOGUE_MAX_WORDS_PER_LABEL


def is_shelf_mark(body):
    """True when a body is a shelf mark, not a description: at least SHELF_MIN_SEGMENTS parts joined by spaced dashes,
    bars or slashes, each of at most SHELF_MAX_WORDS_PER_SEGMENT words ("Karnataka State Archives - Mysore - Gazettes -
    Gazette-6 - HRS-Historical Record Section - R - 369 (ID 102517)", 76 archive_org atoms on the 2026-11-08 snapshot,
    no atom of any other source)."""
    segs = [s.strip() for s in SEGMENT_RE.split(oncely(clean(body))) if s.strip()]
    return len(segs) >= SHELF_MIN_SEGMENTS and all(len(words(s)) <= SHELF_MAX_WORDS_PER_SEGMENT for s in segs)


def without_physical_description(body):
    """A body with its library physical description and catalogue notes taken out ("ix, 203 pages : 24 cm Includes
    bibliographical references and index" becomes ""); a body with no physical description comes back unchanged."""
    m = PHYSICAL_RE.match(body)
    if not m or not m.group(0).strip():
        return body
    return clean(CATALOGUE_NOTES_RE.sub(" ", body[m.end():]))


STUB_RULES = ("empty", "label", "repeat", "link_notice", "catalogue_record", "shelf_mark", "rights_notice", "no_rest")


def stub_reason(title, summary, content, authors=None):
    """The name of the rule that makes an atom a stub, or None when it carries knowledge. The rules run in the
    ingester's order (isStub in text.ts), so the first that fires is named: "empty" (no body), "label" (fewer than
    STUB_MIN_DISTINCT different words), "repeat" (one line written over and over), "link_notice", "catalogue_record",
    "shelf_mark", "rights_notice", and "no_rest" (nothing beyond the title, the authors and a physical description)."""
    s, c = clean(summary), clean(content)
    body = c if len(c) >= len(s) else s
    if not body:
        return "empty"
    w = words(body)
    distinct = len(set(w))
    if distinct < STUB_MIN_DISTINCT:
        return "label"
    if distinct < STUB_REPEAT_DISTINCT and distinct / len(w) < STUB_REPEAT_RATIO:
        return "repeat"
    if is_link_notice(body):
        return "link_notice"
    if is_catalogue_record(body):
        return "catalogue_record"
    if is_shelf_mark(body):
        return "shelf_mark"
    if is_rights_notice(body):
        return "rights_notice"
    rest = " " + without_physical_description(body).lower() + " "
    for name in [title] + list(authors or []):
        n = clean(name).lower()
        if len(n) >= 3:
            rest = rest.replace(n, " ")
    return "no_rest" if len(clean(rest)) < STUB_MIN_REST else None


def has_email_address(*parts):
    """True when a title, summary or content carries an email address (hasEmailAddress in text.ts). The Commons stores
    no personal data, and an address in a description is an uploader's contact line or a take-down notice, never a fact
    about the item (35 atoms on the 2026-11-12 snapshot, 34 archive_org and 1 openalex). The "@" used as an alias mark
    in Indian court records does not match."""
    return any(EMAIL_RE.search(clean(p)) for p in parts)


COURT_RE = re.compile(r"\b(?:high court|supreme court|court of judicature|district court|sessions? court|court of appeals?|tribunal|chief judicial magistrate|court of [a-z]+(?: and [a-z]+)? at [a-z]+|(?:mr\.?|mrs\.?|smt\.?|sri|dr\.?|the hon[\u2019']?ble(?: mr\.?| mrs\.?| sri| dr\.?)?) justice)\b", re.I)
CASE_RE = re.compile(r"\b(?:writ petition|criminal (?:appeal|revision|misc)|civil (?:appeal|writ|revision|misc)|special appeal|revision petition|misc\.? petition|cr\.? ?misc\.?|crl\.? ?m(?:isc)?\.?|w\.? ?p\.? ?(?:no|nos)|(?:no|nos)\.?\s*:?\s*\d+(?:[-/]\w+)?\s*(?:/|of)\s*(?:19|20)?\d{2}(?:\d{2})?)\b", re.I)
PARTY_RE = re.compile(r"\b(?:versus|vs?\.)\s|\b(?:petitioner|respondent|appellant|applicant|accused|coram|between)s?\b|\bhon[\u2019']?ble\b|\blearned counsel\b|\b[swdr]/o\b", re.I)


def is_court_record(title, summary, content):
    """True when a text is a court record (isCourtRecord in text.ts): it names a court (in the title or the body), a
    case and the parties, all three. The Internet Archive mirrors the Indian High Court judgments corpus as scanned
    orders whose description is the OCR of the first page, naming private people as accused and petitioners with their
    parentage and village (78 atoms on the 2026-11-14 snapshot, 75 of them matched here, no atom of any other source).
    The Commons stores no personal data, so neither does a Zeus training set."""
    s, c = clean(summary), clean(content)
    body = c if len(c) >= len(s) else s
    if not body:
        return False
    return bool(COURT_RE.search(clean(title) + " " + body) and CASE_RE.search(body) and PARTY_RE.search(body))


def is_stub(title, summary, content, authors=None):
    """True when an atom carries no knowledge: a label, one line repeated, a notice that points elsewhere, a catalogue
    record, a shelf mark, a rights notice, or nothing beyond its title, authors and physical description (stub_reason names which)."""
    return stub_reason(title, summary, content, authors) is not None


def wikidata_housekeeping(label, desc):
    """True for a Wikidata item that describes a Wikimedia page (category, template, disambiguation page) and not a thing in the world."""
    return bool(NAMESPACE_RE.search(str(label or "")) or PAGE_KIND_RE.search(str(desc or "").strip()))


WIKIDATA_TAIL_RE = re.compile(r"\.? ?Described in \d+ Wikimedia projects\.?$")


def wikidata_description(a):
    """The description part of a wikidata atom. The connector writes the summary as "<label>: <description>." and the
    content as "<label>. <description>. Described in N Wikimedia projects."; the live export gives the summary, the
    snapshot gave both joined until 2026-11-09 and gives the content alone since (scripts/build_snapshot.py
    join_once). All three read the same here: the label and the "Described in" sentence are taken off."""
    title, summary = str(a.get("title") or ""), str(a.get("summary") or "")
    desc = summary
    for sep in (": ", ". "):
        if title and summary.startswith(title + sep):
            desc = summary[len(title) + len(sep):]
            break
    # the joined form repeats the label and the description after the first one: keep the first
    again = desc.find(". " + title + ". ") if title else -1
    if again >= 0:
        desc = desc[:again]
    return WIKIDATA_TAIL_RE.sub("", desc).rstrip(".").strip()


def usable_atoms(atoms):
    """The atoms a build should see: each id once, no stubs, no atom carrying an email address, no court record, no Wikidata housekeeping items.
    Returns (kept, counts) with counts = {"duplicate": n, "stub": n, "email": n, "court_record": n, "housekeeping": n, "stub_by_rule": {rule: n}},
    where stub_by_rule names the rule that refused each stub (STUB_RULES), so a build can say which rule did the work."""
    seen, kept = set(), []
    counts = {"duplicate": 0, "stub": 0, "email": 0, "court_record": 0, "housekeeping": 0, "stub_by_rule": {}}
    for a in atoms:
        aid = a.get("id")
        if aid in seen:
            counts["duplicate"] += 1
            continue
        seen.add(aid)
        reason = stub_reason(a.get("title"), a.get("summary"), a.get("content"), a.get("authors"))
        if reason:
            counts["stub"] += 1
            counts["stub_by_rule"][reason] = counts["stub_by_rule"].get(reason, 0) + 1
            continue
        if has_email_address(a.get("title"), a.get("summary"), a.get("content")):
            counts["email"] += 1
            continue
        if is_court_record(a.get("title"), a.get("summary"), a.get("content")):
            counts["court_record"] += 1
            continue
        if (a.get("source") or a.get("source_slug")) == "wikidata" and wikidata_housekeeping(a.get("title"), wikidata_description(a)):
            counts["housekeeping"] += 1
            continue
        kept.append(a)
    return kept, counts

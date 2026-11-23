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
FILE_MAX_WORDS_PER_TAG = 6   # a part between commas longer than this is a phrase, not a collection tag

# A quoted run of at least three characters standing on its own (QUOTED_RE in text.ts): opened at the start or after a
# space, a comma or a bracket, closed before the end or a space, a comma or a stop, so an apostrophe inside a word opens nothing.
QUOTED_RE = re.compile(r"(?:^|(?<=[\s,;:(]))(?:'[^']{3,}?'|\"[^\"]{3,}?\"|\u2018[^\u2019]{3,}?\u2019|\u201c[^\u201d]{3,}?\u201d)(?=$|[\s,;:.)])")
FILENAME_RE = re.compile(r"\bfile ?name\s*:", re.I)
SENTENCE_END_RE = re.compile(r"[.!?](?:\s|$)")

# An item record: a scanned object described as an object (DIMENSIONS_RE, WEIGHT_RE, COPYRIGHT_STATUS_RE, DEDICATION_RE and
# ETEXT_CREDIT_RE in text.ts). A measurement with a unit and the side it measures; the object's weight; the copyright status
# of an American item ("No copyright notice evident", "Rule 5 of the United States Copyright Statutes"); an uploader placing
# their own work in the public domain; the digitiser's credit ("Etext created by ...").
DIMENSIONS_RE = re.compile(r"\bdimensions?\b(?:[^.;]|\.\d){0,80}\b(?:width|height|length|diameter|thickness)\b|\d\s*(?:\"|''|\u201d|inch(?:es)?|in\.|millimet(?:er|re)s?|mm|cm)\s*(?:in\s+)?(?:width|height|length|diameter|thickness)\b", re.I)
WEIGHT_RE = re.compile(r"\b(?:weight|weighs|weighing)\b(?:[^.;]|\.\d){0,40}\b(?:grams?|g|ounces?|oz|kilograms?|kg|pounds?|lbs?)\b", re.I)
COPYRIGHT_STATUS_RE = re.compile(r"\bno copyright (?:notice|registration)(?: or (?:notice|registration))?\b[^.;,]{0,20}\b(?:evident|found|filed|on file|appears|appeared|located)\b|\brule 5 of the (?:united states|u\.?s\.?) copyright\b", re.I)
DEDICATION_RE = re.compile(r"\b(?:created|digiti[sz]ed|scanned|written|photographed|uploaded|e[- ]?text created) by [A-Z][\w.'\u2019-]+(?: [A-Z][\w.'\u2019-]+){1,3}\b[^.]{0,40}\b(?:and (?:is|are|was|released|placed|dedicated)|released)\b[^.]{0,60}\bpublic domain\b|\breleased (?:into|to|in) the public domain by [A-Z][\w.'\u2019-]+(?: [A-Z][\w.'\u2019-]+){1,3}\b", re.I)
ETEXT_CREDIT_RE = re.compile(r"\be[- ]?text created by [A-Z]", re.I)

# A mirrored library record: the field headers of a Library of Congress item page as a mirror copies them into the
# Internet Archive's description field, in capitals and without colons (LIBRARY_HEADER_RE in text.ts).
LIBRARY_MIN_HEADERS = 3       # a body with fewer upper-case field headers than this is read as prose
LIBRARY_HEADER_WITHIN = 120   # ...and the first header must come this early (right after the title), or the capitals are prose
LIBRARY_HEADER_RE = re.compile(r"(?:^|\s)(MEDIUM|CREATED / PUBLISHED|CONTRIBUTOR NAMES|SUBJECTS|NOTES|FORMAT|SOURCE|REPOSITORY|REPRODUCTION NUMBER|CALL NUMBER|DIGITAL ID|LCCN|CREDIT|RIGHTS|PROVENANCE|PART OF)(?=\s)")

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


def is_file_record(body):
    """True when a body is a file record, not a description (isFileRecord in text.ts): the item's file name or title in
    quotation marks with nothing around it but the names of its collections ("SPS, SPS-Srinagar, Funded-By-IKS-MoE,IKS-SPS
    Filename: 'Bharatiya Sangeet Ka Itihas ... - Sangeet Research Academy'", "'Shola E Khamosh By Kalidas Gupta Raza Urdu
    Poetry Bombay 1965 - Subh E Ummid Publications', Nazki Collection"). At least one quoted run with no sentence inside
    it; outside the quotes no sentence end and at most FILE_MAX_WORDS_PER_TAG words between commas; and either the quotes
    hold half the body or a "Filename:" field names them. 8 archive_org atoms on the 2026-11-15 snapshot, 6 of them
    stored since 11 November, no atom of any other source."""
    b = oncely(clean(body))
    if not b:
        return False
    quoted = [m.group(0) for m in QUOTED_RE.finditer(b)]
    if not quoted:
        return False
    if any(SENTENCE_END_RE.search(q[1:-1]) for q in quoted):
        return False
    rest = FILENAME_RE.sub(" ", QUOTED_RE.sub(" ", b))
    if SENTENCE_END_RE.search(rest):
        return False
    tags = [t.strip() for t in re.split(r"[,;]", rest) if t.strip()]
    if any(len(words(t)) > FILE_MAX_WORDS_PER_TAG for t in tags):
        return False
    return sum(len(q) for q in quoted) * 2 >= len(b) or FILENAME_RE.search(b) is not None


def is_item_record(body):
    """True when a body is an item record, not a description (isItemRecord in text.ts): a scanned object described as an
    object, by its dimensions and weight, its copyright status ("No copyright notice evident, Public Domain under Rule 5 of
    the United States Copyright Statutes"), the uploader's dedication of their own work to the public domain or the
    digitiser's credit ("Etext created by ..."). The rule is the copyright status, or the dedication, or the credit, or a
    dimensions clause together with a weight; a dimensions clause alone is kept (a paper measures proteins, a news story
    gives a display's size). 57 archive_org atoms on the 2026-11-16 snapshot, 54 of them stored since 10 November, among
    them a baptismal certificate, a home inspection report with a street address and class rosters naming private people;
    no atom of any other source."""
    b = oncely(clean(body))
    if not b:
        return False
    return bool(COPYRIGHT_STATUS_RE.search(b) or DEDICATION_RE.search(b) or ETEXT_CREDIT_RE.search(b) or (DIMENSIONS_RE.search(b) and WEIGHT_RE.search(b)))


def is_library_record(body):
    """True when a body is a mirrored library record, not a description (isLibraryRecord in text.ts): the fields of a
    Library of Congress item page copied with their headers in capitals ("L'Elegante valse brillante MEDIUM 1 score
    CREATED / PUBLISHED 1843 SOURCE http://www.loc.gov/item/... CREDIT (Library of Congress) ... RIGHTS The ... collection
    is in the public domain ... PROVENANCE (this copy) Mirrored from loc.gov"). At least LIBRARY_MIN_HEADERS distinct
    headers, the first within LIBRARY_HEADER_WITHIN characters, and a rights sentence somewhere. 4 archive_org atoms on
    the live Commons of 2026-11-23, stored since the 22nd when a mirror began uploading the sheet-music collection; no
    other atom of any source has even two of these headers."""
    b = oncely(clean(body))
    if not b:
        return False
    found, first = set(), -1
    for m in LIBRARY_HEADER_RE.finditer(b):
        found.add(m.group(1))
        if first < 0:
            first = m.start(1)
    if len(found) < LIBRARY_MIN_HEADERS or first > LIBRARY_HEADER_WITHIN:
        return False
    return any(RIGHTS_RE.search(x) for x in re.split(r"[.!?]\s+", b))


def without_physical_description(body):
    """A body with its library physical description and catalogue notes taken out ("ix, 203 pages : 24 cm Includes
    bibliographical references and index" becomes ""); a body with no physical description comes back unchanged."""
    m = PHYSICAL_RE.match(body)
    if not m or not m.group(0).strip():
        return body
    return clean(CATALOGUE_NOTES_RE.sub(" ", body[m.end():]))


STUB_RULES = ("empty", "label", "repeat", "link_notice", "catalogue_record", "shelf_mark", "rights_notice", "file_record", "item_record", "library_record", "no_rest")


def stub_reason(title, summary, content, authors=None):
    """The name of the rule that makes an atom a stub, or None when it carries knowledge. The rules run in the
    ingester's order (isStub in text.ts), so the first that fires is named: "empty" (no body), "label" (fewer than
    STUB_MIN_DISTINCT different words), "repeat" (one line written over and over), "link_notice", "catalogue_record",
    "shelf_mark", "rights_notice", "file_record", "item_record", "library_record" (a Library of Congress page copied by a
    mirror), and "no_rest" (nothing beyond the title, the authors and a physical description)."""
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
    if is_file_record(body):
        return "file_record"
    if is_item_record(body):
        return "item_record"
    if is_library_record(body):
        return "library_record"
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


# ---------------------------------------------------------------------------- rule-made name edits
# build_dataset.contradict() makes a "name" contradiction by swapping any capitalised word of the sentence for the
# title of a random other atom. Read on 2026-11-23 (v29's by_edit put name edits lowest, 0.889): 248 of the 336 name
# edits of the frozen first split, and 2,195 of the 2,923 in train, are not a name swap. The title put in is a paper
# or article title ("Utah Man pleads guilty in wife's death a decision model catch these risks at runtime?"), or the
# word taken out is a sentence opener ("However", "Improving") rather than a name. The claim that results is
# nonsense, not a contradiction of the passage, and a model that calls it not covered is not wrong. Only the clear
# cases are flagged; a type-mismatched but readable swap ("Nietzsche" -> "Corbin station") is left as it is.

NAME_EDIT_RE = re.compile(r"\(name (.+?) -> (.+)\)\.?\s*$")
# words that open sentences and are never names in this corpus
OPENERS = {"however", "when", "could", "would", "should", "while", "after", "before", "during", "there", "these", "those",
           "this", "that", "what", "which", "where", "with", "from", "into", "over", "under", "since", "although", "though",
           "because", "also", "many", "most", "some", "such", "each", "every", "both", "here", "they", "their", "then", "than",
           "thus", "hence", "finally", "first", "second", "third", "today", "yesterday", "recently", "previously", "currently",
           "overall", "instead", "additionally", "furthermore", "moreover", "meanwhile", "despite", "among", "between", "within",
           "without", "using", "based", "given", "following", "according", "unlike", "like", "only", "even", "about", "whether",
           "once", "until", "upon", "just", "results", "methods", "background", "objective", "objectives", "conclusions",
           "conclusion", "purpose", "aims", "introduction", "papers", "studies", "existing", "current", "recent", "large"}
# endings of ordinary English words that open sentences in abstracts ("Improving", "Generalized", "Dual", "Recently")
COMMON_ENDINGS = ("ing", "ed", "ly", "ive", "al", "ous", "tion", "tions", "ment", "ments", "ness", "ity", "ities", "ism", "isms")


def malformed_name_edit(rationale, passage_texts):
    """The reasons a rule-made name contradiction is not a name swap, or [] when it is one, or None when the
    rationale names no name edit. Reasons: "cut_title" (the title put in has an unclosed bracket: "Gaitana (singer"),
    "title_not_name" (it has five or more words, a colon, a question or exclamation mark, or ends with a full stop:
    a paper or article title, not a name), "not_a_name" (the word taken out is one word that opens a sentence of the
    passage and is a common opener or carries a common-word ending). Pure, deterministic, no word list on disk, so
    the cloud, the Mac and the tests agree."""
    m = NAME_EDIT_RE.search(rationale or "")
    if not m:
        return None
    old, new = m.group(1), m.group(2)
    reasons = []
    if new.count("(") != new.count(")"):
        reasons.append("cut_title")
    if len(new.split()) >= 5 or re.search(r"[:?!]", new) or new.rstrip().endswith("."):
        reasons.append("title_not_name")
    if " " not in old:
        opens = any(re.search(r"(?:^|[.!?]\s+)" + re.escape(old) + r"\b", t or "") for t in passage_texts)
        low = old.lower()
        if opens and (low in OPENERS or (len(low) > 5 and low.endswith(COMMON_ENDINGS))):
            reasons.append("not_a_name")
    return reasons

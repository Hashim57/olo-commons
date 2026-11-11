"""zeus/quality.py mirrors isStub (functions/olo-ingest/text.ts) and wikidataHousekeeping (sources.ts);
these are the same examples tests/text_test.ts and tests/sources_test.ts use, so the two ports stay in step."""
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import quality  # noqa: E402

ABS = ("Project Gutenberg is a volunteer effort to digitize and archive cultural works, as well as to encourage the creation "
       "and distribution of eBooks. It was founded in 1971 by American writer Michael S. Hart and is the oldest digital library.")


def test_one_word_or_one_line_repeated_is_a_stub():
    for t, s in [("New Book", "new book new book"), ("adult1010", "adult1010 adult1010"), ("patronyt", "P P"), ("allianz-travelss", "fhfh fhfh"),
                 ("0925", "m m"), ("The Apple Store", ":) :)"), ("Hazrat Ummul Baneen", "Author: Sayyid Saeed Akhtar Rizvi Author: Sayyid Saeed Akhtar Rizvi")]:
        assert quality.is_stub(t, s, s), (t, s)
    assert quality.is_stub("Art and Heart", "Art and Heart. Subjects: Poetry", "Subjects: Poetry")
    assert quality.is_stub("Anything", "", "")
    assert quality.is_stub("Anything", None, None)
    assert quality.is_stub("Tags", "radio drama season picks " * 12, "radio drama season picks " * 12)


def test_a_body_that_only_repeats_the_title_and_author_is_a_stub():
    t = "Hydropower Engineering Module 5 CE IIT Kharagpur"
    assert quality.is_stub(t, t, t, ["IIT Kharagpur"])
    assert quality.is_stub("A Short Title", "A Short Title by Jane Q. Writer", "A Short Title by Jane Q. Writer", ["Jane Q. Writer"])


def test_real_atoms_of_every_source_pass():
    assert not quality.is_stub("Ehnen", "Ehnen: town.", "Ehnen. town. Described in 10 Wikimedia projects.")
    assert not quality.is_stub("Magnus Wikman", "Magnus Wikman: association football player.", "Magnus Wikman. association football player. Described in 5 Wikimedia projects.")
    assert not quality.is_stub("Project Gutenberg", ABS[:120], ABS)
    assert not quality.is_stub("A paper", "We study coral reef recovery after bleaching.",
                               "We study coral reef recovery after bleaching. Reefs with high herbivore cover recovered faster across 40 sites over six years.")
    assert not quality.is_stub("Mason's retreat", "", "After many years in England an impoverished, upper-class American family return to an inherited estate on Chesapeake Bay.")


def test_wikidata_housekeeping():
    assert quality.wikidata_housekeeping("Category:Buildings in Trapani", "Wikimedia category")
    assert quality.wikidata_housekeeping("Kelen", "Wikimedia disambiguation page")
    assert quality.wikidata_housekeeping("Template:Taxonomy/Trissexodon", "taxonomy template")
    assert quality.wikidata_housekeeping("List of sovereign states", "Wikimedia list article")
    assert quality.wikidata_housekeeping("Portal:Science", "Wikimedia portal")
    assert quality.wikidata_housekeeping("Smith", "Wikimedia human name disambiguation page")
    assert not quality.wikidata_housekeeping("Trapani", "city in Sicily, Italy")
    assert not quality.wikidata_housekeeping("Categorical imperative", "central concept in Kantian ethics")
    assert not quality.wikidata_housekeeping("Wikipedia", "free multilingual online encyclopedia")
    assert not quality.wikidata_housekeeping("Template Gothic", "typeface designed in 2001")


def test_wikidata_description_is_what_follows_the_label():
    a = {"title": "Kelen", "summary": "Kelen: Wikimedia disambiguation page."}
    assert quality.wikidata_description(a) == "Wikimedia disambiguation page"
    b = {"title": "A: B", "summary": "A: B: a thing with a colon in its name."}
    assert quality.wikidata_description(b) == "a thing with a colon in its name"



def test_wikidata_description_reads_every_form_the_text_has_had():
    title = "Mercury"
    live = {"title": title, "summary": "Mercury: Wikimedia disambiguation page."}
    joined = {"title": title, "summary": "Mercury: Wikimedia disambiguation page. Mercury. Wikimedia disambiguation page. Described in 41 Wikimedia projects."}
    content_only = {"title": title, "summary": "Mercury. Wikimedia disambiguation page. Described in 41 Wikimedia projects."}
    for a in (live, joined, content_only):
        assert quality.wikidata_description(a) == "Wikimedia disambiguation page"
        assert quality.wikidata_housekeeping(a["title"], quality.wikidata_description(a))
    # a description that must match to its end (PAGE_KIND_RE's "taxonomy template$") is found in the snapshot forms too
    t = {"title": "Taxonomy/Aves", "summary": "Taxonomy/Aves. taxonomy template. Described in 5 Wikimedia projects."}
    assert quality.wikidata_description(t) == "taxonomy template"
    assert quality.wikidata_housekeeping(t["title"], quality.wikidata_description(t))
    # a real thing stays a real thing in every form
    for s in ("Kachari Kingdom: kingdom in medieval Assam, Northeast India.",
              "Kachari Kingdom. kingdom in medieval Assam, Northeast India. Described in 13 Wikimedia projects."):
        k = {"title": "Kachari Kingdom", "summary": s}
        assert quality.wikidata_description(k) == "kingdom in medieval Assam, Northeast India"
        assert not quality.wikidata_housekeeping(k["title"], quality.wikidata_description(k))

def test_usable_atoms_drops_duplicates_stubs_and_housekeeping_once_each_and_keeps_order():
    good = {"id": "g1", "title": "Project Gutenberg", "summary": ABS[:120], "content": ABS, "source": "wikipedia"}
    stub = {"id": "s1", "title": "New Book", "summary": "new book new book", "content": "new book new book", "source": "archive_org"}
    cat = {"id": "c1", "title": "Category:Births in Ivrea", "summary": "Category:Births in Ivrea: Wikimedia category.",
           "content": "Category:Births in Ivrea. Wikimedia category. Described in 4 Wikimedia projects.", "source": "wikidata"}
    town = {"id": "t1", "title": "Ehnen", "summary": "Ehnen: town.", "content": "Ehnen. town. Described in 10 Wikimedia projects.", "source": "wikidata"}
    kept, counts = quality.usable_atoms([good, stub, dict(good), cat, town, dict(stub)])
    assert [a["id"] for a in kept] == ["g1", "t1"]
    assert counts == {"duplicate": 2, "stub": 1, "housekeeping": 1, "stub_by_rule": {"label": 1}}
    # a non-wikidata atom is never judged by the wikidata rule
    wiki_cat = dict(cat, id="w1", source="wikipedia", summary="Category:Births in Ivrea is a category page on Wikipedia that groups the people born in Ivrea, in Piedmont.",
                    content="Category:Births in Ivrea is a category page on Wikipedia that groups the people born in Ivrea, in Piedmont. It has existed since 2006.")
    kept2, counts2 = quality.usable_atoms([wiki_cat])
    assert len(kept2) == 1 and counts2["housekeeping"] == 0


# Same examples as tests/text_test.ts (isLinkNotice); contact addresses replaced by example.org.
NOTICES = [
    "لمزيد من التفاصيل يرجى زيارة ketabpedia.com لمزيد من التفاصيل يرجى زيارة ketabpedia.com",
    "للاطلاع علی بیانات الکتاب يرجى زيارة ketabpedia.com للمراسلة: contact@example.org للاطلاع علی بیانات الکتاب يرجى زيارة ketabpedia.com للمراسلة: contact@example.org",
    "Raw Scan images of a Canister of the Sim Collection: https://archive.org/details/SerialsOnMicrofilmCollection Archival backup. See Sim collection: https://archive.org/details/sim_microfilm All the issues from this canister",
    "Archived blog snapshot from Wedzat (https://www.wedzat.com). Archived blog snapshot from Wedzat (https://www.wedzat.com).",
    "Backup of http://www.islc.net/~ccronan/ from 4 March 2019 Backup of http://www.islc.net/~ccronan/ from 4 March 2019",
]


def test_uploader_notices_are_stubs():
    for n in NOTICES:
        assert quality.is_link_notice(n), n
        assert quality.is_stub("ktp2019-item", n, n), n


def test_a_description_that_cites_a_link_is_kept_and_text_without_a_link_is_not_a_notice():
    abstract = ("We release a benchmark of 12,000 annotated claims drawn from news and encyclopaedia text, with labels for "
                "support, contradiction and missing evidence, and we report baselines from three model families. Code and "
                "data are available at https://github.com/example/claims.")
    assert not quality.is_link_notice(abstract)
    assert not quality.is_stub("A claim benchmark", abstract, abstract)
    assert not quality.is_link_notice("Elementary algebra encompasses the basic concepts of algebra, such as variables and terms, and U.S. schools teach it.")
    assert not quality.is_link_notice("")
    assert not quality.is_link_notice("Dose 2.5 mg, version 1.2.3, p. 4.")


DELPHER = ("Title: De 's Gravenhaagsche nieuwsbode Datum: 06-02-1859 Editie: Dag Plaats van uitgave: 's Gravenhage Uitgever: "
           "J.A. de la Vieter Verspreidingsgebied: Regionaal/lokaal Nummer: 220")


def test_catalogue_records_are_stubs():
    records = [
        "Title: Algemeen Handelsblad Datum: 22-05-1861 Editie: Dag Plaats van uitgave: Amsterdam Uitgever: P. den Hengst en Zoon [etc.] Verspreidingsgebied: Landelijk Nummer: 120",
        DELPHER + " " + DELPHER,
        "Title: Journal de la province de Limbourg Datum: 09-10-1824 Editie: Dag Plaats van uitgave: Maastricht Uitgever: L.Th. N\u0133pels Verspreidingsgebied: Regionaal/lokaal Nummer: 238",
        "Gazette Type: Extraordinary Date: 2022-05-26 Department: Home Election Department Subject: designates the officer, Gazette Source: URL",
        "Gazette Type: Daily Date: 2022-04-20 Department: Gazette contains multiple Departments/Organizations Subject: Gazette contains multiple Subjects Gazette Source: URL",
        "Gazette Type: Extra Ordinary Gazette Number: 611 Date: 2024-10-01 Gazette Type: Extra Ordinary Gazette Number: 611 Date: 2024-10-01",
    ]
    for r in records:
        assert quality.is_catalogue_record(r), r
        assert quality.is_stub("Algemeen Handelsblad 22-05-1861", r, r), r


def test_prose_with_headings_and_real_atoms_pass_the_catalogue_rule():
    abstract = ("OBJECTIVE: To estimate the effectiveness of neuromuscular training and training load management interventions in "
                "preventing injuries in youth football. METHODS: We searched five databases to March 2025 for randomised trials. "
                "RESULTS: Twelve trials with 9,412 players were included; training programmes reduced injury incidence by a third. "
                "CONCLUSIONS: Neuromuscular training prevents injuries in youth football.")
    assert not quality.is_catalogue_record(abstract)
    assert not quality.is_stub("Injury prevention in youth football", abstract[:200], abstract)
    assert not quality.is_catalogue_record("Bezugnehmend auf: Arnold Schering: Bach und das Symbol, insbesondere die Symbolik seines Kanons. BJ 1925, S. 40-63 "
                                           "Darauf bezugnehmend: Arnold Schering: Bach und das Symbol. 3. Studie: Psychologische Grundlegung des "
                                           "Symbolbegriffs aus Christian Wolffs Psychologia empirica. BJ 1937, S. 83-95")
    assert not quality.is_catalogue_record("Dataset published by Wake County. Wake County farmers market locations, hours, and descriptions. Source: county GIS. Updated: weekly.")
    assert not quality.is_catalogue_record("Ehnen: town. Described in 10 Wikimedia projects.")
    assert not quality.is_catalogue_record("")
    assert not quality.is_catalogue_record("At 10:20 AM, the Prime Minister revealed his cabinet; at 11:05 the list was published and at 12:30 the first ministers were sworn in by the King.")


def test_oncely_reads_a_doubled_text_once():
    once = "Title: Arnhemsche courant Datum: 10-12-1814 Editie: Dag Nummer: 147"
    assert quality.oncely(once + " " + once) == once
    assert quality.oncely(once) == once
    assert quality.oncely("short short") == "short short"


def test_shelf_marks_are_stubs():
    dash = " \u2013 "
    parts = ["Karnataka State Archives", "Mysore", "Gazettes", "Gazette-6", "HRS-Historical Record Section", "R", "369 (ID 102517)"]
    for sep in (dash, " - ", " | ", " / "):
        r = sep.join(parts)
        assert quality.is_shelf_mark(r), r
        assert quality.is_shelf_mark(r + " " + r), r
        assert quality.is_stub("76_PART_2_4_OCT_DEC_1903_118.pdf", r, r), r


def test_sentences_with_asides_and_publisher_chains_pass_the_shelf_rule():
    assert not quality.is_shelf_mark("Dataset published by DOC/NOAA/NESDIS/NCEI > National Centers for Environmental Information, NESDIS, NOAA, "
                                     "U.S. Department of Commerce. Daily summaries of temperature and precipitation from 1,200 stations.")
    assert not quality.is_shelf_mark("The study - the first of its kind in Europe - followed 3,000 children for a decade and found that reading "
                                     "aloud at home - even ten minutes a day - raised vocabulary scores.")
    assert not quality.is_shelf_mark("Annual report - 1903 - Mysore - Railways")
    assert not quality.is_shelf_mark("")


def test_physical_descriptions_alone_are_stubs():
    records = [
        "ix, 203 pages : 24 cm Includes bibliographical references and index",
        "121 pages ; 24 cm Includes bibliographical references (pages 112 -115) and index",
        "xii, 386 p. : 23 cm Includes indexes Bibliography: p. 347-375",
        "1 guide (191 p.) : 23 cm",
        "1 volume (unpaged) : 24 cm Includes bibliography",
        "287 pages, 16 unnumbered pages of plates : 24 cm",
        "xv, 415 p. : ill. ; 24 cm Includes index",
        "v, 268 pages : 24 cm English or French Includes bibliographies",
    ]
    for r in records:
        assert len(quality.without_physical_description(r)) < 40, r
        assert quality.is_stub("Some scanned book", r, r), r
    assert quality.without_physical_description("ix, 203 pages : 24 cm Includes bibliographical references and index") == ""


def test_records_with_a_summary_after_the_measurements_are_kept():
    amish = ("282 pages ; 22 cm An Amish man leaves his community and family to escape parental abuse but he also leaves "
             "behind the woman he planned to marry.")
    assert quality.without_physical_description(amish) == amish[len("282 pages ; 22 cm "):]
    assert not quality.is_stub("Lavina", amish, amish)
    abstract = "We study coral reef recovery after bleaching. Reefs with high herbivore cover recovered faster across 40 sites over six years."
    assert quality.without_physical_description(abstract) == abstract
    news = "12 people were injured when a bus left the road near Tromso on Tuesday."
    assert quality.without_physical_description(news) == news
    assert quality.without_physical_description("") == ""


CROSSREF = "This paper is in the public domain in USA. Metadata comes from the CrossRef API, see full record in the source URL below."


def test_rights_notices_are_stubs():
    # the same examples as tests/text_test.ts, so the ingester and the training filter stay in step
    assert quality.is_rights_notice(CROSSREF)
    assert quality.is_rights_notice(CROSSREF + " " + CROSSREF)
    assert quality.is_stub("Notes", CROSSREF, CROSSREF)
    assert quality.is_rights_notice("No known copyright restrictions.")
    assert quality.is_rights_notice("Public Domain Mark 1.0. Metadata from the publisher.")


def test_descriptions_that_mention_rights_in_passing_pass_the_rights_rule():
    assert not quality.is_rights_notice("Attente de Dieu by XXe century french philosopher and mystic Simone Weil. It's public domain.")
    assert not quality.is_rights_notice('Bank Note Reporter by Krause Publications Inc. This is an in-copyright publication. "Snippet" results will appear in the Newman Portal search results.')
    abstract = ("With the rapid adoption of large language models in text generation, it has become difficult to trace generated content and assert copyright. "
                "We study watermarking schemes that survive paraphrase, measuring detection rates on three model families across news, fiction and code, "
                "and we show that metadata alone cannot establish provenance once the text has been edited. Our results suggest that copyright holders "
                "need a combination of watermarks and public registries, and we release the evaluation suite under a public domain dedication so that others can extend it.")
    assert not quality.is_rights_notice(abstract)
    assert not quality.is_rights_notice("Public Domain Day. annual observance on 1 January. Described in 8 Wikimedia projects.")
    assert not quality.is_rights_notice("")
    assert not quality.is_stub("Public Domain Day", "Public Domain Day. annual observance on 1 January.", "Public Domain Day. annual observance on 1 January. Described in 8 Wikimedia projects.")


def test_stub_reason_names_the_first_rule_that_fires_in_the_ingester_order():
    shelf = " - ".join(["Karnataka State Archives", "Mysore", "Gazettes", "Gazette-6", "HRS-Historical Record Section", "R", "369 (ID 102517)"])
    cases = [
        ("Anything", "", "", "empty"),
        ("patronyt", "P P", "P P", "label"),
        ("New Book", "new book new book new book new book", "new book new book new book new book", "label"),
        ("Tags", "radio drama season picks and more music " * 6, "radio drama season picks and more music " * 6, "repeat"),
        ("ktp2019-item", NOTICES[0], NOTICES[0], "link_notice"),
        ("Algemeen Handelsblad", DELPHER, DELPHER, "catalogue_record"),
        ("76_PART_2_4_OCT_DEC_1903_118.pdf", shelf, shelf, "shelf_mark"),
        ("Our Astronomical Column", CROSSREF, CROSSREF, "rights_notice"),
        ("Some scanned book", "ix, 203 pages : 24 cm Includes bibliographical references and index", "ix, 203 pages : 24 cm Includes bibliographical references and index", "no_rest"),
        ("Hydropower Engineering Module Five Lecture Notes", "Hydropower Engineering Module Five Lecture Notes by IIT Kharagpur", "Hydropower Engineering Module Five Lecture Notes by IIT Kharagpur", "no_rest"),
    ]
    for title, summary, content, rule in cases:
        assert quality.stub_reason(title, summary, content) == rule, (summary, rule)
        assert rule in quality.STUB_RULES
        assert quality.is_stub(title, summary, content)
    assert quality.stub_reason("Project Gutenberg", ABS[:120], ABS) is None
    assert not quality.is_stub("Project Gutenberg", ABS[:120], ABS)


def test_usable_atoms_counts_stubs_by_rule():
    shelf = " - ".join(["Karnataka State Archives", "Mysore", "Gazettes", "Gazette-6", "HRS-Historical Record Section", "R", "369 (ID 102517)"])
    atoms = [
        {"id": "a", "title": "Project Gutenberg", "summary": ABS[:120], "content": ABS, "source": "wikipedia"},
        {"id": "b", "title": "x", "summary": shelf, "content": shelf, "source": "archive_org"},
        {"id": "c", "title": "y", "summary": shelf, "content": shelf, "source": "archive_org"},
        {"id": "d", "title": "z", "summary": DELPHER, "content": DELPHER, "source": "archive_org"},
    ]
    kept, counts = quality.usable_atoms(atoms)
    assert [x["id"] for x in kept] == ["a"]
    assert counts["stub"] == 3
    assert counts["stub_by_rule"] == {"shelf_mark": 2, "catalogue_record": 1}

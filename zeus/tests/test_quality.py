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


def test_usable_atoms_drops_duplicates_stubs_and_housekeeping_once_each_and_keeps_order():
    good = {"id": "g1", "title": "Project Gutenberg", "summary": ABS[:120], "content": ABS, "source": "wikipedia"}
    stub = {"id": "s1", "title": "New Book", "summary": "new book new book", "content": "new book new book", "source": "archive_org"}
    cat = {"id": "c1", "title": "Category:Births in Ivrea", "summary": "Category:Births in Ivrea: Wikimedia category.",
           "content": "Category:Births in Ivrea. Wikimedia category. Described in 4 Wikimedia projects.", "source": "wikidata"}
    town = {"id": "t1", "title": "Ehnen", "summary": "Ehnen: town.", "content": "Ehnen. town. Described in 10 Wikimedia projects.", "source": "wikidata"}
    kept, counts = quality.usable_atoms([good, stub, dict(good), cat, town, dict(stub)])
    assert [a["id"] for a in kept] == ["g1", "t1"]
    assert counts == {"duplicate": 2, "stub": 1, "housekeeping": 1}
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

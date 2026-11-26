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
    assert counts == {"duplicate": 2, "stub": 1, "email": 0, "court_record": 0, "housekeeping": 1, "stub_by_rule": {"label": 1}}
    # a non-wikidata atom is never judged by the wikidata rule
    wiki_cat = dict(cat, id="w1", source="wikipedia", summary="Category:Births in Ivrea is a category page on Wikipedia that groups the people born in Ivrea, in Piedmont.",
                    content="Category:Births in Ivrea is a category page on Wikipedia that groups the people born in Ivrea, in Piedmont. It has existed since 2006.")
    kept2, counts2 = quality.usable_atoms([wiki_cat])
    assert len(kept2) == 1 and counts2["housekeeping"] == 0


# Same examples as tests/text_test.ts (isLinkNotice); contact addresses replaced by example.org.
NOTICES = [
    "لمزيد من التفاصيل يرجى زيارة example.org لمزيد من التفاصيل يرجى زيارة example.org",
    "للاطلاع علی بیانات الکتاب يرجى زيارة example.org للمراسلة: contact@example.org للاطلاع علی بیانات الکتاب يرجى زيارة example.org للمراسلة: contact@example.org",
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


FILE_RECORDS = [
    ("Bharatiya Sangeet Ka Itihas Dr. Thakur Jayadeva Singh Kolkata", "SPS, SPS-Srinagar, Funded-By-IKS-MoE,IKS-SPS Filename: 'Bharatiya Sangeet Ka Itihas Dr.Thakur Jayadeva Singh Kolkata - Sangeet Research Academy'"),
    ("Miscellaneous Unknown Unknown Tamil", "Muthulakshmi Research Academy Scans,Funded-By-IKS-MoE,IKS-MUTHU, Filename: 'Miscellaneous-Unknown-Unknown-Tamil'"),
    ("Upanishad Rahasya Ya Gita Ki Samagra Vyakhya ( Box 22 ) Anandomayi", "Sri Sri Anandamayee Ashram Varanasi Collection Filename: 'Upanishad Rahasya ya Gita ki Samagra Vyakhya ( Box 22 ) - Anandomayi'"),
    ("Shola E Khamosh By Kalidas Gupta Raza Urdu Poetry Bombay 1965", "'Shola E Khamosh By Kalidas Gupta Raza Urdu Poetry Bombay 1965 - Subh E Ummid Publications', Nazki Collection"),
    ("Mugdhabodhawithcommentary Sivanarayansiromani 1913 Bibliotheca Indica", "Bibliotheca Indica Series, Asiatic Society of Bengal, 'Mugdhabodhawithcommentary-Sivanarayansiromani1913 Bibliotheca Indica - the Asiatic Society Calcutta'"),
    ("Shash Kalima Ma Namaz Arabic And Urdu Islam Lithograph Missing Pages Srinagar", "'Shash Kalima Ma Namaz Arabic and Urdu Islam Lithograph Missing Pages Srinagar - Ghulam Muhammad Nur Muhammad', Aalami-Urdu-ConferenceAalami-Urdu-Conference, BVB-Lucknow-Donations, BVB"),
    ("Der Tropenpflanzer", "${res.getProperty('main.meta.description')}"),
]


def test_file_records_are_stubs():
    # the same examples as tests/text_test.ts (the 2026-11-15 snapshot), so the ingester and the training filter stay in step
    for title, body in FILE_RECORDS:
        assert quality.is_file_record(body), body
        assert quality.is_file_record(body + " " + body), body
        assert quality.is_stub(title, body, body), body
        # the first rule in the ingester's order is named: the template has too few distinct words to get this far
        assert quality.stub_reason(title, body, body) == ("label" if body.startswith("$") else "file_record"), body
    assert quality.is_file_record('Nazki Collection, "Shola E Khamosh By Kalidas Gupta Raza Urdu Poetry Bombay 1965 - Subh E Ummid Publications"')
    assert quality.is_file_record("Nazki Collection, \u201cShola E Khamosh By Kalidas Gupta Raza Urdu Poetry Bombay 1965\u201d")


ITEM_RECORDS = [
    # the same examples as tests/text_test.ts (the 2026-11-16 snapshot), the uploader's name replaced by a placeholder
    ("gaylord_library_card_number_55", 'Gaylord Library Card number 55; 13 August 1982. Dimensions: 2 7/8" width by 4 7/8" height; weight 1.9 grams. E text created by Jane Doe. Hi-resolution TIFF files are archived and can be downloaded.'),
    ("Baptism_Certificate_Immaculate_Conception_Church", "This is a Baptismal Certificate issued in the Immaculate Conception Church, Astoria, New York, Form No. 314, dated 5 October, 1952, for Jane Doe; printed by F. J. Remey Co., New York. No copyright notice evident, Public Domain under Rule 5 of the United States Copyright Statutes."),
    ("Homart_303_220_Sears_Humidifier_", 'Homart Furnace Humidifier; Published by Sears, Roebuck and Company, Chicago, Illinois; in 1950; Part Number 85-099; Model Number 303.220. Dimensions are: 8 1/2" width by 11" height, 4 pages. No copyright notice evident.'),
    ("olympus_model_OM_10_camera_", "Olympus Model OM-10 Camera and owner's manual; published June 1979, by Olympus. There is no copyright registration or notice filed for this item; the digital work was created by Jane Doe and is in the Public Domain under the Creative Commons License."),
    ("Thoughts_Of_You", "This is a Poem written by Jane Doe; 19 February 2000. 'Thoughts of You'. The hand written document is included. This work was created by Jane Doe and is in the Public Domain under the Creative Commons License."),
    ("ISE_100_Prospectus", "This is a prospectus for a course ISE100 'Computer and Information Technology Fundamentals' held for National College, South Bend, Indiana. 19 December 2011. Created by Jane Doe and released under the Creative Commons License in the Public Domain."),
    ("ISE100_Course_Objectives", "These are the Course Objectives and Outline for Week 8; for the course ISE100 offered at National College, South Bend, Indiana. Released into the Public Domain by Jane Doe under the Creative Commons License."),
    ("What_Is_Medical_Informatics_", "What is Medical Informatics; by Dr. John Roe. Used for MP520 Computer Systems in Medicine for Radiological Technologies University, South Bend, Indiana Campus. Uploaded by Jane Doe and released into the Public Domain."),
    ("IREX_Addendum_", "This is an Addendum to an exchange program Proposal filed under the International Research and Exchanges Board (IREX), 2121 K Street, NW; Suite 700, Washington, D.C. 20037; 26 June 2002. Public Domain as government document. Etext created by Jane Doe."),
    ("ceramic_pitcher_03_wash_basin_green_white", "Ceramic Pitcher 03 and wash-basin; 1920. Dimensions are: Pitcher height 305.0 millimeters by maximum width by base width 110.0 millimeters by width 110.0 millimeters; and weight 1,443.0 grams; Bowl dimensions are: top 405.0 millimeters diameter by base 175.0 millimeters diameter by 115.0 millimeters height."),
    ("hand_fan_01_japanese_silk_1890", "Japanese Hand Fan made of silk. Dimension of fan: 220 millimeters diameter by 2.0 millimeters rim thickness, 110.0 handle length by 9.0 millimeters thickness, and 23.1 grams total weight. No copyright notice or registration on file."),
    ("CASE Original Purchaser Warranty Card", "CASE Original Purchaser Warranty Card New Case Machines, 9-55671, Form 2107-Rev. 1, November 1963. J. I. CASE Company, Racine, Wisconsin. Dimensions are: 89.0 millimeters width by 120.0 millimeters height, and weight 3.1 grams; 1 page."),
]


def test_item_records_are_stubs():
    for title, body in ITEM_RECORDS:
        assert quality.is_item_record(body), body
        assert quality.is_item_record(body + " " + body), body
        assert quality.is_stub(title, body, body), body
        assert quality.stub_reason(title, body, body) == "item_record", body


def test_measurements_and_the_public_domain_in_real_text_pass_the_item_record_rule():
    # a dimensions clause alone, a weight alone
    assert not quality.is_item_record("Roll up displays for use in hand-held gadgets will be available for mass production by March 2007 according to Philips. The first screens are 5 inches wide and 0.1 mm thick, a 5 inch width that fits a pocket.")
    assert not quality.is_item_record("We relate the stability of a protein to its length: a chain of 300 residues spans about 10 nm length when folded, and the dimension of the folded state sets the width of the funnel.")
    assert not quality.is_item_record("A 68-year-old man was seen at the hospital because of an increasing body weight loss of 12 kg, unquenchable thirst and back pain.")
    # the public domain mentioned in passing, a work that entered it by age, a copyright notice discussed
    assert not quality.is_item_record("Public Domain Day is an annual observance on 1 January of the day when copyrights expire and works enter the public domain. Described in 8 Wikimedia projects.")
    assert not quality.is_item_record("The novel was published in 1817 and has been in the public domain for more than a century; this edition was scanned by the Boston Public Library from its own copy.")
    assert not quality.is_item_record("Under the 1909 Act a work published without a copyright notice fell into the public domain; the 1989 amendments made the notice optional.")
    assert not quality.is_item_record("Ochyrotica. genus of insects. Described in 8 Wikimedia projects.")
    assert not quality.is_item_record("")
    assert quality.stub_reason("Public Domain Day", "Public Domain Day. annual observance on 1 January. Described in 8 Wikimedia projects.", "") is None


def test_descriptions_that_quote_something_pass_the_file_record_rule():
    assert not quality.is_file_record('"Northanger Abbey" by Jane Austen is a coming-of-age novel and satire of Gothic fiction completed in 1799 and published posthumously in 1817.')
    assert not quality.is_file_record('15 pages : 21 cm "The circus is in town. Come and see!"--Back cover')
    assert not quality.is_file_record('The minister said the plan was "a first step", and the opposition called it "too little, too late".')
    assert not quality.is_file_record("Women's rights advocate and Georgetown University Law Center graduate Sandra Fluke was a featured speaker Wednesday at the 2012 Democratic National Convention in Charlotte, North Carolina, the speech was broadcast on the network's news channel")
    assert not quality.is_file_record("'Annual report of the Mysore railways 1903', scanned from the copy held by the state archive at Bangalore")
    assert not quality.is_file_record("Karnataka State Archives - Mysore - Gazettes - Gazette-6 - HRS-Historical Record Section - R - 369 (ID 102517)")
    assert not quality.is_file_record("Ochyrotica. genus of insects. Described in 8 Wikimedia projects.")
    assert not quality.is_file_record("")


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


def test_atoms_with_an_email_address_are_refused_and_counted_apart():
    postcard = ("This photograph Post Card is of an unknown subject, Paris Number 531/32; 01 January 1907; French Postcard. "
                "Anyone who can identify the subject in this photograph is encouraged to contact me at someone@example.com, or comment below.")
    court = "Criminal Appeal No.36530 of 2008 RAM KUMAR @ RAMU @ R. KUMAR, Son of Late Shyam Kumar, Versus The State."
    assert quality.has_email_address("photograph_unknown_post_card_205", postcard, postcard)
    assert quality.has_email_address("uploader2002@example.net", "A scanned book with a long enough description to pass every other rule.", "")
    assert not quality.has_email_address("Patna High Court", court, court)
    assert not quality.has_email_address("Pass@1", "it raises pass@1 while the base model overtakes it at pass@256", None)
    assert not quality.has_email_address("Project Gutenberg", ABS, ABS)
    atoms = [
        {"id": "a", "title": "Project Gutenberg", "summary": ABS[:120], "content": ABS, "source": "wikipedia"},
        {"id": "b", "title": "photograph_unknown_post_card_205", "summary": postcard[:600], "content": postcard, "source": "archive_org"},
        {"id": "c", "title": "Patna High Court", "summary": court, "content": court, "source": "archive_org"},
    ]
    kept, counts = quality.usable_atoms(atoms)
    assert [x["id"] for x in kept] == ["a"]
    assert counts["email"] == 1 and counts["court_record"] == 1 and counts["stub"] == 0


def test_court_records_are_refused_and_counted_apart():
    patna = ("HIGH COURT OF JUDICATURE AT PATNA Cr.Misc. No.25012 of 2008 A. P. SINHA Versus THE STATE OF BIHAR ----------- 2 28.08.2008 "
             "Heard learned counsel for the petitioner and State. This petitioner is a named accused person in a case which has been registered under Section")
    assert quality.is_court_record("Patna High Court - BRHC010028812008 (2008-08-28)", patna[:600], patna)
    jaipur = ("COURT OF JUDICATURE FOR RAJASTHAN BENCH AT JAIPUR S.B. Civil Writ Petition No.3503/07 G. Toshniwal & Anr. Vs. Chief Judicial Magistrate & Anr. "
              "Date of order: 5.10.2007 HON'BLE MR. JUSTICE M. RAFIQ Mr. Sandeep Mehta, for the petitioners.")
    assert quality.is_court_record("High Court Of Rajasthan - RJHC020123982007 (2007-10-05)", jaipur, jaipur)
    telangana = "SRI JUSTICE G. RAGHURAM W.P.No. 17830 of 2007 23-08-2007 Between: P. S. Reddy Petitioner And The District Collector, East Godavari District and two others Respondents"
    assert quality.is_court_record("High Court for State of Telangana - HBHC010268642007 (2007-08-23)", telangana, telangana)
    nainital = "COURT OF UTTARAKHAND AT NAINITAL Writ Petition No. 18(S/S)2007 L. Ram S/o R. Swaroop Barber vide no. 9322622, Central Industrial Security Force (CISF) Unit BHEL, Ranipur, R/o quarter no. A/189 C"
    assert quality.is_court_record("High Court of Uttarakhand - UKHC010031592007 (2007-04-25)", nainital, nainital)
    # one or two of the three signs is not a record: Wikipedia and Wikinews texts about courts, an abstract, a book
    adams = ("2022 Florida court case on transgender students' rights to access bathrooms. Adams ex rel. Kasper v. School Board of St. Johns County, Florida "
             "is a court case from the United States Court of Appeals for the Eleventh Circuit.")
    assert not quality.is_court_record("Adams ex rel. Kasper v. School Board of St. Johns County, Florida", adams, adams)
    monkeys = "The Delhi High Court expressed its displeasure to the civic authorities on their continued failure to resolve the problem of marauding monkeys in the court premises."
    assert not quality.is_court_record("Errant monkeys draw the ire of Delhi court", monkeys, monkeys)
    souter = 'In the town of Weare, New Hampshire, a movement is under way to force Supreme Court Justice David Souter to sell his home for "public benefit," an expansion of the eminent domain ruling he joined.'
    assert not quality.is_court_record("House of Supreme Court Justice threatened", souter, souter)
    abstract = "We study 1,240 trials registered between 2005 and 2019 (No. 12 of 2019 in our numbering) and find that the applicant institutions reported outcomes in 61 percent of cases."
    assert not quality.is_court_record("Reporting of trial outcomes", abstract, abstract)
    book = "A history of the Supreme Court of the United States from its founding to the present day, with chapters on each Chief Justice and the cases that defined the institution."
    assert not quality.is_court_record("The Supreme Court: a history", book, book)
    assert not quality.is_court_record("Project Gutenberg", ABS, ABS)
    assert not quality.is_court_record(None, None, "")
    atoms = [
        {"id": "a", "title": "Project Gutenberg", "summary": ABS[:120], "content": ABS, "source": "wikipedia"},
        {"id": "b", "title": "Patna High Court - BRHC010028812008 (2008-08-28)", "summary": patna[:600], "content": patna, "source": "archive_org"},
        {"id": "c", "title": "The Supreme Court: a history", "summary": book, "content": book, "source": "archive_org"},
    ]
    kept, counts = quality.usable_atoms(atoms)
    assert [x["id"] for x in kept] == ["a", "c"]
    assert counts["court_record"] == 1 and counts["email"] == 0 and counts["stub"] == 0


def test_a_rule_made_name_edit_that_is_no_name_swap_is_flagged():
    f = quality.malformed_name_edit
    # the title of an article or paper put in where a name was
    assert f("The passage gives a different value (name Clark -> Utah Man pleads guilty in wife's death).", ["Judge Clark ruled."]) == ["title_not_name"]
    assert f("(name Masked -> Integrated Sensing and Communication via Channel Knowledge Maps).", ["Masked models."]) == ["title_not_name", "not_a_name"]
    assert "title_not_name" in f("(name Seven -> Microplastics: a review).", ["x"])
    # a title cut inside its bracket
    assert f("(name Rathcoole -> Gaitana (singer).", ["The depot in Rathcoole."]) == ["cut_title"]
    # a sentence opener taken out, not a name
    assert f("(name However -> Chara Sands).", ["It grew. However, it stalled."]) == ["not_a_name"]
    assert f("(name Improving -> Garoden).", ["Improving the throughput is central."]) == ["not_a_name"]
    # a readable swap of one name for another stays, even across types, and so does an opener that is a name
    assert f("(name Germany -> Chara Sands).", ["Italian Embassy, Berlin: mission of Italy to Germany."]) == []
    assert f("(name Nietzsche -> Corbin station).", ["Nietzsche launches a fierce attack."]) == []
    assert f("(name Khan Foundation -> Indian Ocean Earthquake).", ["Aga Khan Foundation said."]) == []
    # not a name edit at all
    assert f("The passage gives a different value (year 1971 -> 1978).", ["x"]) is None
    assert f("", []) is None

LOC_RECORD = ("L'Elegante valse brillante MEDIUM 1 score CREATED / PUBLISHED 1843 SOURCE http://www.loc.gov/item/2023798348/ "
              "Digital id: ['M1.A12 I'] CREDIT (Library of Congress) Credit Line: Music Division, Library of Congress. RIGHTS The "
              "Library of Congress Music for the Nation: American Sheet Music, ca. 1820-1860 collection is in the public domain and "
              "is free to use and reuse. No known copyright restrictions. Public domain: copyright not renewed or term expired (works "
              "published before 1930; 17 U.S.C. sec. 304/302 schedule). No endorsement of this mirror by the Library of Congress is "
              "implied. PROVENANCE (this copy) Mirrored from loc.gov with no processing. Mirrored to archive.org by the Hessel Digital "
              "Library (HDL) for preservation access.")

LIBRARY_RECORDS = [
    ("L'Elegante valse brillante (1843, Library of Congress)", LOC_RECORD),
    ("Fort Wayne quick step (1841, Library of Congress)", "Fort Wayne quick step MEDIUM 1 score CREATED / PUBLISHED 1841 SOURCE http://www.loc.gov/item/2023797954/ Digital id: ['M1.A12 I'] CREDIT (Library of Congress) Credit Line: Music Division, Library of Congress. RIGHTS The Library of Congress Music for the Nation: American Sheet Music, ca. 1820-1860 collection is in the public domain and is free to use and reuse. No known copyright restrictions. PROVENANCE (this copy) Mirrored from loc.gov with no processing."),
    ("Ne pleurez pas (1836, Library of Congress)", "Ne pleurez pas MEDIUM 1 score CREATED / PUBLISHED 1836 CONTRIBUTOR NAMES Grobe, Charles. REPRODUCTION NUMBER http://hdl.loc.gov/loc.music/sm1836.123 CALL NUMBER M1.A12 V RIGHTS The collection is in the public domain and is free to use and reuse. No known copyright restrictions. Public domain: copyright not renewed or term"),
]


def test_library_records_are_stubs():
    for title, body in LIBRARY_RECORDS:
        assert quality.is_library_record(body), body
        assert quality.is_library_record(body + " " + body), body
        assert quality.is_stub(title, body[:600], body), body
        assert quality.stub_reason(title, body[:600], body) == "library_record", body


def test_capitals_and_rights_sentences_in_real_text_pass_the_library_record_rule():
    # two headers only, prose about a library
    assert not quality.is_library_record("The Library of Congress holds the largest collection of sheet music in the world. SOURCE materials and NOTES from the Music Division are open to researchers, and most pieces published before 1930 are in the public domain.")
    # three of the words in capitals, late in the text, no rights sentence
    assert not quality.is_library_record("The committee read the report in full before voting. Its chapters were headed MEDIUM, FORMAT and SOURCE, and each ran to several pages of findings about how newspapers describe their suppliers.")
    # a headline with two of the words and a rights sentence
    assert not quality.is_library_record("CREDIT RIGHTS ROW ENDS IN COURT. The newspaper settled the dispute over the photographs, which the court said were in the public domain since the photographer died in 1890.")
    # a catalogue record with colons, a Wikidata item, an empty body
    assert not quality.is_library_record("Title: Algemeen Handelsblad Datum: 22-05-1861 Editie: Dag Plaats van uitgave: Amsterdam Uitgever: P. den Hengst en Zoon Nummer: 120")
    assert not quality.is_library_record("Library of Congress. national library of the United States. Described in 90 Wikimedia projects.")
    assert not quality.is_library_record("")
    # the real record with its headers in lower case is prose
    import re
    assert not quality.is_library_record(re.sub(r"MEDIUM|CREATED / PUBLISHED|SOURCE|CREDIT|RIGHTS|PROVENANCE", lambda m: m.group(0).lower(), LOC_RECORD))


EUROPEAN_CATALOGUE_RECORDS = [
    ("\u0152uvres de don Barth\u00e9lemi de las Casas, \u00e9v\u00eaque de Chiapa", "Cote du document : DELTA 53987 FA 2 tomes ([8]-CX-409-[1] ; [6]-503-[1] p.) : ill. ; in-8. Notice Sudoc"),
    ("Epistler, befattende adskillige historiske, politiske, metaphysiske", "440 p. ; In-8 Cote du document : 8 SC SUP 57 (3) NOR Notice dans le Sudoc Autres documents li\u00e9s : 8 SC SUP 57 (1) NOR 8 SC SUP 57 (2) NOR 8 SC SUP 57 (4) NOR"),
    ("Relaciones y cartas de Crist\u00f3bal Col\u00f3n", "M\u00e1s detalles PUBLICACI\u00d3N Madrid : Viuda de Hernando, 1892 DESCR. F\u00cdSICA 424 p. ; 19 cm COLECCI\u00d3N Biblioteca cl\u00e1sica ; 164 Biblioteca cl\u00e1sica (Librer\u00eda Vda. de Hernando y Cia.) ; 164 Subject Col\u00f3n, Crist\u00f3bal, 1451?-1506 -- Correspondencia CLASIF. ABREV. 929 A/Z CLASIFICAC. 929 Col\u00f3n, C. SIGNATURA B Res.140146 Cat\u00e1logo Fama"),
]


def test_european_library_catalogue_pages_are_library_records_as_in_text_ts():
    for title, body in EUROPEAN_CATALOGUE_RECORDS:
        assert quality.is_library_record(body), body
        assert quality.is_library_record(body + " " + body), body
        assert quality.is_stub(title, body[:600], body), body


def test_french_and_spanish_prose_about_shelf_marks_passes_the_library_record_rule():
    # the same sentences tests/text_test.ts keeps
    assert not quality.is_library_record("La cote du document indique la place du livre sur le rayon ; le Sudoc est le catalogue collectif des biblioth\u00e8ques universitaires fran\u00e7aises, cr\u00e9\u00e9 en 2000.")
    assert not quality.is_library_record("El tratado de 1892 re\u00fane las cartas de Col\u00f3n a los Reyes Cat\u00f3licos. M\u00e1s detalles sobre la edici\u00f3n figuran en el pr\u00f3logo de Fern\u00e1ndez de Navarrete.")
    assert not quality.is_library_record("M\u00e1s detalles sobre la guerra de 1898 se encuentran en los diarios de la \u00e9poca, que describen el bloqueo del puerto de Santiago de Cuba y la rendici\u00f3n de la ciudad en julio.")
    assert not quality.is_library_record("El contrato se firma por duplicado. SIGNATURA del arrendador y del arrendatario al pie de cada p\u00e1gina, seg\u00fan el art\u00edculo 1255 del C\u00f3digo Civil.")


def test_a_wikidata_atom_with_a_facts_sentence_is_knowledge_not_a_record():
    # the shape the connector writes since 2026-11-23: description, then "property value" clauses joined by semicolons
    title = "Yuri Zheleznov"
    summary = "Yuri Zheleznov: Russian footballer. Instance of human; country of citizenship Russia; date of birth 15 November 2002; place of birth Saransk; occupation association football player; member of sports team FC Ural Yekaterinburg."
    content = summary.replace(": ", ". ", 1)[:-1] + ". Described in 4 Wikimedia projects."
    assert quality.stub_reason(title, summary, content) is None
    assert not quality.is_catalogue_record(summary)
    a = {"title": title, "summary": summary, "source": "wikidata"}
    assert quality.wikidata_description(a).startswith("Russian footballer")
    assert not quality.wikidata_housekeeping(title, quality.wikidata_description(a))
    # a housekeeping item is still read as one from the start of its description
    assert quality.wikidata_housekeeping("Category:Rivers", quality.wikidata_description({"title": "Category:Rivers", "summary": "Category:Rivers: Wikimedia category."}))

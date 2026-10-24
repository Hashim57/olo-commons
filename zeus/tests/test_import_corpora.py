"""Unit tests for zeus/import_corpora.py. Run with: python3 -m pytest zeus/tests
No network: rows are shaped like VitaminC lines."""
import os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import import_corpora as ic  # noqa: E402
import validate_gold as vg  # noqa: E402


def row(i, label="SUPPORTS", page=None, claim=None, evidence=None, case=None, rtype="real"):
    return {"unique_id": f"case{i}_{label[:3]}", "case_id": case or f"case{i}", "wiki_revision_id": str(1000 + i), "label": label,
            "claim": claim or f"Town number {i} had a population of more than 540,000 in 2017 .",
            "evidence": evidence or f"Town number {i} ( ) is a city in England , with a population of 545,500 as of 2017 ( 5th most populous district ) .",
            "page": page or f"Town {i} -LRB-England-RRB-", "revision_type": rtype}


ROWS = [row(i, l) for i in range(30) for l in ("SUPPORTS", "REFUTES", "NOT ENOUGH INFO")]


def test_detok_and_page_name():
    assert ic.detok("Dragon Con had less than 1000 guests .") == "Dragon Con had less than 1000 guests."
    assert ic.detok("certified ( BPI ) , for $ 554.9 million , it 's fine") == "certified (BPI), for $554.9 million, it's fine"
    assert ic.page_name("Puss in Boots -LRB-2011 film-RRB-") == "Puss in Boots (2011 film)"
    assert ic.page_name(None) == ""


def test_quote_is_an_exact_substring_cut_at_a_word():
    text = "word " * 60
    q = ic.quote_of(text.strip())
    assert q in text and len(q) <= 160 and not q.endswith(" ")
    assert ic.quote_of("short text") == "short text"


def test_to_example_maps_labels_and_keeps_provenance():
    rng = random.Random(1)
    ex = ic.to_example(row(1, "REFUTES"), ROWS, rng)
    assert ex["label"] == "contradicted"
    assert len(ex["passages"]) == 3
    main = [p for p in ex["passages"] if p["id"] == ic.passage_id("case1_REF")][0]
    assert main["url"] == "https://en.wikipedia.org/w/index.php?title=Town_1_(England)&oldid=1001"
    assert main["title"] == "Town 1 (England)"
    assert ex["evidence"][0]["passage"] == main["id"] and ex["evidence"][0]["quote"] in main["text"]
    assert ex["licence"] == "CC BY-SA 3.0" and ex["kind"] == "vitaminc:real"
    # distractors never come from the same page or case
    assert all(p["title"] != "Town 1 (England)" for p in ex["passages"] if p["id"] != main["id"])
    nc = ic.to_example(row(2, "NOT ENOUGH INFO"), ROWS, rng)
    assert nc["label"] == "not_covered" and nc["evidence"] == []
    assert ic.to_example(row(3, "WEIRD"), ROWS, rng) is None
    assert ic.to_example(row(4, claim="short"), ROWS, rng) is None


def test_convert_is_balanced_seeded_and_valid():
    a = ic.convert(ROWS, 30, seed=3)
    b = ic.convert(ROWS, 30, seed=3)
    assert [x["unique_id"] for x in a] == [x["unique_id"] for x in b]
    labels = [x["label"] for x in a]
    assert labels.count("supported") == labels.count("contradicted") == labels.count("not_covered") == 10
    for ex in a:
        assert vg.check_example(ex) == [], vg.check_example(ex)
    synth = [row(i, "SUPPORTS", rtype="synthetic") for i in range(40, 50)]
    only_real = ic.convert(ROWS + synth, 60, seed=3, real_only=True)
    assert all(x["kind"] == "vitaminc:real" for x in only_real)


def test_balanced_sample_handles_small_corpora():
    rng = random.Random(0)
    out = ic.balanced_sample([row(1, "SUPPORTS"), row(2, "SUPPORTS"), row(3, "REFUTES")], 10, rng)
    assert len(out) == 3

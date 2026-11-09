"""Unit tests for scripts/build_snapshot.py (no network): python3 -m pytest scripts/tests -q"""
import importlib.util
import pathlib

SPEC = importlib.util.spec_from_file_location("build_snapshot", pathlib.Path(__file__).resolve().parents[1] / "build_snapshot.py")
bs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bs)


def atom(i, **kw):
    a = {"id": f"id-{i}", "title": f"Atom {i}", "summary": "s" * 250, "content": "c" * 300, "url": f"https://example.org/{i}", "source": "wikipedia", "status": "candidate"}
    a.update(kw)
    return a


def test_an_atom_repeated_at_a_page_boundary_is_kept_once():
    seen = set()
    page1 = [atom(i) for i in range(3)]
    page2 = [atom(2), atom(3), atom(4)]  # page 2 starts on the atom page 1 ended on
    kept = bs.keep(page1, seen) + bs.keep(page2, seen)
    assert [a["id"] for a in kept] == ["id-0", "id-1", "id-2", "id-3", "id-4"]


def test_superseded_retracted_and_textless_atoms_stay_out():
    seen = set()
    batch = [atom(1, status="superseded"), atom(2, status="retracted"), atom(3, summary="", content=""), atom(4, url=""), atom(5, status="verified")]
    assert [a["id"] for a in bs.keep(batch, seen)] == ["id-5"]


def test_an_atom_without_an_id_is_keyed_by_url():
    seen = set()
    a = atom(1)
    del a["id"]
    assert len(bs.keep([a, dict(a)], seen)) == 1


def test_compact_prefers_the_summary_and_caps_the_text():
    row = bs.compact(atom(1, summary="A short one.", content="x" * 2000, observed_at="2026-11-03T00:56:45+00:00"))
    assert row[0] == "id-1" and row[1] == "Atom 1"
    assert row[2].startswith("A short one. x") and len(row[2]) == bs.TEXT_MAX
    assert row[-1] == "2026-11-03"
    long_summary = bs.compact(atom(2))
    assert long_summary[2] == "s" * 250


def test_compact_does_not_write_a_summary_that_starts_its_content_twice():
    desc = "Title: Arnhemsche courant Datum: 10-12-1814 Editie: Dag Plaats van uitgave: Arnhem Uitgever: C.A. Thieme Nummer: 147"
    # the connectors store a short description as both summary and content
    assert bs.compact(atom(1, summary=desc, content=desc))[2] == desc
    # ...and a longer one as summary = the first 600 characters of the content
    long = "We study coral reef recovery after bleaching. " * 20
    row = bs.compact(atom(2, summary=long[:150], content=long))
    assert row[2] == " ".join(long.split())[:bs.TEXT_MAX]
    # a summary that is not the start of the content is still followed by the content
    assert bs.compact(atom(3, summary="A short one.", content="Then the rest."))[2] == "A short one. Then the rest."


def test_compact_writes_a_wikidata_description_once():
    # sources.ts: summary "Label: description." and content "Label. description. Described in N Wikimedia projects."
    row = bs.compact(atom(1, source="wikidata", title="Kachari Kingdom", summary="Kachari Kingdom: kingdom in medieval Assam, Northeast India.",
                          content="Kachari Kingdom. kingdom in medieval Assam, Northeast India. Described in 13 Wikimedia projects."))
    assert row[2] == "Kachari Kingdom. kingdom in medieval Assam, Northeast India. Described in 13 Wikimedia projects."
    assert row[2].count("medieval Assam") == 1


def test_compact_keeps_a_summary_that_already_ends_with_its_content():
    # gutenberg without a book summary: "Title. Subjects: ..." beside "Subjects: ..."
    row = bs.compact(atom(1, source="gutenberg", summary="Villette. Subjects: Love stories; Women teachers -- Fiction", content="Subjects: Love stories; Women teachers -- Fiction"))
    assert row[2] == "Villette. Subjects: Love stories; Women teachers -- Fiction"
    # data_gov: "Dataset published by X. notes" beside "notes"
    notes = "Fiscal year 2026 budget information for Wake County, NC."
    assert bs.compact(atom(2, source="data_gov", summary="Dataset published by Wake County. " + notes, content=notes))[2] == "Dataset published by Wake County. " + notes


def test_compact_joins_a_partial_overlap_without_the_repeat():
    summary = "Dataset published by Ocean Protection Council. Ocean acidification and hypoxia monitoring project locations"
    content = "Ocean Acidification and Hypoxia monitoring project locations, compiled by council staff in 2019."
    assert bs.compact(atom(1, summary=summary, content=content))[2] == summary + " compiled by council staff in 2019."
    # fewer shared words than OVERLAP_MIN is a coincidence, not a repeat: both texts are kept whole
    assert bs.compact(atom(2, summary="Notes on the river.", content="The river rises in the hills."))[2] == "Notes on the river. The river rises in the hills."


def test_join_once_leaves_different_texts_alone():
    assert bs.join_once("A short one.", "Then the rest.") == "A short one. Then the rest."
    assert bs.join_once("", "Only content.") == "Only content."
    assert bs.join_once("Only a summary.", "") == "Only a summary."
    # punctuation-only content has no words to compare
    assert bs.join_once("A short one.", "...") == "A short one. ..."

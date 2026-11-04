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

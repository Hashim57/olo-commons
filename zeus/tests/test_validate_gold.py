"""Unit tests for zeus/validate_gold.py. Run with: python3 -m pytest zeus/tests
Also validates every gold file that is actually in the repository."""
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import validate_gold as vg  # noqa: E402

GOLD_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "gold")


def passage(pid, text, source="wikipedia"):
    return {"id": pid, "source": source, "url": f"https://example.org/{pid}", "text": text}


def good(label="supported"):
    ex = {"claim": "The library opened in 1902 and holds two million volumes.",
          "passages": [passage("a1", "The library opened in 1902. It holds more than two million volumes."), passage("b2", "The Danube flows east through ten countries.")],
          "label": label, "evidence": [{"passage": "a1", "quote": "The library opened in 1902"}], "rationale": "The first passage states it."}
    if label == "not_covered":
        ex["evidence"] = []
    return ex


def test_valid_examples_pass():
    assert vg.check_example(good()) == []
    assert vg.check_example(good("contradicted")) == []
    assert vg.check_example(good("not_covered")) == []


def test_missing_keys_and_bad_label():
    ex = good()
    del ex["rationale"]
    assert any("rationale" in p for p in vg.check_example(ex))
    ex = good()
    ex["label"] = "maybe"
    assert any("label" in p for p in vg.check_example(ex))
    assert vg.check_example("not an object") == ["line is not a JSON object"]


def test_evidence_must_quote_its_passage_exactly():
    ex = good()
    ex["evidence"][0]["quote"] = "The library opened in 1903"
    assert any("exact substring" in p for p in vg.check_example(ex))
    ex = good()
    ex["evidence"][0]["passage"] = "zz"
    assert any("not in passages" in p for p in vg.check_example(ex))
    ex = good()
    ex["evidence"] = []
    assert any("at least one evidence" in p for p in vg.check_example(ex))
    ex = good("not_covered")
    ex["evidence"] = [{"passage": "a1", "quote": "The library"}]
    assert any("empty evidence" in p for p in vg.check_example(ex))


def test_passages_need_provenance_and_unique_ids():
    ex = good()
    ex["passages"][1]["id"] = "a1"
    assert any("repeated" in p for p in vg.check_example(ex))
    ex = good()
    ex["passages"][1]["url"] = "http://example.org/x"
    assert any("not https" in p for p in vg.check_example(ex))
    ex = good()
    ex["passages"] = ex["passages"][:1]
    assert any("two passages" in p for p in vg.check_example(ex))
    ex = good()
    ex["passages"][0]["text"] = ""
    assert any("lacks text" in p for p in vg.check_example(ex))


def test_check_file_counts_and_reports(tmp_path):
    p = tmp_path / "g.jsonl"
    bad = good()
    bad["evidence"][0]["quote"] = "nope"
    p.write_text("\n".join([json.dumps(good()), "", "{not json", json.dumps(bad), json.dumps(good())]) + "\n", encoding="utf-8")
    n_ok, problems = vg.check_file(str(p))
    assert n_ok == 1
    assert any("line 3: not JSON" in m for m in problems)
    assert any("line 4" in m and "exact substring" in m for m in problems)
    assert any("line 5" in m and "already in this file" in m for m in problems)


def test_repository_gold_files_are_valid():
    if not os.path.isdir(GOLD_DIR):
        return
    for name in sorted(os.listdir(GOLD_DIR)):
        if name.endswith(".jsonl"):
            n_ok, problems = vg.check_file(os.path.join(GOLD_DIR, name))
            assert problems == [], problems
            assert n_ok > 0

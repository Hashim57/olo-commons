"""zeus/cloud/record.py: the build's train generators travel with the version. Run with: python3 -m pytest zeus/tests"""
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud"))
import record  # noqa: E402


def test_note_generators_copies_meta_into_the_summary_once(tmp_path):
    summary = tmp_path / "train_summary.json"
    summary.write_text(json.dumps({"base": "b", "train_examples": 100}))
    meta = tmp_path / "meta.json"
    meta.write_text(json.dumps({"train_total": 100, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}))
    s = json.load(open(summary))
    assert record.note_generators(str(summary), s, str(meta)) == ["rules-v1", "hard-v1", "compose-v1"]
    assert json.load(open(summary))["train_generators"] == ["rules-v1", "hard-v1", "compose-v1"]
    # a summary that already names its generators keeps them, whatever today's meta says
    meta.write_text(json.dumps({"train_generators": ["rules-v1"]}))
    assert record.note_generators(str(summary), json.load(open(summary)), str(meta)) == ["rules-v1", "hard-v1", "compose-v1"]


def test_note_generators_leaves_a_summary_alone_without_meta(tmp_path):
    summary = tmp_path / "train_summary.json"
    summary.write_text(json.dumps({"base": "b"}))
    assert record.note_generators(str(summary), {"base": "b"}, str(tmp_path / "missing.json")) is None
    assert json.load(open(summary)) == {"base": "b"}

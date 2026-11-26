"""Tests for scripts/verify_receipt.py (no network): python3 -m pytest scripts/tests -q"""
import copy, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import verify_receipt as vr  # noqa: E402

FIXTURE = json.load(open(os.path.join(ROOT, "tests", "fixtures", "receipt.json"), encoding="utf-8"))
# The two atoms as the public olo_atom RPC returned them on 26 November 2026.
ATOMS = json.load(open(os.path.join(ROOT, "tests", "fixtures", "receipt_atoms.json"), encoding="utf-8"))


def by(results, check):
    return [r for r in results if r[0] == check]


def test_the_seal_written_by_receipt_ts_is_recomputed_byte_for_byte_in_python():
    assert vr.receipt_sha256(FIXTURE) == FIXTURE["receipt_sha256"]
    assert all(ok for _, ok, _ in vr.verify(FIXTURE, None))


def test_a_live_receipt_over_unchanged_atoms_passes_every_check():
    res = vr.verify(FIXTURE, lambda aid: ATOMS[aid])
    assert all(ok for _, ok, _ in res), [r for r in res if not r[1]]
    assert len(by(res, "unchanged")) == 2 and len(by(res, "quoted")) == 2 and len(by(res, "licensed")) == 2


def test_an_edited_receipt_is_caught():
    r = copy.deepcopy(FIXTURE)
    r["sentences"][1]["verdict"] = "supported"
    (check, ok, msg), = by(vr.verify(r, None), "intact")
    assert not ok and "edited" in msg


def test_a_changed_or_removed_atom_is_named():
    changed = copy.deepcopy(ATOMS)
    first = FIXTURE["atoms"][0]["atom"]
    changed[first]["content_hash"] = "0" * 64
    res = vr.verify(FIXTURE, lambda aid: changed[aid])
    assert [ok for _, ok, _ in by(res, "unchanged")] == [False, True]
    res = vr.verify(FIXTURE, lambda aid: None if aid == first else ATOMS[aid])
    assert "no longer in the Commons" in by(res, "unchanged")[0][2]


def test_a_quote_the_atom_does_not_contain_fails_even_when_the_seal_is_redone():
    r = copy.deepcopy(FIXTURE)
    r["sentences"][0]["evidence"][0]["quote"] = "killing 94 people on board"
    r["receipt_sha256"] = vr.receipt_sha256(r)  # a forger can reseal; the quote check still reads the Commons
    res = vr.verify(r, lambda aid: ATOMS[aid])
    assert by(res, "intact")[0][1]
    assert not by(res, "quoted")[0][1]


def test_quotes_read_the_way_olo_answer_reads_them():
    assert vr.quote_key("Hartsfield" + chr(0x2013) + "Jackson  International Airport.") == "hartsfield-jackson international airport"
    assert vr.quote_key("10× faster") == "10x faster"
    assert vr.canonical_json({"b": 1, "a": [{"d": None, "c": "é \"x\""}, True]}) == '{"a":[{"c":"é \\"x\\"","d":null},true],"b":1}'


def test_floats_and_unknown_formats_are_refused():
    r = copy.deepcopy(FIXTURE)
    r["format"] = "something-else"
    assert vr.verify(r, None)[0][1] is False
    try:
        vr.canonical_json({"x": 0.5})
        raise AssertionError("a float was accepted")
    except ValueError:
        pass


def test_the_command_line_reads_a_whole_response_and_exits_with_the_result(tmp_path, capsys):
    p = tmp_path / "answer.json"
    p.write_text(json.dumps({"q": "x", "receipt": FIXTURE}), encoding="utf-8")
    assert vr.main([str(p), "--offline"]) == 0
    assert "checks hold" in capsys.readouterr().out
    bad = copy.deepcopy(FIXTURE); bad["answer_shown"] += "!"
    p.write_text(json.dumps(bad), encoding="utf-8")
    assert vr.main([str(p), "--offline"]) == 1
    p.write_text("not json", encoding="utf-8")
    assert vr.main([str(p), "--offline"]) == 2


SUPPLIED = json.load(open(os.path.join(ROOT, "tests", "fixtures", "receipt_supplied.json"), encoding="utf-8"))
REQUEST = json.load(open(os.path.join(ROOT, "tests", "fixtures", "check_request.json"), encoding="utf-8"))


def test_a_check_receipt_over_your_own_passages_is_matched_to_them_by_fingerprint():
    res = vr.verify(SUPPLIED, None, REQUEST["passages"])
    assert all(ok for _, ok, _ in res), [r for r in res if not r[1]]
    assert len(by(res, "supplied")) == 4  # two fingerprints, two quotes


def test_without_the_passages_the_quotes_are_skipped_not_failed():
    res = vr.verify(SUPPLIED, None, None)
    assert [ok for _, ok, _ in by(res, "supplied")] == [None, None]
    assert by(res, "intact")[0][1]


def test_a_different_passage_than_the_one_checked_is_caught():
    changed = copy.deepcopy(REQUEST["passages"])
    changed[1] = changed[1].replace("4.1 million", "41 million")
    res = vr.verify(SUPPLIED, None, changed)
    assert [ok for _, ok, _ in by(res, "supplied")][:2] == [True, False]


def test_the_command_line_takes_the_request_body_as_supplied(tmp_path):
    r, q = tmp_path / "r.json", tmp_path / "q.json"
    r.write_text(json.dumps(SUPPLIED), encoding="utf-8")
    q.write_text(json.dumps(REQUEST), encoding="utf-8")
    assert vr.main([str(r), "--offline", "--supplied", str(q)]) == 0
    assert vr.main([str(r), "--offline"]) == 0  # skipped lines are not failures

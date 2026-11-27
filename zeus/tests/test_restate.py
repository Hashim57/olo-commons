"""Unit tests for the restate-v1 train examples (zeus/restate.py). No network."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import restate  # noqa: E402


def _row(claim, passage=None, generator=None):
    text = passage or claim
    ex = {"claim": claim, "label": "supported", "passages": [{"id": "a1", "source": "wikipedia", "text": "Unrelated passage."}, {"id": "b2", "source": "wikinews", "text": text}],
          "evidence": [{"passage": "b2", "quote": claim}], "rationale": "The passage states the claim directly."}
    if generator:
        ex["generator"] = generator
    return ex


def test_each_rule_writes_the_same_fact_another_way():
    r = dict(restate.restatements("It was held on 1 January 2016, at the Landmark Events Centre."))
    assert r["restate_date"] == "It was held on January 1, 2016, at the Landmark Events Centre."
    assert dict(restate.restatements("It was removed on August 20, 2008, for repairs."))["restate_date"] == "It was removed on 20 August 2008, for repairs."
    assert dict(restate.restatements("Turnout reached almost 95% of registered voters."))["restate_percent"] == "Turnout reached almost 95 percent of registered voters."
    assert dict(restate.restatements("A bid for a 24 per cent stake was turned down."))["restate_percent"] == "A bid for a 24% stake was turned down."
    assert dict(restate.restatements("Some 10,000 protesters gathered on the square."))["restate_thousands"] == "Some 10000 protesters gathered on the square."
    assert dict(restate.restatements("It is the fifth film in the series, and stars Piggy."))["restate_ordinal"] == "It is the 5th film in the series, and stars Piggy."
    assert dict(restate.restatements("Eight trials comprising 636 participants were included."))["restate_count"] == "8 trials comprising 636 participants were included."
    assert dict(restate.restatements("Obstructive sleep apnoea (OSA) is characterised by the index."))["restate_aside"] == "Obstructive sleep apnoea is characterised by the index."


def test_rules_leave_alone_what_they_cannot_rewrite_safely():
    assert restate.restatements("He came second in the first race.") == [], "first and second are not touched (second is also a unit)"
    assert "restate_thousands" not in dict(restate.restatements("The figure was 1,234,567 in total."))
    assert "restate_count" not in dict(restate.restatements("One of the two was chosen."))
    assert "restate_aside" not in dict(restate.restatements("X (y)."))  # what would be left is too short


def test_only_plain_rule_made_supported_rows_are_restated_and_the_source_rows_stay():
    train = [_row("It is the fifth film in the Merrie Melodies series, and stars Piggy."),
             _row("It is the fifth film in the series.", generator="hard-v2"),
             dict(_row("It is the fifth film in the series, made in 1931."), label="contradicted")]
    added = restate.add_restated(train)
    assert len(added) == 1 and len(train) == 4
    new = added[0]
    assert new["claim"] == "It is the 5th film in the Merrie Melodies series, and stars Piggy."
    assert (new["label"], new["generator"], new["kind"]) == ("supported", restate.RESTATE_VERSION, "restate_ordinal")
    assert new["evidence"] == train[0]["evidence"], "the evidence still quotes the passage's own words"
    assert new["evidence"][0]["quote"] in new["passages"][1]["text"]
    assert new["claim"] not in new["passages"][1]["text"], "the claim is no longer word for word in the passage"


def test_a_rewrite_the_passage_already_contains_is_not_used():
    passage = "It is the fifth film in the series. It is the 5th film in the series."
    assert restate.add_restated([_row("It is the fifth film in the series.", passage=passage)]) == []


def test_the_aside_rule_is_preferred_last_and_capped():
    rows = [_row(f"Person {i}: association football player (born 19{i % 90 + 10}).") for i in range(400)]
    added = restate.add_restated(rows)
    assert sum(1 for r in added if r["kind"] == "restate_aside") == restate.MAX_ASIDE
    both = restate.add_restated([_row("Ten (or so) players won 24% of the matches played.")])
    assert both[0]["kind"] != "restate_aside", "a rewrite that changes how a fact is written comes first"


def test_the_same_seed_gives_the_same_rows():
    mk = lambda: [_row("Some 10,000 protesters gathered on 1 January 2016 for the fifth time.")]
    assert restate.add_restated(mk(), seed=4) == restate.add_restated(mk(), seed=4)


def test_main_keeps_eval_files_identical_and_no_restate_reproduces_train(tmp_path):
    import json, subprocess
    import test_longdoc as tl  # its synthetic atoms
    a = tl.atoms(400)
    for i, x in enumerate(a):  # give some atoms a figure a rule can rewrite
        x["summary"] = x["summary"].rstrip(".") + f", with {i % 9 + 2},000 visitors on 1 January 20{i % 20 + 10}."
    snap = {"v": 1, "fields": ["id", "title", "text", "url", "source", "licence", "published_at"],
            "atoms": [[x["id"], x["title"], x["summary"], x["url"], x["source"], "CC BY-SA 4.0", "2026-10-01"] for x in a]}
    sp = tmp_path / "commons.json"
    sp.write_text(json.dumps(snap))
    script = os.path.join(os.path.dirname(__file__), "..", "build_dataset.py")
    outs = {}
    for name, extra in (("on", ["--no-bound"]), ("off", ["--no-restate", "--no-bound"])):
        out = tmp_path / name
        subprocess.run([sys.executable, script, "--snapshot", str(sp), "--out", str(out), "--eval-share", "0.2"] + extra, check=True, capture_output=True)
        outs[name] = out
    for f in ("eval.jsonl", "eval2.jsonl", "eval3.jsonl"):
        assert (outs["on"] / f).read_bytes() == (outs["off"] / f).read_bytes()
    on = [json.loads(l) for l in (outs["on"] / "train.jsonl").read_text().splitlines()]
    off = [json.loads(l) for l in (outs["off"] / "train.jsonl").read_text().splitlines()]
    assert on[: len(off)] == off, "restate-v1 only appends"
    assert all(x.get("generator") == restate.RESTATE_VERSION and x["label"] == "supported" for x in on[len(off):])
    meta = json.loads((outs["on"] / "meta.json").read_text())
    assert meta["train_generators"][-1] == restate.RESTATE_VERSION
    assert sum(meta["train_restated_by_kind"].values()) == len(on) - len(off) > 0

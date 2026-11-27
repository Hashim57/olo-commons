"""Unit tests for zeus/promote.py and the card in zeus/publish.py. Run with: python3 -m pytest zeus/tests"""
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import promote  # noqa: E402
import publish  # noqa: E402

STATUS = """# Zeus status

| Date | Version | Base | Train examples | Label acc | Evidence hit | Notes |
|---|---|---|---|---|---|---|
| 2026-10-01 | v0 | mlx-community/Qwen2.5-1.5B-Instruct-4bit | 1,200 | 0.71 | 0.62 | first run |
| 2026-10-10 | v2 | mlx-community/Qwen2.5-1.5B-Instruct-4bit | 2,400 | 0.80 | 0.75 | more data |
| 2026-10-24 | v5 | mlx-community/Qwen2.5-1.5B-Instruct-4bit | 3,882 (10 gold) | 0.835 | 0.81 | gold set |
| 2026-10-12 | v3 | mlx-community/Qwen2.5-1.5B-Instruct-4bit | 2,600 | not measured | not measured | crashed |
"""


def write_out(tmp_path, version, acc, hit):
    d = tmp_path / "out" / f"zeus-{version}"
    d.mkdir(parents=True)
    (d / "eval.json").write_text(json.dumps({"base": "b", "n": 200, "label_accuracy": acc, "evidence_hit": hit, "json_valid": 0.99,
                                             "f1": {"supported": 0.8, "contradicted": 0.7, "not_covered": 0.9}}))
    return d


def test_measured_rows_skips_unmeasured(tmp_path):
    p = tmp_path / "STATUS.md"
    p.write_text(STATUS)
    rows = promote.measured_rows(str(p))
    assert sorted(rows) == ["v0", "v2", "v5"]
    assert rows["v5"]["label_accuracy"] == 0.835 and rows["v5"]["train_examples"] == "3,882 (10 gold)"
    assert promote.measured_rows(str(tmp_path / "missing.md")) == {}


def test_candidates_need_eval_json(tmp_path):
    p = tmp_path / "STATUS.md"
    p.write_text(STATUS)
    write_out(tmp_path, "v2", 0.80, 0.75)
    write_out(tmp_path, "v5", 0.835, 0.81)
    cands = promote.candidates(str(tmp_path / "out"), promote.measured_rows(str(p)))
    assert sorted(c["version"] for c in cands) == ["v2", "v5"]
    assert promote.choose(cands)["version"] == "v5"


def test_choose_never_demotes_unless_forced():
    cands = [{"version": "v4", "label_accuracy": 0.85, "evidence_hit": 0.80},
             {"version": "v5", "label_accuracy": 0.83, "evidence_hit": 0.81}]
    current = {"version": "v4"}
    assert promote.choose(cands, current)["version"] == "v4"
    assert promote.choose(cands, current, force=True)["version"] == "v4"  # force still picks the best by score
    # a newer version with equal scores wins the tie
    tie = [{"version": "v4", "label_accuracy": 0.85, "evidence_hit": 0.80},
           {"version": "v6", "label_accuracy": 0.85, "evidence_hit": 0.80}]
    assert promote.choose(tie, current)["version"] == "v6"
    # the current version no longer on disk cannot block a promotion
    assert promote.choose(cands, {"version": "v9"})["version"] == "v4"
    assert promote.choose([], current) is None


def test_model_card_uses_measured_numbers_only(tmp_path):
    ev = json.loads((write_out(tmp_path, "v5", 0.835, 0.81) / "eval.json").read_text())
    card = publish.model_card("v5", ev, {"iters": 600, "minutes": 38.2, "train_examples": 3882}, {"date": "2026-10-24", "base": "b"}, "gold set")
    assert "| Label accuracy | 0.835 |" in card and "| Evidence hit" in card and "0.81" in card
    assert "600 iterations" in card and "2026-10-24" in card and "gold set" in card
    assert "adapter_path='zeus/out/zeus-v5'" in card
    assert chr(0x2014) not in card and chr(0x2013) not in card
    with_repo = publish.model_card("v5", ev, {}, None, "", upload_repo="helius/zeus")
    assert 'load("helius/zeus")' in with_repo


def test_status_notes_reads_the_notes_cell(tmp_path):
    p = tmp_path / "STATUS.md"
    p.write_text(STATUS)
    assert publish.status_notes(str(p), "v5") == "gold set"
    assert publish.status_notes(str(p), "v7") == ""


def test_cloudflare_pick_is_the_best_mistral_version_and_never_demoted():
    cands = [{"version": "v5", "base": "mlx-community/Qwen2.5-1.5B-Instruct-4bit", "label_accuracy": 0.84, "evidence_hit": 0.81},
             {"version": "v6", "base": "mlx-community/Mistral-7B-Instruct-v0.2-4bit", "label_accuracy": 0.80, "evidence_hit": 0.78},
             {"version": "v7", "base": "mlx-community/Mistral-7B-Instruct-v0.2-4bit", "label_accuracy": 0.79, "evidence_hit": 0.80}]
    cf = [c for c in cands if promote.cloudflare_servable(c)]
    assert [c["version"] for c in cf] == ["v6", "v7"]
    assert promote.choose(cf)["version"] == "v6"
    assert promote.choose(cf, {"version": "v6"})["version"] == "v6"
    assert promote.choose(cands)["version"] == "v5"  # the overall best can stay a version Cloudflare cannot serve


def test_best_carries_the_train_generators_of_the_chosen_version(tmp_path):
    p = tmp_path / "STATUS.md"
    p.write_text(STATUS)
    write_out(tmp_path, "v2", 0.80, 0.75)
    d = write_out(tmp_path, "v5", 0.835, 0.81)
    (d / "train_summary.json").write_text(json.dumps({"base": "b", "train_examples": 3882, "train_generators": ["rules-v1", "hard-v1"]}))
    cands = {c["version"]: c for c in promote.candidates(str(tmp_path / "out"), promote.measured_rows(str(p)))}
    assert cands["v5"]["train_generators"] == ["rules-v1", "hard-v1"]
    assert "train_generators" not in cands["v2"]  # no train_summary.json: the key is left out, not invented


def test_above_the_floor_held_out_claims_decide_not_one_answer_on_the_frozen_split():
    v16 = {"version": "v16", "label_accuracy": 1.0, "evidence_hit": 1.0, "held_out_accuracy": 0.717, "eval3_accuracy": 0.66}
    v22 = {"version": "v22", "label_accuracy": 0.995, "evidence_hit": 0.995, "held_out_accuracy": 0.733, "eval3_accuracy": 0.92}
    assert promote.choose([v16, v22], {"version": "v16"})["version"] == "v22"
    # below the floor a better held-out score does not win
    weak = {"version": "v30", "label_accuracy": 0.95, "evidence_hit": 0.95, "held_out_accuracy": 0.90, "eval3_accuracy": 0.95}
    assert promote.choose([v22, weak], {"version": "v22"})["version"] == "v22"
    # equal VitaminC: the hard patterns decide
    v23 = dict(v22, version="v23", eval3_accuracy=0.95)
    assert promote.choose([v22, v23])["version"] == "v23"


def test_the_repository_promotes_the_best_held_out_version_above_the_floor():
    import os
    zeus = os.path.join(os.path.dirname(__file__), "..")
    cands = promote.candidates(os.path.join(zeus, "out"), promote.measured_rows(os.path.join(zeus, "STATUS.md")))
    cf = [c for c in cands if promote.cloudflare_servable(c)]
    above = [c for c in cf if c["label_accuracy"] >= promote.FROZEN_FLOOR and c.get("held_out_accuracy") is not None]
    pick = promote.choose(cf, {"version": "v16"})
    assert pick["held_out_accuracy"] == max(c["held_out_accuracy"] for c in above)
    assert pick["version"] != "v16", "v22 (and any later version better on held-out claims) outranks v16"


def test_the_honest_score_leaves_out_the_malformed_name_edits_exactly():
    # v31 as measured: 0.915 on 200, name_malformed 0.118 on 17 (2 right): 183 - 15 = 181 of 183 right
    ev = {"n": 200, "label_accuracy": 0.915, "by_edit": {"name_malformed": {"n": 17, "accuracy": 0.118}}}
    assert promote.well_formed_accuracy(ev) == 0.989
    assert promote.well_formed_accuracy({"n": 200, "label_accuracy": 0.925, "well_formed": {"label_accuracy": 0.984}}) == 0.984
    assert promote.well_formed_accuracy({"n": 200, "label_accuracy": 0.995}) == 0.995, "older versions: the headline"


def test_a_version_below_the_old_floor_clears_it_on_the_honest_score():
    v31 = {"version": "v31", "label_accuracy": 0.915, "well_formed_accuracy": 0.989, "evidence_hit": 0.915, "held_out_accuracy": 0.637, "eval3_accuracy": 0.965}
    weak = {"version": "v28", "label_accuracy": 0.965, "well_formed_accuracy": 0.965, "evidence_hit": 0.965, "held_out_accuracy": 0.9, "eval3_accuracy": 0.97}
    assert promote.rank_key(v31)[0] is True and promote.rank_key(weak)[0] is False
    assert promote.choose([v31, weak])["version"] == "v31"


def test_a_hand_promotion_is_kept_until_a_later_version_outranks_it():
    v22 = {"version": "v22", "label_accuracy": 0.995, "evidence_hit": 0.995, "held_out_accuracy": 0.733, "eval3_accuracy": 0.92}
    v31 = {"version": "v31", "label_accuracy": 0.915, "well_formed_accuracy": 0.989, "evidence_hit": 0.915, "held_out_accuracy": 0.637, "eval3_accuracy": 0.965}
    pinned = {"version": "v31", "pinned": {"version": "v31", "by": "hand", "reason": "r"}}
    assert promote.choose([v22, v31], {"version": "v22"})["version"] == "v22", "the rule alone keeps v22"
    assert promote.choose([v22, v31], pinned)["version"] == "v31", "an older version cannot undo the hand choice"
    v33 = dict(v31, version="v33", held_out_accuracy=0.70)
    assert promote.choose([v22, v31, v33], pinned)["version"] == "v33", "a later version that outranks it does"
    v34 = dict(v31, version="v34", held_out_accuracy=0.60)
    assert promote.choose([v22, v31, v34], pinned)["version"] == "v31", "a later version that does not, does not"
    assert promote.choose([v22, v31], pinned, force=True)["version"] == "v22", "--force ignores the pin"


def test_the_command_line_promotes_by_hand_only_a_measured_version_with_a_reason(tmp_path, monkeypatch):
    import subprocess, sys, os, shutil
    zeus = os.path.join(os.path.dirname(__file__), "..")
    best = tmp_path / "BEST.json"
    shutil.copy(os.path.join(zeus, "BEST.json"), best)
    run = lambda *a: subprocess.run([sys.executable, os.path.join(zeus, "promote.py"), "--best", str(best), *a], capture_output=True, text=True)
    assert run("--version", "v31").returncode != 0, "a reason is required"
    assert run("--version", "v999", "--reason", "x").returncode != 0, "an unmeasured version is refused"
    r = run("--version", "v31", "--reason", "Hashim's decision")
    assert r.returncode == 0, r.stderr
    b = json.loads(best.read_text())
    assert b["version"] == "v31" and b["cloudflare"]["version"] == "v31"
    assert b["pinned"]["version"] == "v31" and b["pinned"]["reason"] == "Hashim's decision"
    # a later automatic run keeps it
    assert run().returncode == 0
    assert json.loads(best.read_text())["version"] == "v31"


def test_a_version_that_fails_in_olo_answers_form_cannot_be_promoted_however_well_it_reads_the_stored_split():
    v22 = {"version": "v22", "label_accuracy": 0.995, "evidence_hit": 0.995, "held_out_accuracy": 0.733, "eval3_accuracy": 0.92}
    broken = {"version": "v40", "label_accuracy": 0.99, "well_formed_accuracy": 0.99, "evidence_hit": 0.99, "held_out_accuracy": 0.80, "eval3_accuracy": 0.97, "serving_accuracy": 0.55}
    good = dict(broken, version="v41", serving_accuracy=0.97)
    assert promote.rank_key(broken)[0] is False
    assert promote.choose([v22, broken])["version"] == "v22"
    assert promote.choose([v22, broken, good])["version"] == "v41"

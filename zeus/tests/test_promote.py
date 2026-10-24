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

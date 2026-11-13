"""zeus/cloud/recipe.py: the cloud recipe trains exactly what the Zeus Worker serves."""
import os, sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import recipe  # noqa: E402
import promote  # noqa: E402
import train_lora  # noqa: E402

EX = {"claim": "Gutenberg was founded in 1971.", "passages": [{"id": "p1", "source": "wikipedia", "text": "Founded in 1971 by Hart."}],
      "label": "supported", "evidence": [{"passage": "p1", "quote": "Founded in 1971"}], "rationale": "Stated."}


def test_prompt_is_one_user_turn_with_the_system_prompt_folded_in():
    m = recipe.prompt_messages(EX)
    assert len(m) == 1 and m[0]["role"] == "user"
    assert m[0]["content"].startswith(recipe.SYSTEM + "\n\nClaim: Gutenberg")
    assert recipe.SYSTEM == train_lora.SYSTEM  # one prompt across Mac, cloud, Worker and olo-answer


def test_labels_mask_the_prompt_and_keep_the_answer_whole():
    ids, labels = recipe.mask_labels([1, 2, 3, 4], [9, 9, 2], max_len=10)
    assert ids == [1, 2, 3, 4, 9, 9, 2] and labels == [-100] * 4 + [9, 9, 2]
    ids, labels = recipe.mask_labels(list(range(100)), [7, 8], max_len=6)
    assert ids == [96, 97, 98, 99, 7, 8] and labels == [-100] * 4 + [7, 8]


def test_adapter_config_is_what_cloudflare_accepts():
    cfg = recipe.peft_config_for_cloudflare({"r": 8, "lora_alpha": 16, "target_modules": {"v_proj", "q_proj"}, "peft_type": "LORA"})
    assert cfg["model_type"] == "mistral" and cfg["target_modules"] == ["q_proj", "v_proj"]
    assert recipe.LORA["r"] <= recipe.CF_MAX_RANK
    with pytest.raises(ValueError):
        recipe.peft_config_for_cloudflare({"r": 64})


def test_status_row_is_parsed_by_promote(tmp_path):
    row = recipe.status_row("2026-10-25", "v6", "mistralai/Mistral-7B-Instruct-v0.2", "4,100", {"n": 200, "label_accuracy": 0.86, "evidence_hit": 0.82, "json_valid": 0.99, "f1": {}}, 41.0, "A100-40GB")
    p = tmp_path / "STATUS.md"
    p.write_text("| Date | Version |\n|---|---|\n" + row + "\n")
    r = promote.measured_rows(str(p))["v6"]
    assert r["label_accuracy"] == 0.86 and r["evidence_hit"] == 0.82
    assert promote.cloudflare_servable({"base": r["base"]})


def test_steps_within_budget_fits_the_plan_to_the_hour():
    # pace not yet measured, or no budget: the plan stands
    assert recipe.steps_within_budget(10, 100.0, 2000, 3600) == 2000
    assert recipe.steps_within_budget(20, 100.0, 2000, 0) == 2000
    assert recipe.steps_within_budget(20, 0.0, 2000, 3600) == 2000
    # 20 steps in 100 s is 5 s a step: 720 steps fit an hour, so a plan of 2000 is cut to 720
    assert recipe.steps_within_budget(20, 100.0, 2000, 3600) == 720
    # a plan that fits is kept whole
    assert recipe.steps_within_budget(20, 100.0, 600, 3600) == 600
    # never below the steps already done plus one, so the loop ends cleanly
    assert recipe.steps_within_budget(100, 7200.0, 2000, 3600) == 101
    assert recipe.TRAIN_BUDGET_MINUTES == 60


def test_status_row_notes_a_time_capped_run():
    ev = {"n": 200, "json_valid": 1.0, "label_accuracy": 0.99, "evidence_hit": 0.98, "f1": {"supported": 1.0, "contradicted": 0.98, "not_covered": 1.0}}
    summary = {"time_capped": True, "time_budget_minutes": 60, "steps": 720, "planned_steps": 2142, "examples_seen": 11520}
    row = recipe.status_row("2026-11-14", "v20", "mistralai/Mistral-7B-Instruct-v0.2", "34,474", ev, 61.2, "A100-40GB", summary)
    assert "Time budget 60 min: 720 of 2142 planned steps, about 11,520 examples seen." in row
    assert "Time budget" not in recipe.status_row("2026-11-14", "v20", "b", "1", ev, 61.2, "A100-40GB", dict(summary, time_capped=False))
    assert "Time budget" not in recipe.status_row("2026-11-14", "v20", "b", "1", ev, 61.2, "A100-40GB")

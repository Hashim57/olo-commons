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


def test_shuffle_seed_differs_between_versions_and_holds_for_one():
    # reproducible for a version, so a run can be repeated
    assert recipe.shuffle_seed("v21") == recipe.shuffle_seed("v21")
    # different between versions, so two budgeted runs on the same rows see different parts of the set
    seeds = {recipe.shuffle_seed(f"v{n}") for n in range(20, 40)}
    assert len(seeds) == 20
    # a 32-bit value, what random.Random takes and train_summary.json records
    assert all(0 <= x < 2 ** 32 for x in seeds)
    # the constant 0 of v6 to v20 is not among them, so the record shows which runs had the rotation
    assert 0 not in seeds


def test_status_row_notes_a_time_capped_run():
    ev = {"n": 200, "json_valid": 1.0, "label_accuracy": 0.99, "evidence_hit": 0.98, "f1": {"supported": 1.0, "contradicted": 0.98, "not_covered": 1.0}}
    summary = {"time_capped": True, "time_budget_minutes": 60, "steps": 720, "planned_steps": 2142, "examples_seen": 11520}
    row = recipe.status_row("2026-11-14", "v20", "mistralai/Mistral-7B-Instruct-v0.2", "34,474", ev, 61.2, "A100-40GB", summary)
    assert "Time budget 60 min: 720 of 2142 planned steps, about 11,520 examples seen." in row
    assert "Gold and imported rows seen" not in row  # a summary written before the rows were ordered by priority
    with_priority = dict(summary, priority_rows=1742, priority_seen=1742, priority_front=0.4)
    assert "about 11,520 examples seen. Gold and imported rows seen: 1742 of 1742." in recipe.status_row("2026-11-15", "v21", "b", "1", ev, 61.2, "A100-40GB", with_priority)
    assert "Time budget" not in recipe.status_row("2026-11-14", "v20", "b", "1", ev, 61.2, "A100-40GB", dict(summary, time_capped=False))
    assert "Time budget" not in recipe.status_row("2026-11-14", "v20", "b", "1", ev, 61.2, "A100-40GB")


def test_budgeted_order_puts_every_gold_and_imported_row_inside_the_front_of_the_list():
    import random
    priority = [False] * 1000 + [True] * 50
    order = recipe.budgeted_order(priority, random.Random(3))
    assert sorted(order) == list(range(1050))  # a permutation: every row once
    front = order[: int(1050 * recipe.PRIORITY_FRONT)]
    assert sum(priority[i] for i in front) == 50  # all of them inside the budgeted part
    positions = [pos for pos, i in enumerate(order) if priority[i]]
    gaps = [b - a for a, b in zip(positions, positions[1:])]
    assert min(gaps) >= 7 and max(gaps) <= 9  # spread evenly (420 positions over 50 rows), never one block
    # the rule-made part differs between versions, the priority set does not
    other = recipe.budgeted_order(priority, random.Random(4))
    assert other != order and {i for i in other[:420] if priority[i]} == set(range(1000, 1050))


def test_budgeted_order_with_no_or_too_many_priority_rows():
    import random
    assert sorted(recipe.budgeted_order([False] * 10, random.Random(0))) == list(range(10))
    assert recipe.budgeted_order([], random.Random(0)) == []
    # more priority rows than the front holds: they take the first positions, and nothing is lost
    order = recipe.budgeted_order([True] * 8 + [False] * 2, random.Random(1))
    assert sorted(order) == list(range(10)) and all(i < 8 for i in order[:8])
    # all priority rows
    assert sorted(recipe.budgeted_order([True] * 5, random.Random(2))) == list(range(5))


def _row(claim, label="supported"):
    return {"claim": claim, "passages": [{"id": "p1", "source": "wikipedia", "text": claim + " text"}, {"id": "p2", "source": "wikipedia", "text": "other"}],
            "label": label, "evidence": [], "rationale": "r", "kind": "k"}


def test_mistakes_keep_only_wrong_answers_and_never_a_held_out_claim():
    rows = [_row("a"), _row("b", "contradicted"), _row("c"), _row("held")]
    answers = [{"label": "supported"}, {"label": "supported"}, None, {"label": "not_covered"}]
    m = recipe.mistakes_from(rows, answers, "v23", held_out_claims={"held"})
    assert [r["claim"] for r in m] == ["b", "c"]
    assert m[0]["mistake"] == {"version": "v23", "said": "supported", "key": recipe.example_key(rows[1])}
    assert m[1]["mistake"]["said"] == "invalid", "an answer that does not parse is a mistake"
    assert set(m[0]) == {"claim", "passages", "label", "evidence", "rationale", "kind", "mistake"}
    lic = recipe.mistakes_from([dict(_row("v"), licence="CC BY-SA 3.0", attribution="VitaminC")], [None], "v23")
    assert lic[0]["licence"] == "CC BY-SA 3.0" and lic[0]["attribution"] == "VitaminC", "an imported row keeps its licence"


def test_pool_puts_new_mistakes_first_dedupes_and_caps():
    old = recipe.mistakes_from([_row("x"), _row("y")], [{"label": "no"}, {"label": "no"}], "v22")
    new = recipe.mistakes_from([_row("y"), _row("z")], [{"label": "no"}, {"label": "no"}], "v23")
    pool = recipe.merge_pool(old, new)
    assert [r["claim"] for r in pool] == ["y", "z", "x"]
    assert pool[0]["mistake"]["version"] == "v23", "a repeated mistake carries its newest record"
    assert [r["claim"] for r in recipe.merge_pool(old, new, cap=2)] == ["y", "z"]


def test_probe_indices_are_reproducible_per_version_and_bounded():
    import random
    a = recipe.probe_indices(5000, random.Random(recipe.shuffle_seed("v23")), 100)
    b = recipe.probe_indices(5000, random.Random(recipe.shuffle_seed("v23")), 100)
    c = recipe.probe_indices(5000, random.Random(recipe.shuffle_seed("v24")), 100)
    assert a == b and a != c and len(a) == 100 and len(set(a)) == 100
    assert recipe.probe_indices(7, random.Random(0), 100) == list(range(7))


def test_focus_keeps_every_valuable_row_and_samples_the_easy_ones_by_label():
    import random
    from collections import Counter
    train = ([{"label": "supported"}] * 600 + [{"label": "not_covered"}] * 1200 + [{"label": "contradicted"}] * 200
             + [{"label": "supported", "generator": "hard-v1"}] * 500 + [{"label": "supported", "generator": "longdoc-v1"}] * 80
             + [{"label": "supported", "generator": "compose-v2"}] * 90 + [{"label": "contradicted"}] * 50)
    priority = [False] * (len(train) - 50) + [True] * 50
    keep = recipe.focus_indices(train, priority, random.Random(1), caps={"rules": 1000, "hard-v1": 100})
    groups = Counter(recipe.focus_group(train[i], priority[i]) for i in keep)
    assert groups == {"rules": 1000, "hard-v1": 100, "longdoc-v1": 80, "compose-v2": 90, "priority": 50}
    labels = Counter(train[i]["label"] for i in keep if recipe.focus_group(train[i], priority[i]) == "rules")
    assert labels == {"supported": 300, "not_covered": 600, "contradicted": 100}, "each label keeps its share"
    assert keep == sorted(keep) and len(set(keep)) == len(keep)


def test_focus_keeps_the_hedge_and_modal_hard_rows_whole():
    import random
    from collections import Counter
    train = ([{"label": "supported", "generator": "hard-v2", "kind": "hard_twin_supported"}] * 400
             + [{"label": "not_covered", "generator": "hard-v2", "kind": "hard_hedge_drop"}] * 30
             + [{"label": "not_covered", "generator": "hard-v2", "kind": "hard_modal_shift"}] * 20
             + [{"label": "not_covered", "generator": "hard-v2", "kind": "hard_scope_shift"}] * 100)
    priority = [False] * len(train)
    keep = recipe.focus_indices(train, priority, random.Random(3), caps={"hard-v2": 50})
    groups = Counter(recipe.focus_group(train[i], priority[i]) for i in keep)
    assert groups == {"hard-v2": 50, "hard-v2:hard_hedge_drop": 30, "hard-v2:hard_modal_shift": 20}
    assert "hard-v2" in recipe.FOCUS_CAPS and recipe.FOCUS_CAPS["hard-v2"] == recipe.FOCUS_CAPS["hard-v1"]


def test_focus_sample_differs_between_versions_and_holds_for_one():
    import random
    train = [{"label": "supported"}] * 3000
    pr = [False] * 3000
    a = recipe.focus_indices(train, pr, random.Random(recipe.shuffle_seed("v24")), caps={"rules": 500})
    b = recipe.focus_indices(train, pr, random.Random(recipe.shuffle_seed("v24")), caps={"rules": 500})
    c = recipe.focus_indices(train, pr, random.Random(recipe.shuffle_seed("v25")), caps={"rules": 500})
    assert a == b and a != c and len(a) == 500

"""The Zeus training recipe for the cloud GPU, as pure functions (no torch), so the
prompt format, the label masking and the Cloudflare constraints are tested in CI
without a GPU. zeus/cloud/modal_train.py uses these on the GPU.

The recipe matches what Cloudflare Workers AI serves: Mistral 7B Instruct v0.2
(Apache 2.0) at full precision, a LoRA adapter of rank 8 on q_proj and v_proj,
and the system prompt folded into the user turn (Mistral v0.2 has no system role).
"""
import json

BASES = ["mistralai/Mistral-7B-Instruct-v0.2", "unsloth/mistral-7b-instruct-v0.2"]  # the second is an ungated copy of the same weights
CLOUDFLARE_BASE = "@cf/mistral/mistral-7b-instruct-v0.2-lora"
LORA = {"r": 8, "lora_alpha": 16, "lora_dropout": 0.05, "target_modules": ["q_proj", "v_proj"], "bias": "none", "task_type": "CAUSAL_LM"}
CF_MAX_RANK = 32
CF_MAX_BYTES = 300 * 1024 * 1024

SYSTEM = ("You are Zeus, the verification layer of Olo. Given a claim and numbered passages, answer with one JSON object: "
          '{"label": "supported" | "contradicted" | "not_covered", "evidence": [{"passage": "<id>", "quote": "<exact words from that passage>"}], "rationale": "<one sentence>"}. '
          "Quote only words that appear in a passage. If no passage covers the claim, label not_covered with empty evidence.")


def render_user(ex):
    ps = "\n\n".join(f"[{p['id']}] ({p['source']}) {p['text']}" for p in ex["passages"])
    return f"Claim: {ex['claim']}\n\nPassages:\n{ps}"


def render_answer(ex):
    return json.dumps({"label": ex["label"], "evidence": ex["evidence"], "rationale": ex["rationale"]}, ensure_ascii=False)


def prompt_messages(ex):
    """One user turn carrying the system prompt: exactly what the Zeus Worker sends Cloudflare."""
    return [{"role": "user", "content": SYSTEM + "\n\n" + render_user(ex)}]


def mask_labels(prompt_ids, answer_ids, max_len):
    """input_ids and labels for one example: the prompt is context only (-100), the model learns the answer.
    Over-long examples are cut from the left of the prompt so the answer is always kept whole."""
    if len(answer_ids) >= max_len:
        answer_ids = answer_ids[: max_len - 1]
    room = max_len - len(answer_ids)
    prompt_ids = prompt_ids[-room:] if room > 0 else []
    input_ids = list(prompt_ids) + list(answer_ids)
    labels = [-100] * len(prompt_ids) + list(answer_ids)
    return input_ids, labels


def peft_config_for_cloudflare(cfg):
    """The adapter_config.json Cloudflare accepts: PEFT layout plus model_type, rank within its limit."""
    out = dict(cfg)
    out["model_type"] = "mistral"
    out["base_model_name_or_path"] = BASES[0]
    if int(out.get("r", 0)) > CF_MAX_RANK:
        raise ValueError(f"rank {out.get('r')} is above Cloudflare's limit of {CF_MAX_RANK}")
    tm = out.get("target_modules")
    if isinstance(tm, (set, tuple)):
        out["target_modules"] = sorted(tm)
    return out


def status_row(date, version, base, train_examples, ev, minutes, gpu, summary=None):
    """A STATUS.md table row from measured numbers only. With the train_summary.json of a time-capped run, the note
    says how many of the planned steps the hour allowed, so the examples column is read as the set, not the pass."""
    f1 = ev.get("f1") or {}
    capped = ""
    if summary and summary.get("time_capped"):
        capped = f" Time budget {summary.get('time_budget_minutes')} min: {summary.get('steps')} of {summary.get('planned_steps')} planned steps, about {summary.get('examples_seen'):,} examples seen."
    note = (f"Trained in the cloud ({gpu}, {minutes} min), not on the Mac.{capped} Eval n={ev.get('n')}, JSON valid {ev.get('json_valid')}, "
            f"F1 supported {f1.get('supported')} / contradicted {f1.get('contradicted')} / not covered {f1.get('not_covered')}.")
    if ev.get("binary_balanced_accuracy") is not None:
        note += f" Binary balanced accuracy (supported vs the rest, the LLM-AggreFact view) {ev['binary_balanced_accuracy']}."
    rates = ev.get("rates") or {}
    if rates.get("supported", {}).get("tpr") is not None:
        note += " TPR/TNR " + ", ".join(f"{l} {rates[l]['tpr']}/{rates[l]['tnr']}" for l in ("supported", "contradicted", "not_covered") if l in rates) + "."
    return f"| {date} | {version} | {base} | {train_examples} | {ev.get('label_accuracy')} | {ev.get('evidence_hit')} | {note} |"


# How long one training run may spend in the optimiser loop. Hashim asked (2026-11-13) for Zeus to
# train every day for about an hour, so the loop fits the hour rather than the data: at 32,000 examples one
# pass took about 90 of v19's 117 minutes on an A100, so a budgeted run sees roughly half to two thirds of
# the set (v20: 1,049 of 2,264 planned steps), a different part each day (shuffle_seed below), and the
# learning rate still decays to zero.
TRAIN_BUDGET_MINUTES = 60


def shuffle_seed(version):
    """The seed the trainer shuffles the training rows with: the first eight hex digits of the SHA-256 of the
    version name, so the order is reproducible for a version and different between versions. Until v20 the seed
    was the constant 0, which did not matter while a run saw the whole set once, but under the hour budget a run
    stops partway through the shuffled list, so with one seed two budgeted runs on the same rows would train on
    the same part of the set and never reach the rest. The order is recorded in train_summary.json as shuffle_seed."""
    import hashlib
    return int(hashlib.sha256(str(version).encode()).hexdigest()[:8], 16)


def steps_within_budget(steps_done, elapsed_s, planned_steps, budget_s, min_measured=20):
    """The number of optimiser steps a run should take so it finishes inside budget_s seconds, from how long
    the first steps_done steps took. The planned count stands when the pace is not yet measured (fewer than
    min_measured steps), when no budget is set, or when the whole plan fits; otherwise the pace is projected and
    the plan shortened, never below the steps already done plus one so the loop always ends cleanly."""
    if not budget_s or budget_s <= 0 or steps_done < min_measured or elapsed_s <= 0:
        return planned_steps
    per_step = elapsed_s / steps_done
    fit = int(budget_s / per_step)
    if fit >= planned_steps:
        return planned_steps
    return max(steps_done + 1, fit)

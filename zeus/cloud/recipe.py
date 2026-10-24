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


def status_row(date, version, base, train_examples, ev, minutes, gpu):
    """A STATUS.md table row from measured numbers only."""
    f1 = ev.get("f1") or {}
    note = (f"Trained in the cloud ({gpu}, {minutes} min), not on the Mac. Eval n={ev.get('n')}, JSON valid {ev.get('json_valid')}, "
            f"F1 supported {f1.get('supported')} / contradicted {f1.get('contradicted')} / not covered {f1.get('not_covered')}.")
    return f"| {date} | {version} | {base} | {train_examples} | {ev.get('label_accuracy')} | {ev.get('evidence_hit')} | {note} |"

"""The Zeus training recipe for the cloud GPU, as pure functions (no torch), so the
prompt format, the label masking and the Cloudflare constraints are tested in CI
without a GPU. zeus/cloud/modal_train.py uses these on the GPU.

The recipe matches what Cloudflare Workers AI serves: Mistral 7B Instruct v0.2
(Apache 2.0) at full precision, a LoRA adapter of rank 8 on q_proj and v_proj,
and the system prompt folded into the user turn (Mistral v0.2 has no system role).
"""
import json

BASES = ["mistralai/Mistral-7B-Instruct-v0.2", "unsloth/mistral-7b-instruct-v0.2"]  # the second is an ungated copy of the same weights
# The Hub commit each base is read at, so a run trains on the same files as every measured version. On
# 24 November 2026 at 08:18 UTC mistralai moved the chat template out of tokenizer_config.json into
# chat_template.jinja ("Add a response template (#243)", f34bdf28); transformers 4.46.3, which the cloud
# image pins, reads only the old key, so the tokenizer came back with no template and the v31 run failed at
# apply_chat_template before training started (run 40). 63a8b081 is the commit before that change, the one
# v6 to v30 trained on; the unsloth copy is pinned at its only commit for the same reason.
BASE_REVISIONS = {
    "mistralai/Mistral-7B-Instruct-v0.2": "63a8b081895390a26e140280378bc85ec8bce07a",
    "unsloth/mistral-7b-instruct-v0.2": "5d88c8e8dbf7446e665a3633b2f047689f4e6547",
}
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
        if summary.get("priority_rows"):
            capped += f" Gold and imported rows seen: {summary.get('priority_seen')} of {summary.get('priority_rows')}."
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


# The share of the shuffled list that holds every hand-written and imported example. v20, the first
# budgeted run, stopped after 46 percent of the list, so a plain shuffle would have left about half of
# the gold lines and of the VitaminC rows unseen by that version (and a different half by the next).
# They are the examples a rule cannot write and the ones the held-out sets are closest to, so a run
# that trains for an hour should see every one of them; the rule-made rows fill the rest of the order.
PRIORITY_FRONT = 0.4


def budgeted_order(priority, rng, front=PRIORITY_FRONT):
    """The order a budgeted run reads its training rows in. `priority` is one flag per row (True for a gold
    or imported row). Both groups are shuffled with `rng`, then the priority rows are spread at even
    intervals through the first `front` share of the list (or through as many positions as there are
    priority rows, when there are more), and the other rows fill the remaining positions in their shuffled
    order. So a run that stops after `front` of the list has still seen every priority row once, spaced
    among rule-made rows rather than in one block, and the rule-made part still differs between versions
    (the rng is seeded by the version). Every index appears exactly once."""
    first = [i for i, p in enumerate(priority) if p]
    rest = [i for i, p in enumerate(priority) if not p]
    rng.shuffle(first)
    rng.shuffle(rest)
    if not first:
        return rest
    n = len(priority)
    span = min(n, max(len(first), int(n * front)))
    targets = {int(j * span / len(first)) for j in range(len(first))}
    order, f, r = [], iter(first), iter(rest)
    for pos in range(n):
        order.append(next(f) if pos in targets else next(r))
    return order


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


# ---------------------------------------------------------------------------
# Learning from mistakes (since 2026-11-17). Every version trains from the base model, so what one version
# got wrong reaches the next only through the data. After training, a version answers a sample of its own
# training rows (never a held-out row); the ones it gets wrong go into zeus/data/mistakes/pool.jsonl, and the
# next version trains them as priority rows, so each of them is read twice (once in its usual place, once
# early in the order). The pool keeps the newest mistakes first and is capped, so a row the model has since
# learned ages out instead of being drilled for ever.
# ---------------------------------------------------------------------------
MISTAKE_PROBE_N = 800       # training rows a version answers after training, to find what it still gets wrong
MISTAKE_POOL_CAP = 2000     # rows kept in the pool; the oldest go first
MISTAKE_KEYS = ("claim", "passages", "label", "evidence", "rationale", "kind", "licence", "attribution")  # an imported row keeps its licence (VitaminC: CC BY-SA 3.0)


def example_key(ex):
    """A stable identity for a training row: the SHA-256 of its claim, label and passage texts. Two builds of
    the same row from the same atoms get the same key, so the pool never holds one mistake twice."""
    import hashlib
    texts = "\u0001".join(str(p.get("text", "")) for p in ex.get("passages") or [])
    return hashlib.sha256(f"{ex.get('claim', '')}\u0000{ex.get('label', '')}\u0000{texts}".encode()).hexdigest()[:16]


def probe_indices(n_rows, rng, n=MISTAKE_PROBE_N):
    """Which training rows a version answers after training: a sample of n (all of them when there are fewer),
    drawn with the version-seeded rng so it is reproducible and differs between versions."""
    idx = list(range(n_rows))
    rng.shuffle(idx)
    return sorted(idx[:n])


def mistakes_from(examples, answers, version, held_out_claims=()):
    """The rows a version answered wrongly, each kept whole (MISTAKE_KEYS) with what the model said, the version
    and the row's key. An answer that does not parse counts as wrong ("invalid"). A row whose claim is also a
    held-out claim is never kept, so the pool can never carry an eval example into training."""
    held = set(held_out_claims)
    out = []
    for ex, ans in zip(examples, answers):
        said = ans.get("label") if isinstance(ans, dict) else None
        if said == ex.get("label") or ex.get("claim") in held:
            continue
        row = {k: ex[k] for k in MISTAKE_KEYS if k in ex}
        row["mistake"] = {"version": version, "said": said if said in ("supported", "contradicted", "not_covered") else "invalid", "key": example_key(ex)}
        out.append(row)
    return out


def merge_pool(pool, new, cap=MISTAKE_POOL_CAP):
    """The pool after a version's mistakes are added: the new ones first, then the older ones not repeated, at
    most cap rows. A row the newest version got wrong again moves to the front with its newest record."""
    seen, out = set(), []
    for row in list(new) + list(pool):
        k = (row.get("mistake") or {}).get("key") or example_key(row)
        if k in seen:
            continue
        seen.add(k)
        out.append(row)
        if len(out) >= cap:
            break
    return out


# ---------------------------------------------------------------------------
# Focused training (since 2026-11-17). v23 answered 96 percent of a sample of its own training rows correctly
# after training, and doubling the time from 60 to 120 minutes (v22 to v23) did not lift the held-out VitaminC
# score (0.733 to 0.69): most of the extra hour was spent re-reading rule-made rows the model already gets
# right. A run now reads every row that teaches something a rule cannot (gold, imported human-written claims,
# the mistake pool, composed and long-document examples) and a fresh, label-balanced sample of the plain
# rule-made and hard-v1 rows. The sample is seeded by the version, so over a week the whole set is still read.
# On 17 November 2026 Hashim set the budget back to one hour. v24, the first focused run, took 849 of its 1,049
# planned steps in the hour (about 14 steps a minute: long-document rows take longer), so the caps below are
# sized for a whole focused pass of about 13,600 rows, about 850 steps.
# ---------------------------------------------------------------------------
# Since 2026-11-27 (mix v2): the VitaminC import doubles (modal_train.py import_n 4,000 to 8,000: human-written claims
# are where the mistake pool says Zeus fails, 227 of its 338 rows, and the held-out VitaminC score has fallen from
# v22's 0.733 to v33's 0.57), and the rule-made groups give room so a focused pass still fits about the hour:
# rules 2,500 to 1,800, hard-v1 and hard-v2 1,600 to 1,300, and compose-v2, kept whole until now (3,521 rows), capped at 2,400.
FOCUS_CAPS = {"rules": 1800, "hard-v1": 1300, "hard-v2": 1300, "compose-v2": 2400}   # rows kept per sampled group; every other group is kept whole
# Hard rows of these kinds form their own group and are kept whole: they are the few hundred rows that teach
# the pattern eval3 scores lowest (modal_shift, 0.667 in v24), and a 1,600-row sample of 8,000 would see a fifth of them.
FOCUS_WHOLE_KINDS = {"hard_modal_shift", "hard_hedge_drop"}


def focus_group(ex, is_priority):
    """The group a training row belongs to for focus_indices: "priority" (gold, imported, mistakes), its
    generator name (compose-v2, longdoc-v1, hard-v2), "<generator>:<kind>" for the hard kinds kept whole
    (FOCUS_WHOLE_KINDS), or "rules" for the plain rule-made rows."""
    if is_priority:
        return "priority"
    if ex.get("kind") in FOCUS_WHOLE_KINDS:
        return f"{ex.get('generator') or 'rules'}:{ex['kind']}"
    return ex.get("generator") or "rules"


def focus_indices(train, priority, rng, caps=None):
    """Indices of the rows a focused run trains on, in their original order. Groups named in caps are sampled
    down to their cap, keeping each label's share of the group; every other group is kept whole."""
    caps = FOCUS_CAPS if caps is None else caps
    groups = {}
    for i, ex in enumerate(train):
        groups.setdefault(focus_group(ex, priority[i]), []).append(i)
    keep = []
    for g, idx in sorted(groups.items()):
        cap = caps.get(g)
        if cap is None or len(idx) <= cap:
            keep.extend(idx)
            continue
        by_label = {}
        for i in idx:
            by_label.setdefault(train[i].get("label"), []).append(i)
        for lab, li in sorted(by_label.items(), key=lambda kv: str(kv[0])):
            take = round(cap * len(li) / len(idx))
            keep.extend(rng.sample(li, min(take, len(li))))
    return sorted(keep)


# ---------------------------------------------------------------------------
# Serving format (since 2026-11-27). Every training row until v33 labelled its passages by atom id (eight hex
# characters) and nearly all had exactly three passages; olo-answer labels them p1, p2, ... and sends the
# passages a sentence cites, or up to eight. v31 read its frozen split well (served evidence hit 0.905) and
# failed live: in the answer eval of 26 November 48 of its supported sentences lost their evidence, most likely
# to passage ids. A share of every run's rows is now shown the way olo-answer shows them (serving_view), and
# every run is also scored on the first split in that form (serving_eval), which promote.py reads as a floor.
# ---------------------------------------------------------------------------
SERVING_SHARE = 0.5          # share of training rows shown in olo-answer's form
SERVING_PAD_SHARE = 0.4      # of those, the share that also gets unrelated passages, up to SERVING_MAX_PASSAGES
SERVING_MAX_PASSAGES = 8     # olo-answer's default k
SERVING_EVAL_PASSAGES = 6    # every serving_eval row is padded to this many passages


def serving_view(ex, rng, distractors=(), pad_to=0, label="p"):
    """The row with its passages labelled the way olo-answer labels them ("p1", "p2", ... in a shuffled order),
    its evidence re-keyed to the new labels, and, when pad_to is above the row's passage count, unrelated
    passages from `distractors` added at random positions until there are pad_to. A distractor whose text is
    already one of the row's passages is skipped. Claim, label, quotes and rationale are unchanged, so the
    answer the model learns is the same verdict over the same words; only how the passages are named, ordered
    and surrounded changes. The input row is not modified."""
    own = [dict(p) for p in ex.get("passages") or []]
    texts = {p.get("text") for p in own}
    extra = []
    if pad_to and pad_to > len(own) and distractors:
        pool = [d for d in distractors if d.get("text") not in texts]
        rng.shuffle(pool)
        for d in pool[: pad_to - len(own)]:
            extra.append(dict(d))
            texts.add(d.get("text"))
    allp = own + extra
    rng.shuffle(allp)
    new_id = {}
    out_p = []
    for i, p in enumerate(allp, 1):
        nid = f"{label}{i}"
        if p in own and p.get("id") not in new_id:
            new_id[p.get("id")] = nid
        out_p.append({**p, "id": nid})
    out = dict(ex)
    out["passages"] = out_p
    out["evidence"] = [{**e, "passage": new_id.get(e.get("passage"), e.get("passage"))} for e in ex.get("evidence") or []]
    return out


def serving_mix(rows, rng, distractors, share=SERVING_SHARE, pad_share=SERVING_PAD_SHARE, max_passages=SERVING_MAX_PASSAGES):
    """The training rows with `share` of them shown in olo-answer's form (serving_view) and, of those,
    `pad_share` padded with distractors to a random count between their own and max_passages. Seeded by rng,
    so a version's mix is reproducible. Returns a new list in the same order."""
    out = []
    for ex in rows:
        if rng.random() >= share:
            out.append(ex)
            continue
        n = len(ex.get("passages") or [])
        pad = rng.randint(n + 1, max(n + 1, max_passages)) if rng.random() < pad_share and n < max_passages else 0
        out.append(serving_view(ex, rng, distractors, pad_to=pad))
    return out


def distractor_pool(rows, rng, n=4000):
    """Passages to pad rows with: up to n drawn from the given rows (each keeps its source and text). For the
    serving eval the rows are the eval split itself, so no training text enters an eval prompt."""
    ps = [p for ex in rows for p in (ex.get("passages") or []) if p.get("text")]
    rng.shuffle(ps)
    return [{"id": p.get("id"), "source": p.get("source", ""), "text": p["text"]} for p in ps[:n]]


def serving_eval(evals, seed=0, pad_to=SERVING_EVAL_PASSAGES):
    """The first split as olo-answer would show it: every row relabelled p1..pK in a shuffled order and padded
    with passages from other eval rows to pad_to. Fixed seed, so every version is scored on the same prompts."""
    import random as _r
    rng = _r.Random(seed)
    pool = distractor_pool(evals, _r.Random(seed + 1), n=len(evals) * 3)
    return [serving_view(ex, rng, pool, pad_to=pad_to) for ex in evals]

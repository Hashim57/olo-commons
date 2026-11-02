#!/usr/bin/env python3
"""Evaluate a Zeus model (adapter or full model) on the frozen eval split.

  python zeus/eval.py --adapter zeus/out/zeus-v1 [--base Qwen/Qwen2.5-7B-Instruct] [--data zeus/data] [--limit 300]
  python zeus/eval.py --model Qwen/Qwen2.5-7B-Instruct          # the untuned baseline, for comparison
  python zeus/eval.py --adapter zeus/out/zeus-v1 --format-retry   # also measure one format repair per bad answer

Reports: label accuracy, per-label F1, evidence hit rate (the quoted span is a
substring of the named passage and the passage is the right one), JSON validity.
Writes --out (default <adapter>/eval.json). CPU works for small models; slow.

--format-retry (off by default): when an answer does not parse (no JSON object, bad
JSON, a label outside the three), ask once more with a short repair prompt. The
headline numbers (json_valid, label_accuracy, evidence_hit and the rest of score())
are always computed on the first answer, so reports stay comparable with older
ones; the retry adds separate *_after_retry fields and retries_used. The report
says which mode ran ("format_retry": true or false).
"""
import argparse, json, os, re, sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from train_lora import SYSTEM, render_user  # noqa: E402

LABELS = ("supported", "contradicted", "not_covered")

# The one repair turn a format retry adds after the bad answer. Kept identical to
# REPAIR in zeus/cloudflare/worker.js.
REPAIR = ('Your answer was not one valid JSON object in the required format. Answer again with only the JSON object '
          '{"label": "supported" | "contradicted" | "not_covered", "evidence": [{"passage": "<id>", "quote": "<exact words from that passage>"}], '
          '"rationale": "<one sentence>"} and no other text.')
RETRY_MAX_TOKENS = 200   # the retry never writes more than this
RETRY_MAX_SECONDS = 30   # nor runs longer than this (local generation)


def parse(text):
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        o = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    if o.get("label") not in LABELS:
        return None
    return o


def evidence_ok(pred, ex):
    if ex["label"] == "not_covered":
        return not pred.get("evidence")
    ev = pred.get("evidence") or []
    if not ev:
        return False
    want = {e["passage"] for e in ex["evidence"]}
    texts = {p["id"]: p["text"] for p in ex["passages"]}
    return all(e.get("passage") in want and e.get("quote", "") and e["quote"] in texts.get(e["passage"], "") for e in ev)


def score(examples, answers):
    """Measured numbers for a list of examples and the model's raw answers (text or an
    already parsed dict per example). One function for every path that scores Zeus
    (eval.py, eval_endpoint.py, train_mlx.py, cloud/modal_train.py), so the four
    never drift apart. Nothing is estimated: an answer that does not parse counts
    against the true label and never towards a predicted one.

    Returns: n, label_accuracy, json_valid, evidence_hit, f1 (per label), and
    - confusion: true label -> {predicted label or "invalid": count}
    - rates: per label, tpr (recall: of the examples with this label, how many were
      labelled so) and tnr (of the examples without this label, how many were not
      wrongly given it). The gap between the two shows a bias the headline hides.
    - binary_balanced_accuracy: the two-label view used by LLM-AggreFact, with
      supported as 1 and both contradicted and not_covered as 0, so Zeus can be
      put beside published checkers. It is the mean of the supported tpr and tnr.
    """
    confusion = {l: {k: 0 for k in LABELS + ("invalid",)} for l in LABELS}
    tp, fp, fn = Counter(), Counter(), Counter()
    correct = valid = ev_hits = 0
    for ex, ans in zip(examples, answers):
        pred = ans if isinstance(ans, dict) else parse(ans or "")
        if pred is not None and pred.get("label") not in LABELS:
            pred = None
        if not pred:
            fn[ex["label"]] += 1
            confusion[ex["label"]]["invalid"] += 1
            continue
        valid += 1
        confusion[ex["label"]][pred["label"]] += 1
        if pred["label"] == ex["label"]:
            correct += 1
            tp[ex["label"]] += 1
            if evidence_ok(pred, ex):
                ev_hits += 1
        else:
            fp[pred["label"]] += 1
            fn[ex["label"]] += 1
    n = len(examples)
    f1, rates = {}, {}
    for l in LABELS:
        p = tp[l] / (tp[l] + fp[l]) if tp[l] + fp[l] else 0
        r = tp[l] / (tp[l] + fn[l]) if tp[l] + fn[l] else 0
        f1[l] = round(2 * p * r / (p + r), 3) if p + r else 0
        positives = tp[l] + fn[l]
        negatives = n - positives
        rates[l] = {"tpr": round(tp[l] / positives, 3) if positives else None,
                    "tnr": round((negatives - fp[l]) / negatives, 3) if negatives else None}
    s = rates["supported"]
    bba = round((s["tpr"] + s["tnr"]) / 2, 3) if s["tpr"] is not None and s["tnr"] is not None else None
    return {"n": n, "label_accuracy": round(correct / n, 3) if n else 0, "json_valid": round(valid / n, 3) if n else 0,
            "evidence_hit": round(ev_hits / n, 3) if n else 0, "f1": f1, "confusion": confusion, "rates": rates,
            "binary_balanced_accuracy": bba}


def repair_messages(messages, bad_answer):
    """The original conversation, the answer that did not parse, and the repair instruction."""
    return list(messages) + [{"role": "assistant", "content": bad_answer or ""}, {"role": "user", "content": REPAIR}]


def answer_with_retry(generate, messages, format_retry=False):
    """Ask once; with format_retry, ask at most one more time when the first answer does
    not parse. `generate(messages, retry)` returns the model's text; retry=True asks it to
    use the retry caps (greedy, RETRY_MAX_TOKENS, RETRY_MAX_SECONDS).
    Returns (first_answer, final_answer, retried)."""
    first = generate(messages, False)
    if not format_retry or parse(first or "") is not None:
        return first, first, False
    try:
        second = generate(repair_messages(messages, first), True)
    except Exception:  # a failed retry leaves the answer as bad as it was
        second = ""
    return first, second, True


def retry_metrics(examples, final_answers, retried):
    """The numbers after one format retry, kept apart from score()'s first-attempt ones:
    json_valid_after_retry, label_accuracy_after_retry, evidence_hit_after_retry and
    retries_used (how many examples needed the retry)."""
    s = score(examples, final_answers)
    return {"json_valid_after_retry": s["json_valid"], "label_accuracy_after_retry": s["label_accuracy"],
            "evidence_hit_after_retry": s["evidence_hit"], "retries_used": sum(1 for r in retried if r)}


def report_fields(examples, first_answers, final_answers, retried, format_retry):
    """score() on the first answers, the mode, and (only with format_retry) the after-retry fields."""
    out = {**score(examples, first_answers), "format_retry": bool(format_retry)}
    if format_retry:
        out.update(retry_metrics(examples, final_answers, retried))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter")
    ap.add_argument("--model")
    ap.add_argument("--base", default="Qwen/Qwen2.5-7B-Instruct")
    ap.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--limit", type=int, default=300)
    ap.add_argument("--eval-file", help="score this jsonl instead of <data>/eval.jsonl (for example zeus/data/imported/vitaminc-eval.jsonl)")
    ap.add_argument("--out")
    ap.add_argument("--format-retry", action="store_true",
                    help="retry once with a repair prompt when an answer does not parse; first-attempt metrics stay unchanged and the retry is reported separately")
    args = ap.parse_args()
    if not (args.adapter or args.model):
        sys.exit("give --adapter or --model")

    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM
    name = args.model or args.base
    tok = AutoTokenizer.from_pretrained(args.adapter or name)
    model = AutoModelForCausalLM.from_pretrained(name, torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32, device_map="auto")
    if args.adapter:
        from peft import PeftModel
        model = PeftModel.from_pretrained(model, args.adapter)
    model.eval()

    with open(args.eval_file or os.path.join(args.data, "eval.jsonl")) as f:
        examples = [json.loads(l) for l in f][: args.limit]

    def generate(msgs, retry):
        ids = tok.apply_chat_template(msgs, add_generation_prompt=True, return_tensors="pt").to(model.device)
        caps = {"max_new_tokens": RETRY_MAX_TOKENS, "max_time": RETRY_MAX_SECONDS} if retry else {"max_new_tokens": 200}
        with torch.no_grad():
            out = model.generate(ids, do_sample=False, **caps)
        return tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True)

    firsts, finals, retried = [], [], []
    for ex in examples:
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}]
        first, final, r = answer_with_retry(generate, msgs, args.format_retry)
        firsts.append(first); finals.append(final); retried.append(r)

    report = {"model": args.adapter or args.model, **report_fields(examples, firsts, finals, retried, args.format_retry)}
    out = args.out or os.path.join(args.adapter or ".", "eval.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()

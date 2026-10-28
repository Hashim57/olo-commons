#!/usr/bin/env python3
"""Evaluate a Zeus model (adapter or full model) on the frozen eval split.

  python zeus/eval.py --adapter zeus/out/zeus-v1 [--base Qwen/Qwen2.5-7B-Instruct] [--data zeus/data] [--limit 300]
  python zeus/eval.py --model Qwen/Qwen2.5-7B-Instruct          # the untuned baseline, for comparison
  python zeus/eval.py --adapter zeus/out/zeus-v1 --split eval3  # a later frozen split, reported per pattern

The three Commons splits are all frozen by atom id and kept side by side: eval
(rule-made, saturated, kept for comparison with v0 to v5), eval2 (near misses,
relation flips, true passage last) and eval3 (versioned; see zeus/eval3.py).
Splits whose lines carry a `kind` are also reported per pattern (`by_kind`).

Reports: label accuracy, per-label F1, evidence hit rate (the quoted span is a
substring of the named passage and the passage is the right one), JSON validity.
Writes --out (default <adapter>/eval.json). CPU works for small models; slow.
"""
import argparse, json, os, re, sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from train_lora import SYSTEM, render_user  # noqa: E402

LABELS = ("supported", "contradicted", "not_covered")
SPLITS = {"eval": "eval.jsonl", "eval2": "eval2.jsonl", "eval3": "eval3.jsonl"}


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


def score_by_kind(examples, answers):
    """Label accuracy per pattern ({kind: {"n", "accuracy"}}) for splits whose lines carry a `kind`
    (eval2, eval3). Lines without one count as "other". Same answer handling as score(): an answer
    that does not parse is wrong."""
    kinds = {}
    for ex, ans in zip(examples, answers):
        pred = ans if isinstance(ans, dict) else parse(ans or "")
        d = kinds.setdefault(ex.get("kind", "other"), {"n": 0, "correct": 0})
        d["n"] += 1
        if pred and pred.get("label") == ex["label"]:
            d["correct"] += 1
    return {k: {"n": d["n"], "accuracy": round(d["correct"] / d["n"], 3)} for k, d in sorted(kinds.items())}


def split_report(examples, answers):
    """score() plus, for a split with patterns, by_kind, and the split's version when its lines carry one."""
    r = score(examples, answers)
    if any("kind" in ex for ex in examples):
        r["by_kind"] = score_by_kind(examples, answers)
    versions = sorted({ex["version"] for ex in examples if ex.get("version")})
    if versions:
        r["version"] = versions[0] if len(versions) == 1 else versions
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter")
    ap.add_argument("--model")
    ap.add_argument("--base", default="Qwen/Qwen2.5-7B-Instruct")
    ap.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--limit", type=int, default=300)
    ap.add_argument("--split", choices=sorted(SPLITS), default="eval", help="which frozen Commons split in --data to score (default eval)")
    ap.add_argument("--eval-file", help="score this jsonl instead of a split in --data (for example zeus/data/imported/vitaminc-eval.jsonl)")
    ap.add_argument("--out")
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

    with open(args.eval_file or os.path.join(args.data, SPLITS[args.split])) as f:
        examples = [json.loads(l) for l in f][: args.limit]

    answers = []
    for ex in examples:
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}]
        ids = tok.apply_chat_template(msgs, add_generation_prompt=True, return_tensors="pt").to(model.device)
        with torch.no_grad():
            out = model.generate(ids, max_new_tokens=200, do_sample=False)
        answers.append(tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True))

    # split_report on the first split (no kind, no version) is exactly score(), so its eval.json is unchanged.
    report = {"model": args.adapter or args.model, **split_report(examples, answers)}
    if not args.eval_file and args.split != "eval":
        report["split"] = args.split
    out = args.out or os.path.join(args.adapter or ".", "eval.json" if args.split == "eval" or args.eval_file else f"{args.split}.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Evaluate a Zeus model (adapter or full model) on the frozen eval split.

  python zeus/eval.py --adapter zeus/out/zeus-v1 [--base Qwen/Qwen2.5-7B-Instruct] [--data zeus/data] [--limit 300]
  python zeus/eval.py --model Qwen/Qwen2.5-7B-Instruct          # the untuned baseline, for comparison

Reports: label accuracy, per-label F1, evidence hit rate (the quoted span is a
substring of the named passage and the passage is the right one), JSON validity.
Writes --out (default <adapter>/eval.json). CPU works for small models; slow.
"""
import argparse, json, os, re, sys
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
from train_lora import SYSTEM, render_user  # noqa: E402

LABELS = ("supported", "contradicted", "not_covered")


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter")
    ap.add_argument("--model")
    ap.add_argument("--base", default="Qwen/Qwen2.5-7B-Instruct")
    ap.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--limit", type=int, default=300)
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

    with open(os.path.join(args.data, "eval.jsonl")) as f:
        examples = [json.loads(l) for l in f][: args.limit]

    tp, fp, fn = Counter(), Counter(), Counter()
    correct = valid = ev_hits = 0
    for ex in examples:
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}]
        ids = tok.apply_chat_template(msgs, add_generation_prompt=True, return_tensors="pt").to(model.device)
        with torch.no_grad():
            out = model.generate(ids, max_new_tokens=200, do_sample=False)
        text = tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True)
        pred = parse(text)
        if not pred:
            fn[ex["label"]] += 1
            continue
        valid += 1
        if pred["label"] == ex["label"]:
            correct += 1
            tp[ex["label"]] += 1
            if evidence_ok(pred, ex):
                ev_hits += 1
        else:
            fp[pred["label"]] += 1
            fn[ex["label"]] += 1

    n = len(examples)
    f1 = {}
    for l in LABELS:
        p = tp[l] / (tp[l] + fp[l]) if tp[l] + fp[l] else 0
        r = tp[l] / (tp[l] + fn[l]) if tp[l] + fn[l] else 0
        f1[l] = round(2 * p * r / (p + r), 3) if p + r else 0
    report = {"model": args.adapter or args.model, "n": n, "label_accuracy": round(correct / n, 3) if n else 0,
              "json_valid": round(valid / n, 3) if n else 0, "evidence_hit": round(ev_hits / n, 3) if n else 0, "f1": f1}
    out = args.out or os.path.join(args.adapter or ".", "eval.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()

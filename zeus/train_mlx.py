#!/usr/bin/env python3
"""Train and evaluate Zeus on an Apple Silicon Mac with MLX (uses the Mac GPU).

  python zeus/train_mlx.py --out zeus/out/zeus-v1 [--base mlx-community/Qwen2.5-7B-Instruct-4bit] [--iters 600]

Steps: convert zeus/data/{train,eval}.jsonl (+ gold) to MLX chat format, run
mlx_lm LoRA, then evaluate the adapter on the frozen eval split and write
--out/eval.json and --out/train_summary.json (commit those two, not the weights).

Memory: the 4-bit 7B needs about 10 GB of unified memory for LoRA; on a 16 GB
Mac use --base mlx-community/Qwen2.5-1.5B-Instruct-4bit or --num-layers 8.
"""
import argparse, json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(__file__))
from train_lora import SYSTEM, render_user, render_answer  # noqa: E402
from eval import parse, evidence_ok, LABELS  # noqa: E402


def to_mlx(data_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    gold = os.path.join(data_dir, "gold")
    extra = [os.path.join(gold, p) for p in os.listdir(gold) if p.endswith(".jsonl")] if os.path.isdir(gold) else []
    counts = {}
    for split, files in (("train", [os.path.join(data_dir, "train.jsonl")] + extra), ("valid", [os.path.join(data_dir, "eval.jsonl")])):
        n = 0
        with open(os.path.join(out_dir, f"{split}.jsonl"), "w") as w:
            for f in files:
                if not os.path.exists(f):
                    continue
                for line in open(f):
                    line = line.strip()
                    if not line:
                        continue
                    ex = json.loads(line)
                    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}, {"role": "assistant", "content": render_answer(ex)}]
                    w.write(json.dumps({"messages": msgs}, ensure_ascii=False) + "\n")
                    n += 1
        counts[split] = n
    # mlx_lm wants a test split too; reuse valid
    import shutil
    shutil.copy(os.path.join(out_dir, "valid.jsonl"), os.path.join(out_dir, "test.jsonl"))
    return counts


def evaluate(base, adapter, data_dir, limit):
    from mlx_lm import load, generate
    model, tok = load(base, adapter_path=adapter)
    examples = [json.loads(l) for l in open(os.path.join(data_dir, "eval.jsonl"))][:limit]
    correct = valid = ev_hits = 0
    per = {l: {"tp": 0, "fp": 0, "fn": 0} for l in LABELS}
    for ex in examples:
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}]
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
        text = generate(model, tok, prompt=prompt, max_tokens=200, verbose=False)
        pred = parse(text)
        if not pred:
            per[ex["label"]]["fn"] += 1
            continue
        valid += 1
        if pred["label"] == ex["label"]:
            correct += 1
            per[ex["label"]]["tp"] += 1
            if evidence_ok(pred, ex):
                ev_hits += 1
        else:
            per[pred["label"]]["fp"] += 1
            per[ex["label"]]["fn"] += 1
    n = len(examples)
    f1 = {}
    for l, c in per.items():
        p = c["tp"] / (c["tp"] + c["fp"]) if c["tp"] + c["fp"] else 0
        r = c["tp"] / (c["tp"] + c["fn"]) if c["tp"] + c["fn"] else 0
        f1[l] = round(2 * p * r / (p + r), 3) if p + r else 0
    return {"model": adapter, "base": base, "n": n, "label_accuracy": round(correct / n, 3) if n else 0,
            "json_valid": round(valid / n, 3) if n else 0, "evidence_hit": round(ev_hits / n, 3) if n else 0, "f1": f1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="mlx-community/Qwen2.5-7B-Instruct-4bit")
    ap.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--iters", type=int, default=600)
    ap.add_argument("--batch-size", type=int, default=2)
    ap.add_argument("--num-layers", type=int, default=16)
    ap.add_argument("--lr", type=float, default=1e-5)
    ap.add_argument("--eval-limit", type=int, default=200)
    ap.add_argument("--skip-train", action="store_true")
    args = ap.parse_args()

    mlx_dir = os.path.join(args.data, "mlx")
    counts = to_mlx(args.data, mlx_dir)
    print("mlx data", counts)
    t0 = time.time()
    if not args.skip_train:
        cmd = [sys.executable, "-m", "mlx_lm.lora", "--model", args.base, "--train", "--data", mlx_dir, "--iters", str(args.iters),
               "--batch-size", str(args.batch_size), "--num-layers", str(args.num_layers), "--learning-rate", str(args.lr),
               "--adapter-path", args.out, "--save-every", "100", "--steps-per-eval", "100", "--max-seq-length", "3072"]
        print(" ".join(cmd))
        subprocess.run(cmd, check=True)
    minutes = round((time.time() - t0) / 60, 1)
    report = evaluate(args.base, args.out, args.data, args.eval_limit)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "eval.json"), "w") as f:
        json.dump(report, f, indent=2)
    with open(os.path.join(args.out, "train_summary.json"), "w") as f:
        json.dump({"base": args.base, "framework": "mlx", "train_examples": counts.get("train"), "eval_examples": counts.get("valid"),
                   "iters": args.iters, "num_layers": args.num_layers, "lr": args.lr, "minutes": minutes}, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()

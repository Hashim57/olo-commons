#!/usr/bin/env python3
"""Train and evaluate Zeus on an Apple Silicon Mac with MLX (uses the Mac GPU).

  python zeus/train_mlx.py --out zeus/out/zeus-v1 [--base mlx-community/Qwen2.5-7B-Instruct-4bit] [--iters 600]

Steps: convert zeus/data/{train,eval}.jsonl (+ gold and imported corpora) to MLX chat format, run
mlx_lm LoRA, then evaluate the adapter on the frozen eval split and write
--out/eval.json and --out/train_summary.json (commit those two, not the weights).

Memory: the 4-bit 7B needs about 10 GB of unified memory for LoRA; on a 16 GB
Mac use --base mlx-community/Qwen2.5-1.5B-Instruct-4bit or --num-layers 8.
"""
import argparse, json, os, re, subprocess, sys, time

# Bases whose chat template has no system role (Mistral v0.2): the system prompt is folded into the
# user turn, in training and at inference, so the served model sees exactly what it was trained on.
FOLD_SYSTEM_BASES = ("mistral",)


def prompt_messages(ex, fold):
    from train_lora import SYSTEM as S, render_user as ru  # noqa: E402
    if fold:
        return [{"role": "user", "content": S + "\n\n" + ru(ex)}]
    return [{"role": "system", "content": S}, {"role": "user", "content": ru(ex)}]


def folds(base):
    return any(k in base.lower() for k in FOLD_SYSTEM_BASES)

sys.path.insert(0, os.path.dirname(__file__))
from train_lora import SYSTEM, render_user, render_answer  # noqa: E402
from eval import parse, evidence_ok, LABELS, score  # noqa: E402


def to_mlx(data_dir, out_dir, fold=False):
    os.makedirs(out_dir, exist_ok=True)
    # hand-written gold and imported open corpora train alongside the Commons examples; never in valid
    extra = []
    for sub in ("gold", "imported"):
        d = os.path.join(data_dir, sub)
        if os.path.isdir(d):
            extra += [os.path.join(d, p) for p in sorted(os.listdir(d)) if p.endswith(".jsonl") and not p.endswith("-eval.jsonl")]
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
                    msgs = prompt_messages(ex, fold) + [{"role": "assistant", "content": render_answer(ex)}]
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
    answers = []
    for ex in examples:
        msgs = prompt_messages(ex, folds(base))
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
        answers.append(generate(model, tok, prompt=prompt, max_tokens=200, verbose=False))
    return {"model": adapter, "base": base, **score(examples, answers)}


def last_checkpoint(out):
    """(iteration, path) of the newest numbered adapter checkpoint mlx_lm saved in out, or (0, None)."""
    best = (0, None)
    if os.path.isdir(out):
        for name in os.listdir(out):
            m = re.fullmatch(r"(\d{7})_adapters\.safetensors", name)
            if m and int(m.group(1)) > best[0]:
                best = (int(m.group(1)), os.path.join(out, name))
    return best


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
    ap.add_argument("--no-grad-checkpoint", action="store_true", help="faster but uses more GPU memory")
    ap.add_argument("--max-seq-length", type=int, default=3072)
    # LoRA shape. Cloudflare Workers AI serves uploaded adapters of rank 8 or less on q_proj and v_proj
    # (zeus/cloudflare/README.md); --lora-rank 8 --lora-keys self_attn.q_proj,self_attn.v_proj matches it.
    ap.add_argument("--lora-rank", type=int, default=0, help="0 keeps mlx_lm's default LoRA config")
    ap.add_argument("--lora-keys", default="")
    ap.add_argument("--lora-scale", type=float, default=20.0)
    args = ap.parse_args()

    mlx_dir = os.path.join(args.data, "mlx")
    counts = to_mlx(args.data, mlx_dir, fold=folds(args.base))
    lora_config = None
    if args.lora_rank:
        lora_config = os.path.join(mlx_dir, "lora_config.yaml")
        keys = [k.strip() for k in args.lora_keys.split(",") if k.strip()]
        with open(lora_config, "w") as f:
            f.write("lora_parameters:\n")
            if keys:
                f.write("  keys: [" + ", ".join(json.dumps(k) for k in keys) + "]\n")
            f.write(f"  rank: {args.lora_rank}\n  scale: {args.lora_scale}\n  dropout: 0.0\n")
    print("mlx data", counts)
    t0 = time.time()
    if not args.skip_train:
        def lora_cmd(iters, batch, resume=None):
            c = [sys.executable, "-m", "mlx_lm.lora", "--model", args.base, "--train", "--data", mlx_dir, "--iters", str(iters),
                 "--batch-size", str(batch), "--num-layers", str(args.num_layers), "--learning-rate", str(args.lr),
                 "--adapter-path", args.out, "--save-every", "100", "--steps-per-eval", "100", "--max-seq-length", str(args.max_seq_length)]
            # Gradient checkpointing trades some speed for much less activation memory. v3 died with a
            # Metal out-of-memory error at iter 250 on a 16 GB Mac while other apps were open.
            if not args.no_grad_checkpoint:
                c.append("--grad-checkpoint")
            if lora_config:
                c += ["-c", lora_config]
            if resume:
                c += ["--resume-adapter-file", resume]
            return c
        cmd = lora_cmd(args.iters, args.batch_size)
        print(" ".join(cmd))
        r = subprocess.run(cmd)
        if r.returncode != 0:
            # One retry for a crash mid-run (for example GPU memory pressure): resume from the last saved
            # checkpoint with batch size 1 for the iterations that are left. Recorded in train_summary.json.
            done, ckpt = last_checkpoint(args.out)
            if not ckpt or done >= args.iters:
                sys.exit(f"training failed (exit {r.returncode}) with no checkpoint to resume from")
            print(f"training stopped (exit {r.returncode}); resuming from iter {done} with batch size 1", flush=True)
            retry = {"resumed_from_iter": done, "retry_batch_size": 1}
            cmd = lora_cmd(args.iters - done, 1, resume=ckpt)
            print(" ".join(cmd))
            subprocess.run(cmd, check=True)
        else:
            retry = None
    else:
        retry = None
    minutes = round((time.time() - t0) / 60, 1)
    report = evaluate(args.base, args.out, args.data, args.eval_limit)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "eval.json"), "w") as f:
        json.dump(report, f, indent=2)
    with open(os.path.join(args.out, "train_summary.json"), "w") as f:
        json.dump({"base": args.base, "framework": "mlx", "train_examples": counts.get("train"), "eval_examples": counts.get("valid"),
                   "iters": args.iters, "num_layers": args.num_layers, "lr": args.lr, "minutes": minutes,
                   "grad_checkpoint": not args.no_grad_checkpoint, "retry": retry, "system_folded": folds(args.base),
                   "lora": {"rank": args.lora_rank or None, "keys": args.lora_keys or None, "scale": args.lora_scale if args.lora_rank else None}}, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()

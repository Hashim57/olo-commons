#!/usr/bin/env python3
"""QLoRA fine-tune of an open-weight instruction model into Zeus.

  python zeus/train_lora.py --base Qwen/Qwen2.5-7B-Instruct --out zeus/out/zeus-v1 \
      [--data zeus/data] [--epochs 2] [--lr 2e-4] [--max-len 3072]

Needs one GPU with 16 GB or more (4-bit). Writes a PEFT adapter to --out and a
training summary to --out/train_summary.json that eval.py and STATUS.md use.
"""
import argparse, json, os, time

SYSTEM = ("You are Zeus, the verification layer of Olo. Given a claim and numbered passages, answer with one JSON object: "
          '{"label": "supported" | "contradicted" | "not_covered", "evidence": [{"passage": "<id>", "quote": "<exact words from that passage>"}], "rationale": "<one sentence>"}. '
          "Quote only words that appear in a passage. If no passage covers the claim, label not_covered with empty evidence.")


def render_user(ex):
    ps = "\n\n".join(f"[{p['id']}] ({p['source']}) {p['text']}" for p in ex["passages"])
    return f"Claim: {ex['claim']}\n\nPassages:\n{ps}"


def render_answer(ex):
    return json.dumps({"label": ex["label"], "evidence": ex["evidence"], "rationale": ex["rationale"]}, ensure_ascii=False)


def to_messages(ex):
    return {"messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}, {"role": "assistant", "content": render_answer(ex)}]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="Qwen/Qwen2.5-7B-Instruct")
    ap.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=float, default=2)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--max-len", type=int, default=3072)
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--no-4bit", action="store_true")
    args = ap.parse_args()

    import torch
    from datasets import load_dataset
    from peft import LoraConfig
    from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
    from trl import SFTConfig, SFTTrainer

    files = {"train": os.path.join(args.data, "train.jsonl"), "eval": os.path.join(args.data, "eval.jsonl")}
    extra = []
    for sub in ("gold", "imported"):
        d = os.path.join(args.data, sub)
        if os.path.isdir(d):
            extra += [os.path.join(d, p) for p in sorted(os.listdir(d)) if p.endswith(".jsonl") and not p.endswith("-eval.jsonl")]
    if extra:
        files["train"] = [files["train"]] + extra
    ds = load_dataset("json", data_files=files)
    ds = ds.map(to_messages, remove_columns=ds["train"].column_names)

    tok = AutoTokenizer.from_pretrained(args.base)
    tok.pad_token = tok.pad_token or tok.eos_token
    quant = None if args.no_4bit else BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=torch.bfloat16, bnb_4bit_use_double_quant=True)
    model = AutoModelForCausalLM.from_pretrained(args.base, quantization_config=quant, torch_dtype=torch.bfloat16, device_map="auto")

    lora = LoraConfig(r=args.rank, lora_alpha=2 * args.rank, lora_dropout=0.05, task_type="CAUSAL_LM",
                      target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"])
    cfg = SFTConfig(output_dir=args.out, num_train_epochs=args.epochs, learning_rate=args.lr, per_device_train_batch_size=2,
                    gradient_accumulation_steps=8, max_seq_length=args.max_len, logging_steps=10, eval_strategy="epoch",
                    save_strategy="epoch", bf16=True, warmup_ratio=0.03, lr_scheduler_type="cosine", report_to=[],
                    gradient_checkpointing=True, packing=False)
    t0 = time.time()
    trainer = SFTTrainer(model=model, args=cfg, train_dataset=ds["train"], eval_dataset=ds["eval"], peft_config=lora, processing_class=tok)
    trainer.train()
    trainer.save_model(args.out)
    tok.save_pretrained(args.out)
    summary = {"base": args.base, "train_examples": len(ds["train"]), "eval_examples": len(ds["eval"]), "epochs": args.epochs, "lr": args.lr,
               "rank": args.rank, "minutes": round((time.time() - t0) / 60, 1), "final_eval_loss": trainer.evaluate().get("eval_loss")}
    with open(os.path.join(args.out, "train_summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary))


if __name__ == "__main__":
    main()

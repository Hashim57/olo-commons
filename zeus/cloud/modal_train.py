"""Train and measure Zeus on a cloud GPU (Modal), never on anyone's computer.

  modal run zeus/cloud/modal_train.py --version v6

Run by .github/workflows/zeus-train.yml. The local part (on the GitHub runner)
builds the dataset from the Commons, imports the open corpora and checks the gold
set; the remote part (an A100 on Modal) fine-tunes Mistral 7B Instruct v0.2 with
a rank-8 LoRA on q_proj and v_proj at full precision (what Cloudflare serves),
scores it on the frozen eval split, and sends back the adapter and the measured
numbers. Outputs land in zeus/out/zeus-<v>/ (eval.json, train_summary.json) and
zeus/out/zeus-<v>-peft/ (the two files Cloudflare accepts).

Cost: Modal bills per second (an A100 40 GB is about $2.10 an hour) and gives
$30 of free credit a month; one run of about 40 minutes is about $1.50.
Secrets on Modal's side: none; the Hugging Face token, if the base is gated for
you, comes from the HF_TOKEN environment variable of the caller.
"""
import io
import json
import os
import subprocess
import sys
import tarfile
import time

import modal

HERE = os.path.dirname(os.path.abspath(__file__))
ZEUS = os.path.dirname(HERE)
REPO = os.path.dirname(ZEUS)

app = modal.App("zeus-train")
image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("torch==2.5.1", "transformers==4.46.3", "peft==0.13.2", "accelerate==1.1.1", "safetensors==0.4.5", "sentencepiece==0.2.0")
)
cache = modal.Volume.from_name("zeus-hf-cache", create_if_missing=True)
GPU = os.environ.get("ZEUS_GPU", "A100-40GB")


def _tar(paths):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for src, arc in paths:
            t.add(src, arcname=arc)
    return buf.getvalue()


@app.function(image=image, gpu=GPU, timeout=4 * 3600, volumes={"/cache": cache})
def train_remote(payload: bytes, version: str, hf_token: str = "", iters_epochs: float = 1.0, eval_limit: int = 200) -> bytes:
    import torch
    from peft import LoraConfig, get_peft_model
    from transformers import AutoModelForCausalLM, AutoTokenizer

    os.environ["HF_HOME"] = "/cache/hf"
    if hf_token:
        os.environ["HF_TOKEN"] = hf_token
    work = "/tmp/zeus"
    os.makedirs(work, exist_ok=True)
    tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz").extractall(work)
    sys.path.insert(0, os.path.join(work, "zeus"))
    sys.path.insert(0, os.path.join(work, "zeus", "cloud"))
    import recipe  # noqa: E402
    from eval import evidence_ok, parse, LABELS  # noqa: E402

    data = os.path.join(work, "zeus", "data")

    def load(path):
        return [json.loads(l) for l in open(path) if l.strip()] if os.path.exists(path) else []

    train = load(os.path.join(data, "train.jsonl"))
    for sub in ("gold", "imported"):
        d = os.path.join(data, sub)
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith(".jsonl") and not f.endswith("-eval.jsonl"):
                    train += load(os.path.join(d, f))
    evals = load(os.path.join(data, "eval.jsonl"))[:eval_limit]

    base, tok, model = None, None, None
    for candidate in recipe.BASES:
        try:
            tok = AutoTokenizer.from_pretrained(candidate)
            model = AutoModelForCausalLM.from_pretrained(candidate, torch_dtype=torch.bfloat16, device_map="cuda")
            base = candidate
            break
        except Exception as e:  # gated for this token, or unavailable: try the next copy of the same weights
            print(f"could not load {candidate}: {type(e).__name__}: {str(e)[:160]}", flush=True)
    if model is None:
        raise SystemExit("no base model could be loaded")
    tok.pad_token = tok.pad_token or tok.eos_token

    max_len = 2048
    rows = []
    for ex in train:
        p = tok.apply_chat_template(recipe.prompt_messages(ex), add_generation_prompt=True)
        a = tok(recipe.render_answer(ex), add_special_tokens=False)["input_ids"] + [tok.eos_token_id]
        rows.append(recipe.mask_labels(p, a, max_len))

    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()
    lora_args = {k: v for k, v in recipe.LORA.items()}
    model = get_peft_model(model, LoraConfig(**lora_args))
    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=2e-4, weight_decay=0.0)
    batch, accum = 4, 4
    steps = int(len(rows) * iters_epochs / (batch * accum)) or 1
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / 20) * max(0.0, 1 - s / max(1, steps)))
    model.train()
    t0 = time.time()
    import random
    rng = random.Random(0)
    order = list(range(len(rows)))
    step = 0
    while step < steps:
        rng.shuffle(order)
        for i in range(0, len(order) - batch + 1, batch):
            chunk = [rows[j] for j in order[i:i + batch]]
            L = max(len(x[0]) for x in chunk)
            ids = torch.full((batch, L), tok.pad_token_id, dtype=torch.long)
            lab = torch.full((batch, L), -100, dtype=torch.long)
            att = torch.zeros((batch, L), dtype=torch.long)
            for r, (x, y) in enumerate(chunk):
                ids[r, :len(x)] = torch.tensor(x); lab[r, :len(y)] = torch.tensor(y); att[r, :len(x)] = 1
            out = model(input_ids=ids.cuda(), attention_mask=att.cuda(), labels=lab.cuda())
            (out.loss / accum).backward()
            if (i // batch + 1) % accum == 0:
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                opt.step(); sched.step(); opt.zero_grad()
                step += 1
                if step % 10 == 0:
                    print(f"step {step}/{steps} loss {out.loss.item():.4f}", flush=True)
                if step >= steps:
                    break
    minutes = round((time.time() - t0) / 60, 1)

    # measure on the frozen eval split, greedy, as served
    model.eval()
    tok.padding_side = "left"
    tp = {l: 0 for l in LABELS}; fp = dict(tp); fn = dict(tp)
    correct = valid = hits = 0
    for i in range(0, len(evals), 8):
        group = evals[i:i + 8]
        prompts = [tok.apply_chat_template(recipe.prompt_messages(ex), add_generation_prompt=True, tokenize=False) for ex in group]
        enc = tok(prompts, return_tensors="pt", padding=True, add_special_tokens=False).to("cuda")
        with torch.no_grad():
            gen = model.generate(**enc, max_new_tokens=200, do_sample=False, pad_token_id=tok.pad_token_id)
        for ex, g in zip(group, gen):
            pred = parse(tok.decode(g[enc["input_ids"].shape[1]:], skip_special_tokens=True))
            if not pred:
                fn[ex["label"]] += 1; continue
            valid += 1
            if pred["label"] == ex["label"]:
                correct += 1; tp[ex["label"]] += 1
                if evidence_ok(pred, ex):
                    hits += 1
            else:
                fp[pred["label"]] += 1; fn[ex["label"]] += 1
    n = len(evals)
    f1 = {}
    for l in LABELS:
        p = tp[l] / (tp[l] + fp[l]) if tp[l] + fp[l] else 0
        r = tp[l] / (tp[l] + fn[l]) if tp[l] + fn[l] else 0
        f1[l] = round(2 * p * r / (p + r), 3) if p + r else 0
    report = {"model": f"zeus/out/zeus-{version}", "base": base, "n": n, "label_accuracy": round(correct / n, 3) if n else 0,
              "json_valid": round(valid / n, 3) if n else 0, "evidence_hit": round(hits / n, 3) if n else 0, "f1": f1}

    out = os.path.join(work, "out")
    model.save_pretrained(os.path.join(out, "peft"))
    cfg_path = os.path.join(out, "peft", "adapter_config.json")
    cfg = recipe.peft_config_for_cloudflare(json.load(open(cfg_path)))
    json.dump(cfg, open(cfg_path, "w"), indent=2)
    summary = {"base": base, "framework": "peft-cloud", "gpu": GPU, "train_examples": len(rows), "eval_examples": n, "epochs": iters_epochs,
               "steps": steps, "batch": batch * accum, "lr": 2e-4, "lora": recipe.LORA, "minutes": minutes, "system_folded": True}
    json.dump(report, open(os.path.join(out, "eval.json"), "w"), indent=2)
    json.dump(summary, open(os.path.join(out, "train_summary.json"), "w"), indent=2)
    print(json.dumps(report), flush=True)
    return _tar([(out, "out")])


@app.local_entrypoint()
def main(version: str, epochs: float = 1.0, eval_limit: int = 200, import_n: int = 1500):
    py = sys.executable
    os.chdir(REPO)
    subprocess.run([py, "zeus/validate_gold.py"], check=True)
    if import_n > 0:
        subprocess.run([py, "zeus/import_corpora.py", "--corpus", "vitaminc", "--n", str(import_n)], check=False)
    subprocess.run([py, "zeus/build_dataset.py"], check=True)
    # Only what training needs: the splits, gold and imported sets, and the helpers (not the corpus cache).
    parts = [(f"zeus/data/{f}", f"zeus/data/{f}") for f in ("train.jsonl", "eval.jsonl") if os.path.exists(f"zeus/data/{f}")]
    parts += [(f"zeus/data/{d}", f"zeus/data/{d}") for d in ("gold", "imported") if os.path.isdir(f"zeus/data/{d}")]
    parts += [("zeus/eval.py", "zeus/eval.py"), ("zeus/train_lora.py", "zeus/train_lora.py"), ("zeus/cloud/recipe.py", "zeus/cloud/recipe.py")]
    payload = _tar(parts)
    result = train_remote.remote(payload, version, os.environ.get("HF_TOKEN", ""), epochs, eval_limit)
    tmp = os.path.join(REPO, "zeus", "out", f".cloud-{version}")
    os.makedirs(tmp, exist_ok=True)
    tarfile.open(fileobj=io.BytesIO(result), mode="r:gz").extractall(tmp)
    dest = os.path.join(REPO, "zeus", "out", f"zeus-{version}")
    peft = dest + "-peft"
    os.makedirs(dest, exist_ok=True)
    os.makedirs(peft, exist_ok=True)
    for f in ("eval.json", "train_summary.json"):
        os.replace(os.path.join(tmp, "out", f), os.path.join(dest, f))
    for f in os.listdir(os.path.join(tmp, "out", "peft")):
        os.replace(os.path.join(tmp, "out", "peft", f), os.path.join(peft, f))
    print(open(os.path.join(dest, "eval.json")).read())

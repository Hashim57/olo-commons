#!/usr/bin/env python3
"""Publish a measured cloud version of Zeus on the Hugging Face Hub: the LoRA adapter and a model card written
from the measured files. Nothing on the card is typed by hand or estimated.

  python3 zeus/cloud/publish_hf.py v16                 # card only, into zeus/out/zeus-v16-peft/README.md
  python3 zeus/cloud/publish_hf.py v16 --upload        # also upload (HF_WRITE_TOKEN, repo from HF_MODEL_REPO)

Run by .github/workflows/zeus-train.yml after a version becomes the best Cloudflare-servable one (the same rule
that decides what Cloudflare serves, zeus/promote.py), and by .github/workflows/zeus-publish-hf.yml by hand.
The adapter is the one Cloudflare accepts (rank-8 LoRA on q_proj and v_proj of Mistral 7B Instruct v0.2), so
anyone can load it with transformers and peft. The token comes only from the HF_WRITE_TOKEN environment
variable (a GitHub secret); the repo id from HF_MODEL_REPO, default Heliusnetwork/zeus.
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ZEUS = os.path.dirname(HERE)
DEFAULT_REPO = "Heliusnetwork/zeus"
ADAPTER_FILES = ("adapter_config.json", "adapter_model.safetensors")


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def pct(x):
    return "not measured" if x is None else f"{100 * float(x):.1f}%"


def model_card(version, ev, ext, summary, repo, date):
    """The README.md the Hub shows: what Zeus does, its measured scores, how it was trained, its data and
    licences, how to use it and its limits. Held-out numbers first; the saturated frozen split is listed, not led with."""
    base = ev.get("base") or summary.get("base") or "mistralai/Mistral-7B-Instruct-v0.2"
    vit, ev3, ev2, agg = (ext.get(k) or {} for k in ("vitaminc_dev", "eval_v3", "eval_v2", "llm_aggrefact"))
    rows = [("VitaminC dev (300 human-written claims, held out)", vit.get("label_accuracy")),
            ("Commons eval v3 (frozen, hard patterns, n=200)", ev3.get("label_accuracy")),
            ("Commons eval v2 (frozen, harder split, n=200)", ev2.get("label_accuracy")),
            (f"Commons eval (frozen first split, n={ev.get('n', '?')})", ev.get("label_accuracy"))]
    if isinstance(agg.get("balanced_accuracy"), (int, float)):
        rows.insert(1, (f"LLM-AggreFact (balanced accuracy, sample of {agg.get('n')})", agg["balanced_accuracy"] / 100))
    lora = summary.get("lora") or {}
    lines = [
        "---",
        "license: apache-2.0",
        f"base_model: {base}",
        "library_name: peft",
        "pipeline_tag: text-generation",
        "tags:",
        "- fact-checking",
        "- claim-verification",
        "- lora",
        "- olo",
        "language:",
        "- en",
        "---",
        "",
        f"# Zeus {version}: open claim verification",
        "",
        "Zeus reads a claim and a few passages and says whether the passages **support** it, **contradict** it or **do not cover** it. It quotes the exact words that carry the evidence. "
        "It is the checker behind [Olo](https://helius-olo.io), which tests every sentence of an answer against sources from the open [Olo Commons](https://heliusnetwork.app/olo). "
        "It is built in the open: the data pipeline, training code and every measured score are in [Hashim57/olo-commons](https://github.com/Hashim57/olo-commons) under `zeus/`.",
        "",
        "## Measured scores",
        "",
        f"Measured on {date} for this exact version by `zeus/eval.py`. Nothing here is estimated. The held-out sets come first because the frozen first split has been at or near 100 percent for weeks and no longer shows progress.",
        "",
        "| Set | Label accuracy |",
        "|---|---|",
    ]
    lines += [f"| {name} | {pct(v)} |" for name, v in rows]
    lines += [
        "",
        f"Evidence hit on the frozen split (quoted span found in the right passage): {pct(ev.get('evidence_hit'))}. JSON valid: {pct(ev.get('json_valid'))}.",
        "",
        "## Training",
        "",
        f"- Base model: `{base}` (Apache 2.0).",
        f"- Method: LoRA rank {lora.get('r', '?')} on {', '.join(lora.get('target_modules') or ['q_proj', 'v_proj'])}, learning rate {summary.get('lr', '?')}, batch {summary.get('batch', '?')}, "
        f"{summary.get('steps', '?')} optimiser steps in {summary.get('minutes', '?')} minutes on one {summary.get('gpu', 'cloud GPU')}.",
        f"- Training examples: {summary.get('train_examples', '?'):,}." if isinstance(summary.get("train_examples"), int) else "- Training examples: not recorded.",
        "- Trained by the public GitHub workflow `zeus-train.yml` on a cloud GPU; the full log of every version is `zeus/STATUS.md`.",
        "",
        "## Data and licences",
        "",
        "Three parts, described in [`zeus/DATA_CARD.md`](https://github.com/Hashim57/olo-commons/blob/main/zeus/DATA_CARD.md): examples made by rule from Olo Commons atoms (each atom keeps its own source licence), "
        "hand-written gold examples checked against the atoms they quote, and human-written claim and evidence pairs from VitaminC (Schuster, Fisch and Barzilay, NAACL 2021, CC BY-SA 3.0). "
        "Text from Wikipedia and VitaminC is CC BY-SA: attribute Wikipedia and the VitaminC authors. The adapter is released under Apache 2.0, like its base model.",
        "",
        "## Use",
        "",
        "```python",
        "from transformers import AutoModelForCausalLM, AutoTokenizer",
        "from peft import PeftModel",
        "",
        f'base = AutoModelForCausalLM.from_pretrained("{base}", torch_dtype="auto", device_map="auto")',
        f'model = PeftModel.from_pretrained(base, "{repo}")',
        f'tok = AutoTokenizer.from_pretrained("{base}")',
        "```",
        "",
        "Send one user turn with the system prompt from `zeus/cloud/recipe.py` followed by:",
        "",
        "```",
        "Claim: <claim>",
        "",
        "Passages:",
        "[p1] (<source>) <text>",
        "",
        "[p2] (<source>) <text>",
        "```",
        "",
        'The answer is one JSON object: `{"label": "supported" | "contradicted" | "not_covered", "evidence": [{"passage": "<id>", "quote": "<exact words>"}], "rationale": "<one sentence>"}`.',
        "",
        "## Limits",
        "",
        "Most training contradictions are made by rule (one changed relation, year, number or name), so subtle contradictions are harder for it than clear ones; "
        "the weakest pattern in each version is reported in the weekly learning report. It checks claims against the passages it is given and knows nothing beyond them. "
        "It is not a substitute for reading the source: every Olo answer carries its passages so a person can.",
        "",
        f"Card generated by `zeus/cloud/publish_hf.py` on {datetime.now(timezone.utc).date().isoformat()} from `zeus/out/zeus-{version}/`.",
        "",
    ]
    return "\n".join(lines)


def measured_date(version, status_path=os.path.join(ZEUS, "STATUS.md")):
    for line in open(status_path, encoding="utf-8"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) > 2 and cells[1] == version:
            return cells[0]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--upload", action="store_true", help="upload to the Hub (needs HF_WRITE_TOKEN)")
    ap.add_argument("--repo", default=os.environ.get("HF_MODEL_REPO") or DEFAULT_REPO)
    args = ap.parse_args()
    v = args.version if args.version.startswith("v") else "v" + args.version
    out = os.path.join(ZEUS, "out", f"zeus-{v}")
    peft = out + "-peft"
    ev = load(os.path.join(out, "eval.json"))
    date = measured_date(v)
    if not ev or not date:
        sys.exit(f"{v} is not measured (no eval.json or no STATUS row): only measured versions are published")
    card = model_card(v, ev, load(os.path.join(out, "eval-external.json")) or {}, load(os.path.join(out, "train_summary.json")) or {}, args.repo, date)
    os.makedirs(peft, exist_ok=True)
    with open(os.path.join(peft, "README.md"), "w", encoding="utf-8") as f:
        f.write(card)
    print(f"model card written to {peft}/README.md")
    if not args.upload:
        return
    missing = [f for f in ADAPTER_FILES if not os.path.exists(os.path.join(peft, f))]
    if missing:
        sys.exit(f"adapter files missing in {peft}: {', '.join(missing)}")
    token = os.environ.get("HF_WRITE_TOKEN")
    if not token:
        print("::warning::HF_WRITE_TOKEN is not set; the card was written but nothing was uploaded")
        return
    from huggingface_hub import HfApi
    api = HfApi(token=token)
    api.create_repo(args.repo, repo_type="model", private=False, exist_ok=True)
    api.upload_folder(repo_id=args.repo, repo_type="model", folder_path=peft, allow_patterns=list(ADAPTER_FILES) + ["README.md"],
                      commit_message=f"Zeus {v}: adapter and model card from measured files")
    api.create_tag(args.repo, tag=v, repo_type="model", exist_ok=True)
    print(f"uploaded {v} to https://huggingface.co/{args.repo} (tag {v})")


if __name__ == "__main__":
    main()

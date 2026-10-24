#!/usr/bin/env python3
"""Publish a measured Zeus version: fuse the adapter into its base, write a
model card straight from the measured numbers, and (optionally) upload.

  python3 zeus/publish.py --version v5                       # fuse + card into zeus/out/zeus-v5-fused/
  python3 zeus/publish.py --version v5 --upload helius/zeus  # also upload (needs HF_TOKEN in the environment)
  python3 zeus/publish.py --version v5 --card-only           # just write the card (no MLX needed)

The card is generated, never typed by hand: scores come from eval.json, the
training details from train_summary.json and the row in STATUS.md, the data
description from DATA_CARD.md. Nothing is claimed that was not measured.
Weights never enter git; the fused model is written next to the adapter.
Runs on an Apple Silicon Mac for MLX adapters (mlx_lm.fuse); the card part
runs anywhere.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from promote import measured_rows  # noqa: E402


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def status_notes(status_path, version):
    """The Notes cell of the version's row in STATUS.md, or an empty string."""
    for line in open(status_path, encoding="utf-8"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 7 and cells[1] == version:
            return cells[6]
    return ""


def model_card(version, ev, summary, row, notes, upload_repo=None):
    base = ev.get("base") or summary.get("base") or (row or {}).get("base") or "unknown"
    f1 = ev.get("f1") or {}
    lines = [
        "---",
        "license: apache-2.0",
        f"base_model: {base}",
        "tags:",
        "- fact-checking",
        "- claim-verification",
        "- olo",
        "- mlx",
        "language:",
        "- en",
        "---",
        "",
        f"# Zeus {version}: claim verification for Olo Commons",
        "",
        "Zeus decides whether retrieved passages **support**, **contradict** or **do not cover** a claim, and quotes the span that carries the evidence. It is the verification layer of [Olo](https://heliusnetwork.app/olo), the open knowledge base built by Helius Network, and it was trained in the open: data pipeline, training scripts and every measured score are in [Hashim57/olo-commons](https://github.com/Hashim57/olo-commons) under `zeus/`.",
        "",
        "## Measured scores",
        "",
        "Every number below was produced by `zeus/eval.py` on the frozen Commons eval split for this exact version. Nothing is estimated.",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Eval examples | {ev.get('n', 'n/a')} |",
        f"| Label accuracy | {ev.get('label_accuracy', 'n/a')} |",
        f"| Evidence hit (quoted span found in the right passage) | {ev.get('evidence_hit', 'n/a')} |",
        f"| JSON valid | {ev.get('json_valid', 'n/a')} |",
        f"| F1 supported / contradicted / not covered | {f1.get('supported', 'n/a')} / {f1.get('contradicted', 'n/a')} / {f1.get('not_covered', 'n/a')} |",
        "",
        "## Training",
        "",
        f"- Base model: `{base}` (Apache 2.0).",
        f"- Method: LoRA with {summary.get('framework', 'mlx')}, {summary.get('iters', 'n/a')} iterations, {summary.get('num_layers', 'n/a')} layers, learning rate {summary.get('lr', 'n/a')}, {summary.get('minutes', 'n/a')} minutes on an Apple Silicon Mac.",
        f"- Training examples: {summary.get('train_examples', (row or {}).get('train_examples', 'n/a'))}; eval examples held out by a stable hash of the atom id.",
        f"- Date: {(row or {}).get('date', 'n/a')}.",
    ]
    if notes:
        lines.append(f"- Notes from the build log: {notes}")
    lines += [
        "",
        "## Data",
        "",
        "Three parts, described in full in [`zeus/DATA_CARD.md`](https://github.com/Hashim57/olo-commons/blob/main/zeus/DATA_CARD.md): examples made by rule from Olo Commons atoms (each with its source licence), hand-written gold examples validated against the atoms they quote, and human-written pairs imported from open corpora (VitaminC, CC BY-SA 3.0) when the version trained with them. Text from Wikipedia and VitaminC is CC BY-SA; attribute Wikipedia and Schuster, Fisch and Barzilay (2021).",
        "",
        "## Prompt format",
        "",
        "System prompt and user format are exactly those in `zeus/train_lora.py`:",
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
        "## Use",
        "",
        "```python",
        "from mlx_lm import load, generate",
        f"model, tok = load({json.dumps(upload_repo or base)}" + ("" if upload_repo else f", adapter_path='zeus/out/zeus-{version}'") + ")",
        "```",
        "",
        "Or serve it with `bash zeus/serve_mac.sh` and call `/v1/chat/completions`.",
        "",
        "## Limits",
        "",
        "A small model trained on a few thousand examples. Contradictions in the Commons data are mostly rule-made (one changed relation, year, number or name), so judgement on subtle contradictions is weaker than on clear ones; the eval set grows with the Commons, so scores across versions are indicative rather than like-for-like. Not a substitute for reading the source; every answer carries the passages so a person can.",
        "",
        f"Card generated by `zeus/publish.py` on {datetime.now(timezone.utc).date().isoformat()} from `zeus/out/zeus-{version}/eval.json` and `train_summary.json`.",
        "",
    ]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--out-dir", default=os.path.join(HERE, "out"))
    ap.add_argument("--status", default=os.path.join(HERE, "STATUS.md"))
    ap.add_argument("--card-only", action="store_true")
    ap.add_argument("--upload", help="Hugging Face repo id to upload the fused model to (needs HF_TOKEN)")
    args = ap.parse_args()
    v = args.version if args.version.startswith("v") else "v" + args.version
    adapter = os.path.join(args.out_dir, f"zeus-{v}")
    ev_path = os.path.join(adapter, "eval.json")
    if not os.path.exists(ev_path):
        sys.exit(f"{ev_path} missing: only measured versions are published")
    ev = load_json(ev_path)
    summary = load_json(os.path.join(adapter, "train_summary.json")) if os.path.exists(os.path.join(adapter, "train_summary.json")) else {}
    rows = measured_rows(args.status)
    if v not in rows:
        sys.exit(f"{v} has no measured row in STATUS.md: record it first")
    fused = os.path.join(args.out_dir, f"zeus-{v}-fused")
    os.makedirs(fused, exist_ok=True)
    card = model_card(v, ev, summary, rows.get(v), status_notes(args.status, v), args.upload)
    with open(os.path.join(fused, "README.md"), "w", encoding="utf-8") as f:
        f.write(card)
    print(f"model card written to {fused}/README.md")
    if args.card_only:
        return
    if not os.path.exists(os.path.join(adapter, "adapters.safetensors")):
        sys.exit(f"no adapter weights in {adapter}; fuse on the machine that trained it")
    cmd = [sys.executable, "-m", "mlx_lm.fuse", "--model", ev.get("base") or summary.get("base"), "--adapter-path", adapter, "--save-path", fused]
    if args.upload:
        if not os.environ.get("HF_TOKEN"):
            sys.exit("set HF_TOKEN to upload")
        cmd += ["--upload-repo", args.upload]
    print(" ".join(cmd))
    subprocess.run(cmd, check=True)
    print(f"fused model in {fused}" + (f", uploaded to {args.upload}" if args.upload else ""))


if __name__ == "__main__":
    main()

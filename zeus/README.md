# Zeus

Zeus is Olo's verification layer: given a claim and a set of retrieved passages from Olo Commons, it decides whether the passages **support**, **contradict** or **do not cover** the claim, and it says which passage and which sentence carry the evidence. It is the piece that turns Olo from "a chatbot that cites" into "a system whose every claim is checked".

This directory holds everything needed to build Zeus as a fine-tuned open-weight model. The data comes from the Commons, the training is a LoRA on a small instruction model, and the eval is a fixed held-out set so that every version can be compared honestly.

## Base model

`Qwen/Qwen2.5-7B-Instruct` (Apache 2.0) is the default, with `Qwen/Qwen2.5-1.5B-Instruct` as the small variant for CPU inference inside Edge Functions later. Reasons: permissive licence (Llama's is not), strong on structured JSON output and long context (128k), small enough to fine-tune with a single 24 GB GPU using 4-bit QLoRA, and a 1.5B sibling that shares the tokenizer and chat template, so one dataset serves both. The daily improvement task re-checks this choice against newly released open-weight models and records its reasoning in `STATUS.md`; it changes the base only when a candidate beats Qwen on `eval/` under the same licence terms.

## Task format

One example is a JSON object:

```json
{
  "claim": "Project Gutenberg was founded in 1971.",
  "passages": [
    {"id": "a1", "source": "wikipedia", "url": "https://en.wikipedia.org/wiki/Project_Gutenberg", "text": "Project Gutenberg ... founded in 1971 by American writer Michael S. Hart ..."},
    {"id": "a2", "source": "wikidata", "url": "...", "text": "..."}
  ],
  "label": "supported",
  "evidence": [{"passage": "a1", "quote": "founded in 1971 by American writer Michael S. Hart"}],
  "rationale": "The Wikipedia passage states the founding year directly."
}
```

Labels: `supported`, `contradicted`, `not_covered`. The model is trained to answer with exactly that JSON (label, evidence, rationale), nothing else.

## Where the examples come from

`build_dataset.py` pulls recent atoms through the public `olo_export` RPC and makes examples three ways, all with provenance kept:

1. **Supported**: a sentence from an atom's summary becomes the claim; the atom and two unrelated atoms are the passages.
2. **Contradicted**: the same sentence with one fact changed by a rule: half the time a relation word flipped for its opposite (before/after, increased/decreased, north/south, is/is not), otherwise a year, a number, or a name swapped for another atom's name. The original atom is still a passage, so the model learns to read closely rather than match topics, and the relation flips stop it learning that an odd-looking digit means contradicted.
3. **Not covered**: a claim from one atom with passages drawn only from atoms far from it in the graph.

Rule-made contradictions are a start, not the finish. The improvement task's standing job is to raise the share of human-grade examples: hand-written ones in `data/gold/`, and (when an API key is available) LLM-written hard negatives that a rule could not make.

## Files

- `build_dataset.py`: export from the Commons, make examples, write `data/train.jsonl`, `data/eval.jsonl` and `data/meta.json` (counts, including `gold` and `train_total`; the eval split is frozen by atom id, so new data never leaks into it). Unit tests: `python3 -m pytest zeus/tests` (no network).
- `train_lora.py`: QLoRA fine-tune with TRL. One GPU, about 40 minutes for 5k examples on a 7B at 4-bit.
- `eval.py`: label accuracy, evidence hit rate (did the quoted span come from the right passage), and JSON validity, for any model path or adapter.
- `serve.py`: a minimal OpenAI-compatible endpoint for the adapter, so helius-olo.io can call Zeus the same way it calls any model.
- `STATUS.md`: what the latest build scored and what changed. Updated by every run, human or scheduled.

## Run it

```
pip install -r zeus/requirements.txt
python zeus/build_dataset.py --supabase-url https://<project>.supabase.co --anon-key <anon key>
python zeus/train_lora.py --base Qwen/Qwen2.5-7B-Instruct --out zeus/out/zeus-v0
python zeus/eval.py --adapter zeus/out/zeus-v0
```

Training needs a GPU. On an Apple Silicon Mac, one command does the whole thing on the Mac's own GPU with MLX:

```
bash zeus/train_mac.sh v1
```

It builds the dataset, picks the 7B or 1.5B base by how much memory the Mac has, trains a LoRA, evaluates it on the frozen split and writes `zeus/out/zeus-v1/eval.json` and `train_summary.json`. Commit those two files (never the weights). On Linux with an NVIDIA card use `train_lora.py` instead. Dataset building and eval run anywhere.

## Hands-free training (how the daily run trains)

The scheduled cloud run cannot type on the Mac, so it asks for training through the repository: `python3 zeus/request_training.py --reason "..."` writes `zeus/TRAIN_REQUEST.json` with the next version; the run commits and pushes it. A launchd agent on the Mac (`zeus/mac/`, installed once with `bash zeus/mac/install.sh`) polls every 30 minutes, trains the requested version on the Mac GPU, commits `eval.json` and `train_summary.json` (or `FAILED.txt` with the log tail), removes the request and pushes. The next cloud run reads whatever landed under `zeus/out/` and writes the STATUS row, or records the failure and fixes the cause. A pending request is never overwritten; a version that already has results is never trained twice.

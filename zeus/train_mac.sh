#!/bin/bash
# One-command Zeus training on an Apple Silicon Mac (uses the Mac GPU via MLX).
#   bash zeus/train_mac.sh <version>            e.g. bash zeus/train_mac.sh v1
# Needs: macOS on Apple Silicon, Xcode command line tools (xcode-select --install), internet.
# Writes zeus/out/zeus-<version>/{eval.json,train_summary.json}; commit those two files.
set -euo pipefail
V="${1:-v1}"
cd "$(dirname "$0")/.."
if [ "$(uname -m)" != "arm64" ]; then echo "MLX needs Apple Silicon; use zeus/train_lora.py on a GPU box instead"; exit 1; fi
[ -d .zeus-venv ] || python3 -m venv .zeus-venv
. .zeus-venv/bin/activate
pip -q install --upgrade pip
pip -q install mlx-lm requests
ANON="${SUPABASE_ANON_KEY:-$(curl -fsSL https://heliusnetwork.app/assets/config.js | sed -n "s/.*SUPABASE_ANON_KEY: *'\([^']*\)'.*/\1/p" | head -1)}"
# A gold line with a quote that is not in its passage would teach the wrong thing; refuse to train on one.
python3 zeus/validate_gold.py
# Open fact-checking corpora (VitaminC, CC BY-SA 3.0) train alongside the Commons examples. IMPORT_N=0 turns it off.
if [ "${IMPORT_N:-1500}" -gt 0 ]; then python3 zeus/import_corpora.py --corpus vitaminc --n "${IMPORT_N:-1500}" || echo "corpus import failed; training on Commons data only"; fi
python3 zeus/build_dataset.py --anon-key "$ANON"
# sysctl lives in /usr/sbin, which launchd's PATH leaves out; call it by full path.
SYSCTL="$(command -v sysctl || echo /usr/sbin/sysctl)"
MEM_BYTES="$("$SYSCTL" -n hw.memsize 2>/dev/null || echo 0)"
MEM_GB=$(( ${MEM_BYTES:-0} / 1073741824 ))
if [ "$MEM_GB" -le 0 ]; then echo "could not read the Mac's memory size; using the 1.5B base to be safe"; fi
# Profile. "cloudflare" (the default from v6): Mistral 7B Instruct v0.2 (Apache 2.0), the base Cloudflare
# Workers AI serves uploaded LoRA adapters on, rank 8 on q_proj and v_proj in all 32 layers, so the
# adapter can be uploaded as is (zeus/cloudflare/). Fits a 16 GB Mac at 4 bit with gradient checkpointing.
# "qwen": the v0 to v5 recipe, kept for comparison.
PROFILE="${ZEUS_PROFILE:-cloudflare}"
EXTRA=()
if [ "$PROFILE" = "cloudflare" ]; then
  BASE="mlx-community/Mistral-7B-Instruct-v0.2-4bit"; LAYERS=32
  EXTRA=(--lora-rank 8 --lora-keys self_attn.q_proj,self_attn.v_proj --batch-size 1 --max-seq-length 2048 --lr 1e-4)
else
  BASE="mlx-community/Qwen2.5-7B-Instruct-4bit"; LAYERS=16
  if [ "$MEM_GB" -lt 24 ]; then BASE="mlx-community/Qwen2.5-1.5B-Instruct-4bit"; LAYERS=12; echo "Mac has ${MEM_GB} GB, using the 1.5B base"; fi
fi
python3 zeus/train_mlx.py --base "$BASE" --num-layers "$LAYERS" --out "zeus/out/zeus-$V" --iters "${ITERS:-600}" ${EXTRA[@]+"${EXTRA[@]}"}
if [ "$PROFILE" = "cloudflare" ]; then
  # The upload-ready copy (PEFT layout Cloudflare reads); weights stay out of git.
  python3 zeus/export_peft.py --adapter "zeus/out/zeus-$V" --out "zeus/out/zeus-$V-peft" --base-hf mistralai/Mistral-7B-Instruct-v0.2 --model-type mistral || echo "PEFT export failed; the adapter still works locally"
fi
echo
echo "Done. Commit the results:"
echo "  git add -f zeus/out/zeus-$V/eval.json zeus/out/zeus-$V/train_summary.json && git commit -m 'zeus: $V results' && git push"

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
python3 zeus/build_dataset.py --anon-key "$ANON"
MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
BASE="mlx-community/Qwen2.5-7B-Instruct-4bit"; LAYERS=16
if [ "$MEM_GB" -lt 24 ]; then BASE="mlx-community/Qwen2.5-1.5B-Instruct-4bit"; LAYERS=12; echo "Mac has ${MEM_GB} GB, using the 1.5B base"; fi
python3 zeus/train_mlx.py --base "$BASE" --num-layers "$LAYERS" --out "zeus/out/zeus-$V" --iters "${ITERS:-600}"
echo
echo "Done. Commit the results:"
echo "  git add -f zeus/out/zeus-$V/eval.json zeus/out/zeus-$V/train_summary.json && git commit -m 'zeus: $V results' && git push"

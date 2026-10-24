#!/usr/bin/env python3
"""Convert an MLX LoRA adapter (mlx_lm.lora output) into the PEFT layout that
Cloudflare Workers AI, Hugging Face PEFT, vLLM and TGI read.

  python3 zeus/export_peft.py --adapter zeus/out/zeus-v6 --out zeus/out/zeus-v6-peft \
      --base-hf mistralai/Mistral-7B-Instruct-v0.2 --model-type mistral

Writes exactly the two files Cloudflare accepts: adapter_model.safetensors and
adapter_config.json. The maths: mlx_lm computes  y = W x + scale * (x @ A) @ B
with A of shape (in, r) and B of shape (r, out); PEFT computes
y = W x + (alpha / r) * B' (A' x) with A' of shape (r, in) and B' of shape
(out, r). So A' = A^T, B' = B^T and alpha = scale * r. Keys move from
"model.layers.N.self_attn.q_proj.lora_a" to
"base_model.model.model.layers.N.self_attn.q_proj.lora_A.weight".

Needs numpy only (safetensors is read and written directly; the format is an
8-byte header length, a JSON header and raw little-endian tensors). Refuses an
adapter Cloudflare would reject: rank above 32, or a file of 300 MB or more.
"""
import argparse
import json
import os
import re
import struct
import sys

import numpy as np

CF_MAX_RANK = 32
CF_MAX_BYTES = 300 * 1024 * 1024
DTYPES = {"F32": np.float32, "F16": np.float16, "BF16": "bf16", "F64": np.float64}


def read_safetensors(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(n))
        blob = f.read()
    out = {}
    for name, meta in header.items():
        if name == "__metadata__":
            continue
        a, b = meta["data_offsets"]
        raw = blob[a:b]
        kind = DTYPES.get(meta["dtype"])
        if kind is None:
            raise SystemExit(f"unsupported dtype {meta['dtype']} for {name}")
        if kind == "bf16":
            arr = (np.frombuffer(raw, dtype="<u2").astype(np.uint32) << 16).view(np.float32)
        else:
            arr = np.frombuffer(raw, dtype=np.dtype(kind).newbyteorder("<"))
        out[name] = arr.reshape(meta["shape"]).astype(np.float32)
    return out


def write_safetensors(path, tensors, metadata=None):
    header, chunks, offset = {}, [], 0
    for name in sorted(tensors):
        arr = np.ascontiguousarray(tensors[name].astype("<f2"))
        data = arr.tobytes()
        header[name] = {"dtype": "F16", "shape": list(arr.shape), "data_offsets": [offset, offset + len(data)]}
        chunks.append(data)
        offset += len(data)
    if metadata:
        header["__metadata__"] = {k: str(v) for k, v in metadata.items()}
    hb = json.dumps(header, separators=(",", ":")).encode()
    hb += b" " * ((8 - len(hb) % 8) % 8)  # keep tensor data 8-byte aligned
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(hb)))
        f.write(hb)
        for c in chunks:
            f.write(c)


KEY = re.compile(r"^(?:model\.)?(?P<path>.*?)\.(?P<which>lora_a|lora_b)$")


def convert(mlx_tensors, scale, rank):
    """MLX LoRA tensors to PEFT tensors, plus the target module names found."""
    out, modules = {}, set()
    for name, arr in mlx_tensors.items():
        m = KEY.match(name)
        if not m:
            raise SystemExit(f"unexpected tensor {name}: not a LoRA a or b matrix")
        path = m.group("path")  # e.g. layers.0.self_attn.q_proj
        modules.add(path.rsplit(".", 1)[-1])
        which = "lora_A" if m.group("which") == "lora_a" else "lora_B"
        if arr.ndim != 2:
            raise SystemExit(f"{name} has shape {arr.shape}; expected a matrix")
        if which == "lora_A" and arr.shape[1] != rank:
            raise SystemExit(f"{name} has shape {arr.shape}; expected (in, {rank})")
        if which == "lora_B" and arr.shape[0] != rank:
            raise SystemExit(f"{name} has shape {arr.shape}; expected ({rank}, out)")
        out[f"base_model.model.model.{path}.{which}.weight"] = arr.T
    return out, sorted(modules)


def peft_config(base_hf, model_type, rank, scale, modules):
    return {
        "peft_type": "LORA",
        "task_type": "CAUSAL_LM",
        "base_model_name_or_path": base_hf,
        "model_type": model_type,
        "r": rank,
        "lora_alpha": scale * rank,
        "lora_dropout": 0.0,
        "target_modules": modules,
        "bias": "none",
        "fan_in_fan_out": False,
        "inference_mode": True,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", required=True, help="mlx_lm adapter folder (adapters.safetensors + adapter_config.json)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--base-hf", required=True, help="the unquantized base on Hugging Face, e.g. mistralai/Mistral-7B-Instruct-v0.2")
    ap.add_argument("--model-type", required=True, choices=["mistral", "gemma", "llama"], help="what Cloudflare calls the base family")
    a = ap.parse_args()
    cfg_path = os.path.join(a.adapter, "adapter_config.json")
    cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
    lp = cfg.get("lora_parameters", {})
    rank, scale = int(lp.get("rank", 8)), float(lp.get("scale", 20.0))
    if rank > CF_MAX_RANK:
        sys.exit(f"rank {rank} is above Cloudflare's limit of {CF_MAX_RANK}")
    weights = os.path.join(a.adapter, "adapters.safetensors")
    if not os.path.exists(weights):
        sys.exit(f"no {weights}; train first")
    tensors, modules = convert(read_safetensors(weights), scale, rank)
    os.makedirs(a.out, exist_ok=True)
    out_w = os.path.join(a.out, "adapter_model.safetensors")
    write_safetensors(out_w, tensors, {"format": "pt"})
    size = os.path.getsize(out_w)
    if size >= CF_MAX_BYTES:
        sys.exit(f"{out_w} is {size} bytes; Cloudflare accepts under {CF_MAX_BYTES}")
    with open(os.path.join(a.out, "adapter_config.json"), "w") as f:
        json.dump(peft_config(a.base_hf, a.model_type, rank, scale, modules), f, indent=2)
    print(f"PEFT adapter in {a.out}: {len(tensors)} tensors, rank {rank}, alpha {scale * rank:g}, modules {modules}, {size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()

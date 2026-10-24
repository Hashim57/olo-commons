"""zeus/export_peft.py: an MLX LoRA adapter becomes a PEFT adapter that computes
exactly the same update, in the two files Cloudflare accepts."""
import json, os, struct, sys

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import export_peft as ep  # noqa: E402

RANK, SCALE, D_IN, D_Q, D_V = 8, 20.0, 64, 64, 16


def mlx_adapter(tmp_path, dtype="F32"):
    rng = np.random.default_rng(0)
    t = {}
    for i in range(2):
        t[f"model.layers.{i}.self_attn.q_proj.lora_a"] = rng.normal(size=(D_IN, RANK)).astype(np.float32)
        t[f"model.layers.{i}.self_attn.q_proj.lora_b"] = rng.normal(size=(RANK, D_Q)).astype(np.float32)
        t[f"model.layers.{i}.self_attn.v_proj.lora_a"] = rng.normal(size=(D_IN, RANK)).astype(np.float32)
        t[f"model.layers.{i}.self_attn.v_proj.lora_b"] = rng.normal(size=(RANK, D_V)).astype(np.float32)
    d = tmp_path / "mlx"; d.mkdir()
    # write as MLX would (float32 or bfloat16)
    header, blob, off = {}, b"", 0
    for k, v in t.items():
        if dtype == "BF16":
            raw = (v.view(np.uint32) >> 16).astype("<u2").tobytes()
        else:
            raw = v.astype("<f4").tobytes()
        header[k] = {"dtype": dtype, "shape": list(v.shape), "data_offsets": [off, off + len(raw)]}
        blob += raw; off += len(raw)
    hb = json.dumps(header).encode()
    (d / "adapters.safetensors").write_bytes(struct.pack("<Q", len(hb)) + hb + blob)
    (d / "adapter_config.json").write_text(json.dumps({"lora_parameters": {"rank": RANK, "scale": SCALE, "dropout": 0.0, "keys": ["self_attn.q_proj", "self_attn.v_proj"]}, "num_layers": 2}))
    return d, t


def test_same_update_after_conversion(tmp_path):
    d, t = mlx_adapter(tmp_path)
    out = tmp_path / "peft"
    sys.argv = ["x", "--adapter", str(d), "--out", str(out), "--base-hf", "mistralai/Mistral-7B-Instruct-v0.2", "--model-type", "mistral"]
    ep.main()
    assert sorted(os.listdir(out)) == ["adapter_config.json", "adapter_model.safetensors"]
    cfg = json.loads((out / "adapter_config.json").read_text())
    assert cfg["r"] == RANK and cfg["lora_alpha"] == SCALE * RANK and cfg["model_type"] == "mistral"
    assert cfg["target_modules"] == ["q_proj", "v_proj"] and cfg["task_type"] == "CAUSAL_LM"
    peft = ep.read_safetensors(str(out / "adapter_model.safetensors"))
    x = np.random.default_rng(1).normal(size=(3, D_IN)).astype(np.float32)
    for i in range(2):
        for mod, d_out in (("q_proj", D_Q), ("v_proj", D_V)):
            A, B = t[f"model.layers.{i}.self_attn.{mod}.lora_a"], t[f"model.layers.{i}.self_attn.{mod}.lora_b"]
            mlx_delta = SCALE * (x @ A) @ B
            Ap = peft[f"base_model.model.model.layers.{i}.self_attn.{mod}.lora_A.weight"]
            Bp = peft[f"base_model.model.model.layers.{i}.self_attn.{mod}.lora_B.weight"]
            assert Ap.shape == (RANK, D_IN) and Bp.shape == (d_out, RANK)
            peft_delta = (cfg["lora_alpha"] / cfg["r"]) * (x @ Ap.T) @ Bp.T
            assert np.abs(mlx_delta - peft_delta).max() / np.abs(mlx_delta).max() < 5e-3  # fp16 storage


def test_reads_bfloat16(tmp_path):
    d, t = mlx_adapter(tmp_path, "BF16")
    got = ep.read_safetensors(str(d / "adapters.safetensors"))
    k = "model.layers.0.self_attn.q_proj.lora_a"
    assert np.allclose(got[k], t[k], rtol=1e-2, atol=1e-2)


def test_refuses_bad_shapes_and_names():
    with pytest.raises(SystemExit):
        ep.convert({"model.layers.0.self_attn.q_proj.weight": np.zeros((2, 2))}, 20.0, 8)
    with pytest.raises(SystemExit):
        ep.convert({"model.layers.0.self_attn.q_proj.lora_a": np.zeros((64, 4))}, 20.0, 8)

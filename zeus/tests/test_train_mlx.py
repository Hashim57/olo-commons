"""Unit tests for the pure helpers in zeus/train_mlx.py (no MLX needed)."""
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import train_mlx as tm  # noqa: E402


def test_last_checkpoint_picks_newest_numbered_adapter(tmp_path):
    assert tm.last_checkpoint(str(tmp_path / "missing")) == (0, None)
    assert tm.last_checkpoint(str(tmp_path)) == (0, None)
    for n in ("0000100", "0000200", "0000250x"):
        (tmp_path / f"{n}_adapters.safetensors").write_text("w")
    (tmp_path / "adapters.safetensors").write_text("w")
    it, path = tm.last_checkpoint(str(tmp_path))
    assert it == 200 and path.endswith("0000200_adapters.safetensors")

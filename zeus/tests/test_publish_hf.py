"""zeus/cloud/publish_hf.py: the Hugging Face model card says only what was measured."""
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud"))
import publish_hf  # noqa: E402

EV = {"n": 200, "label_accuracy": 1.0, "evidence_hit": 0.995, "json_valid": 1.0, "base": "mistralai/Mistral-7B-Instruct-v0.2"}
SUMMARY = {"lora": {"r": 8, "target_modules": ["q_proj", "v_proj"]}, "lr": 2e-4, "batch": 16, "steps": 1034, "minutes": 60.0, "gpu": "A100-40GB", "train_examples": 36255}


def test_card_leads_with_held_out_scores_and_never_invents_one():
    ext = {"vitaminc_dev": {"label_accuracy": 0.733}, "eval_v3": {"label_accuracy": 0.92}, "llm_aggrefact": {"error": "gated"}}
    card = publish_hf.model_card("v22", EV, ext, SUMMARY, "Heliusnetwork/zeus", "2026-11-16")
    assert "library_name: peft" in card and "base_model: mistralai/Mistral-7B-Instruct-v0.2" in card
    assert card.index("VitaminC dev") < card.index("Commons eval (frozen first split")
    assert "| VitaminC dev (300 human-written claims, held out) | 73.3% |" in card
    assert "Commons eval v2 (frozen, harder split, n=200) | not measured |" in card
    assert "AggreFact" not in card, "an unmeasured benchmark is not listed"
    assert 'PeftModel.from_pretrained(base, "Heliusnetwork/zeus")' in card
    assert "36,255" in card and "—" not in card and "–" not in card


def test_card_lists_aggrefact_once_measured():
    card = publish_hf.model_card("v30", EV, {"llm_aggrefact": {"balanced_accuracy": 71.2, "n": 600}}, SUMMARY, "Heliusnetwork/zeus", "2026-12-01")
    assert "| LLM-AggreFact (balanced accuracy, sample of 600) | 71.2% |" in card


def test_only_measured_versions_have_a_date():
    assert publish_hf.measured_date("v16") == "2026-11-04"
    assert publish_hf.measured_date("v9999") is None

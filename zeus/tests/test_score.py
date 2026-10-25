"""eval.score: the one scorer every Zeus path uses. Checked without a model: the
answers are given as text, exactly as a model would return them."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import eval as ev  # noqa: E402

P1 = {"id": "p1", "source": "wikipedia", "url": "https://example.org/a", "text": "Project Gutenberg was founded in 1971 by Michael Hart."}
P2 = {"id": "p2", "source": "arxiv", "url": "https://example.org/b", "text": "The method improves recall on long documents."}


def ex(label, claim="Project Gutenberg was founded in 1971.", evidence=None):
    return {"claim": claim, "passages": [P1, P2], "label": label,
            "evidence": [{"passage": "p1", "quote": "founded in 1971"}] if evidence is None and label != "not_covered" else (evidence or []),
            "rationale": "test"}


def ans(label, quote=None, passage="p1"):
    return json.dumps({"label": label, "evidence": [{"passage": passage, "quote": quote}] if quote else [], "rationale": "r"})


def test_perfect_answers_score_one_everywhere():
    exs = [ex("supported"), ex("contradicted", claim="Project Gutenberg was founded in 1980."), ex("not_covered", claim="Hart was born in Washington.")]
    answers = [ans("supported", "founded in 1971"), ans("contradicted", "founded in 1971"), ans("not_covered")]
    r = ev.score(exs, answers)
    assert r["n"] == 3 and r["label_accuracy"] == 1.0 and r["json_valid"] == 1.0 and r["evidence_hit"] == 1.0
    assert r["f1"] == {"supported": 1.0, "contradicted": 1.0, "not_covered": 1.0}
    assert r["binary_balanced_accuracy"] == 1.0
    for l in ev.LABELS:
        assert r["confusion"][l][l] == 1 and sum(r["confusion"][l].values()) == 1
        assert r["rates"][l] == {"tpr": 1.0, "tnr": 1.0}


def test_confusion_matrix_and_rates_show_where_the_errors_go():
    # Four supported, two contradicted, two not covered. The model says supported to
    # everything except one contradicted example it gets right, and one answer is not JSON.
    exs = [ex("supported")] * 4 + [ex("contradicted")] * 2 + [ex("not_covered")] * 2
    answers = [ans("supported", "founded in 1971")] * 3 + ["I think it is supported"] + [ans("contradicted", "founded in 1971"), ans("supported")] + [ans("supported")] * 2
    r = ev.score(exs, answers)
    c = r["confusion"]
    assert c["supported"] == {"supported": 3, "contradicted": 0, "not_covered": 0, "invalid": 1}
    assert c["contradicted"] == {"supported": 1, "contradicted": 1, "not_covered": 0, "invalid": 0}
    assert c["not_covered"] == {"supported": 2, "contradicted": 0, "not_covered": 0, "invalid": 0}
    assert r["label_accuracy"] == 0.5 and r["json_valid"] == 0.875
    # supported: 3 of 4 positives found (tpr 0.75); 3 of the 4 negatives were wrongly called supported (tnr 0.25)
    assert r["rates"]["supported"] == {"tpr": 0.75, "tnr": 0.25}
    assert r["binary_balanced_accuracy"] == 0.5
    # contradicted: 1 of 2 found, never wrongly predicted
    assert r["rates"]["contradicted"] == {"tpr": 0.5, "tnr": 1.0}
    # not_covered: never predicted at all
    assert r["rates"]["not_covered"] == {"tpr": 0.0, "tnr": 1.0} and r["f1"]["not_covered"] == 0


def test_evidence_hit_needs_the_right_passage_and_an_exact_quote():
    exs = [ex("supported"), ex("supported"), ex("supported")]
    answers = [ans("supported", "founded in 1971"), ans("supported", "founded in 1971", passage="p2"), ans("supported", "founded in 1972")]
    r = ev.score(exs, answers)
    assert r["label_accuracy"] == 1.0 and r["evidence_hit"] == round(1 / 3, 3)


def test_parsed_dicts_and_unknown_labels_are_accepted():
    exs = [ex("supported"), ex("not_covered", claim="Hart was born in Washington.")]
    r = ev.score(exs, [{"label": "supported", "evidence": [{"passage": "p1", "quote": "founded in 1971"}]}, '{"label": "maybe"}'])
    assert r["label_accuracy"] == 0.5 and r["json_valid"] == 0.5
    assert r["confusion"]["not_covered"]["invalid"] == 1


def test_empty_eval_set_does_not_divide_by_zero():
    r = ev.score([], [])
    assert r["n"] == 0 and r["label_accuracy"] == 0 and r["binary_balanced_accuracy"] is None
    assert r["rates"]["supported"] == {"tpr": None, "tnr": None}

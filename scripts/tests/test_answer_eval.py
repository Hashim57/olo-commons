"""Unit tests for scripts/answer_eval.py (no network): python3 -m pytest scripts/tests -q"""
import importlib.util
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("answer_eval", ROOT / "scripts" / "answer_eval.py")
ae = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ae)

Q = {"id": "q001", "question": "When was AaB founded?", "atoms": ["a1", "a2"], "answer": "13 May 1885, as a cricket club.", "facts": ["1885", "cricket"],
     "provenance": [{"id": "a1", "source": "wikipedia"}, {"id": "a2", "source": "wikipedia"}]}


def resp(sentences, passages):
    return {"sentences": sentences, "passages": passages, "mode": "written", "verifier": "zeus:v22", "abstained": not any(s["verdict"] == "supported" for s in sentences)}


def test_a_full_answer_scores_one_on_every_measure():
    r = resp([{"text": "AaB was founded on 13 May 1885.", "verdict": "supported", "citations": ["p1"]},
              {"text": "It began as a cricket club.", "verdict": "supported", "citations": ["p2"]}],
             [{"id": "p1", "atom": "a1"}, {"id": "p2", "atom": "a2"}, {"id": "p3", "atom": "other"}])
    s = ae.score(Q, r)
    assert s["ok"] and s["retrieval"] == 1 and s["citation"] == 1 and s["verification"] == 1 and s["facts"] == 1 and not s["abstained"]


def test_a_hidden_sentence_earns_no_citation_and_no_fact():
    r = resp([{"text": "AaB was founded on 13 May 1885.", "verdict": "supported", "citations": ["p1"]},
              {"text": "It began as a cricket club.", "verdict": "not_covered", "citations": ["p2"]}],
             [{"id": "p1", "atom": "a1"}, {"id": "p2", "atom": "a2"}])
    s = ae.score(Q, r)
    assert s["retrieval"] == 1 and s["citation"] == 0.5 and s["verification"] == 0.5 and s["facts"] == 0.5


def test_retrieval_is_the_share_of_expected_atoms_that_came_back():
    r = resp([{"text": "AaB was founded on 13 May 1885.", "verdict": "supported", "citations": ["p1"]}], [{"id": "p1", "atom": "a1"}])
    s = ae.score(Q, r)
    assert s["retrieval"] == 0.5 and s["citation"] == 0.5


def test_an_abstention_keeps_retrieval_but_no_facts():
    r = resp([{"text": "AaB was founded in 1885 as a cricket club.", "verdict": "contradicted", "citations": ["p1"]}], [{"id": "p1", "atom": "a1"}, {"id": "p2", "atom": "a2"}])
    s = ae.score(Q, r)
    assert s["abstained"] and s["retrieval"] == 1 and s["citation"] == 0 and s["facts"] == 0 and s["verification"] == 0


def test_no_passages_is_a_failed_call_scored_zero():
    s = ae.score(Q, {"error": "http 503"})
    assert not s["ok"] and s["retrieval"] == 0 and s["facts"] == 0 and s["error"] == "http 503"


def test_facts_compare_digits_without_separators_and_on_word_boundaries():
    assert ae.fact_found("1,085", "a population of 1085 people")
    assert ae.fact_found("1085", "a population of 1,085 people")
    assert ae.fact_found("300,000", "received €300,000 from the state")
    assert not ae.fact_found("18", "it aired in 2018")
    assert ae.fact_found("18", "for 18 episodes in 2007")
    assert ae.fact_found("14 million|fourteen million", "Fourteen million chargers")
    assert ae.fact_found("Jagun Jagun", "films such as JAGUN JAGUN (2023)")
    assert not ae.fact_found("7.1", "rose 17.1% in 2004")
    assert ae.fact_found("7.1", "rose 7.1% in 2004")


def test_summary_means_and_zero_retrieval_list():
    qs = [dict(Q, id="q001"), dict(Q, id="q002", provenance=[{"id": "a1", "source": "pubmed"}])]
    scores = [{"id": "q001", "ok": True, "retrieval": 1.0, "citation": 1.0, "verification": 1.0, "facts": 0.5, "abstained": False, "mode": "written", "verifier": "zeus:v22"},
              {"id": "q002", "ok": True, "retrieval": 0.0, "citation": 0.0, "verification": 0.5, "facts": 0.0, "abstained": True, "mode": "extractive", "verifier": "extractive"}]
    s = ae.summarise(qs, scores)
    assert s["n"] == 2 and s["retrieval"] == 0.5 and s["facts"] == 0.25 and s["abstained"] == 1 and s["failed_calls"] == 0
    assert s["zero_retrieval"] == ["q002"] and s["by_source"]["pubmed"]["n"] == 1 and s["by_source"]["wikipedia"]["retrieval"] == 1.0
    text = ae.report(s, qs)
    assert "| retrieval | 0.500 |" in text and "q002" in text


def test_the_frozen_question_set_is_well_formed():
    rows = ae.load_questions(str(ROOT / "tests" / "answers" / "questions-v1.jsonl"))
    assert len(rows) >= 60
    ids = [r["id"] for r in rows]
    assert len(set(ids)) == len(ids)
    for r in rows:
        assert r["question"].strip().endswith("?"), r["id"]
        assert all(len(a) == 36 for a in r["atoms"]), r["id"]  # atom uuids
        assert r["provenance"] and all(p.get("url") and p.get("source") and p.get("licence") for p in r["provenance"]), r["id"]
        assert [p["id"] for p in r["provenance"]] == r["atoms"], r["id"]
        assert any(ae.fact_found(f, r["answer"]) for f in r["facts"]), r["id"]  # the reference answer carries at least one expected fact
        assert "—" not in json.dumps(r) and "–" not in json.dumps(r), r["id"]  # no em or en dashes anywhere

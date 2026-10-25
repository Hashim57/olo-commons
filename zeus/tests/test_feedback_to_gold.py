import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from feedback_to_gold import build, passage_text

A = {"id": "11111111-aaaa-bbbb-cccc-000000000001", "source_slug": "wikipedia", "url": "https://en.wikipedia.org/wiki/B", "summary": "A bridge. The bridge opened in 1934 and is 503 metres long. " * 4, "content": ""}
D = {"id": "22222222-aaaa-bbbb-cccc-000000000002", "source_slug": "arxiv", "url": "https://arxiv.org/abs/1", "summary": "Something unrelated about neural networks. " * 6, "content": ""}


def flag(**kw):
    base = {"id": "f1", "claim": "The bridge opened in 1932.", "verdict_given": "supported", "verdict_user": "contradicted",
            "passages": [{"atom": A["id"], "quote": "opened in 1934"}], "evidence_quote": None, "note": "the page says 1934", "client": "ios"}
    base.update(kw)
    return base


def test_contradicted_flag_becomes_a_valid_gold_line():
    ex, why = build(flag(), {A["id"]: A}, [dict(D)])
    assert why is None, why
    assert ex["label"] == "contradicted" and ex["evidence"] == [{"passage": A["id"][:8], "quote": "opened in 1934"}]
    assert len(ex["passages"]) == 2 and ex["kind"] == "feedback" and ex["rationale"] == "the page says 1934"
    assert "quote_hint" not in ex["passages"][0]


def test_not_covered_needs_no_evidence_and_reviewer_note_wins():
    ex, why = build(flag(verdict_user="not_covered", reviewer_note="The passage is about another bridge."), {A["id"]: A}, [dict(D)])
    assert why is None and ex["evidence"] == [] and ex["rationale"].startswith("The passage is about")


def test_supported_without_an_exact_quote_is_skipped():
    ex, why = build(flag(verdict_user="supported", passages=[{"atom": A["id"]}], evidence_quote="opened in 1932"), {A["id"]: A}, [dict(D)])
    assert ex is None and "exact substring" in why


def test_unresolvable_passage_and_odd_verdicts_are_skipped():
    assert build(flag(passages=[{"atom": "no-such"}]), {A["id"]: A}, [dict(D)])[0] is None
    assert build(flag(verdict_user="wrong_source"), {A["id"]: A}, [dict(D)])[0] is None


def test_passage_text_follows_the_snapshot_rule():
    assert len(passage_text({"summary": "x" * 1000})) == 600
    assert passage_text({"summary": "short", "content": "more words here"}) == "short more words here"

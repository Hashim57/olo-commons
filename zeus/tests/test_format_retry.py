"""The format retry in eval.py and eval_endpoint.py: at most one repair attempt, off by
default, and the first-attempt numbers never touched by it. A fake generator stands in
for the model; the endpoint is a local HTTP server. No model, no network."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import eval as ev  # noqa: E402
import eval_endpoint as ee  # noqa: E402

P1 = {"id": "p1", "source": "wikipedia", "url": "https://example.org/a", "text": "Project Gutenberg was founded in 1971 by Michael Hart."}
EX = {"claim": "Project Gutenberg was founded in 1971.", "passages": [P1], "label": "supported",
      "evidence": [{"passage": "p1", "quote": "founded in 1971"}], "rationale": "test"}
GOOD = json.dumps({"label": "supported", "evidence": [{"passage": "p1", "quote": "founded in 1971"}], "rationale": "r"})
MSGS = [{"role": "system", "content": "S"}, {"role": "user", "content": "U"}]


class FakeModel:
    """Returns the scripted answers in order and records every call."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def __call__(self, messages, retry):
        self.calls.append((messages, retry))
        return self.answers[len(self.calls) - 1]


def test_garbage_then_valid_retry_is_counted_apart_and_first_attempt_metrics_stay_put():
    m = FakeModel("I think it is supported", GOOD)
    first, final, retried = ev.answer_with_retry(m, MSGS, format_retry=True)
    assert (first, final, retried) == ("I think it is supported", GOOD, True)
    assert len(m.calls) == 2 and m.calls[1][1] is True
    repair = m.calls[1][0]
    assert repair[:2] == MSGS and repair[2] == {"role": "assistant", "content": "I think it is supported"}
    assert repair[3] == {"role": "user", "content": ev.REPAIR}

    r = ev.report_fields([EX], [first], [final], [retried], True)
    assert r == {**ev.score([EX], [first]), "format_retry": True, "json_valid_after_retry": 1.0,
                 "label_accuracy_after_retry": 1.0, "evidence_hit_after_retry": 1.0, "retries_used": 1}
    assert r["json_valid"] == 0 and r["label_accuracy"] == 0 and r["confusion"]["supported"]["invalid"] == 1


def test_both_answers_bad_counts_as_invalid():
    m = FakeModel("{not json", '{"label": "true"}')
    first, final, retried = ev.answer_with_retry(m, MSGS, format_retry=True)
    assert retried and len(m.calls) == 2
    r = ev.report_fields([EX], [first], [final], [retried], True)
    assert r["json_valid"] == 0 and r["json_valid_after_retry"] == 0 and r["label_accuracy_after_retry"] == 0 and r["retries_used"] == 1


def test_a_valid_first_answer_makes_no_retry_call():
    m = FakeModel(GOOD)
    assert ev.answer_with_retry(m, MSGS, format_retry=True) == (GOOD, GOOD, False)
    assert len(m.calls) == 1 and m.calls[0][1] is False
    r = ev.report_fields([EX], [GOOD], [GOOD], [False], True)
    assert r["retries_used"] == 0 and r["json_valid"] == r["json_valid_after_retry"] == 1.0


def test_retry_is_off_by_default_and_the_report_is_the_old_one_plus_the_mode():
    m = FakeModel("garbage", GOOD)
    assert ev.answer_with_retry(m, MSGS) == ("garbage", "garbage", False)
    assert len(m.calls) == 1
    r = ev.report_fields([EX], ["garbage"], ["garbage"], [False], False)
    assert r == {**ev.score([EX], ["garbage"]), "format_retry": False}
    assert not any(k.endswith("_after_retry") for k in r) and "retries_used" not in r


def test_never_more_than_one_retry_and_a_failed_retry_is_just_a_bad_answer():
    m = FakeModel("bad", "still bad", GOOD)
    first, final, retried = ev.answer_with_retry(m, MSGS, format_retry=True)
    assert len(m.calls) == 2 and final == "still bad" and retried

    def boom(messages, retry):
        if retry:
            raise TimeoutError("cap")
        return "bad"
    assert ev.answer_with_retry(boom, MSGS, format_retry=True) == ("bad", "", True)


def test_parse_is_unchanged_and_strict():
    assert ev.parse(GOOD)["label"] == "supported"
    assert ev.parse('Answer: {"label": "not_covered", "evidence": [], "rationale": "r"}')["label"] == "not_covered"
    for bad in ("", "supported", '{"label": "Supported"}', '{"label": "maybe"}', "{bad json}", '{"evidence": []}'):
        assert ev.parse(bad) is None


# The endpoint side: what the Worker says about a retry reaches the report.

def serve(reply):
    class H(BaseHTTPRequestHandler):
        seen = []

        def do_POST(self):
            H.seen.append(json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0))))
            status, obj = reply
            body = json.dumps(obj).encode()
            self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_port}/v1", H.seen


def test_endpoint_reports_the_first_answer_apart_when_the_worker_retried():
    srv, url, seen = serve((200, {"retried": True, "zeus_first_answer": "garbage", "choices": [{"message": {"content": GOOD}}]}))
    try:
        got = ee.ask_full(url, "key", "default_model", EX, timeout=5, errors=[], format_retry=True)
        assert got == {"text": GOOD, "first": "garbage", "retried": True}
        assert seen[0]["format_retry"] is True
    finally:
        srv.shutdown()


def test_endpoint_without_the_flag_sends_nothing_new_and_reads_an_old_worker():
    srv, url, seen = serve((200, {"choices": [{"message": {"content": GOOD}}]}))
    try:
        assert ee.ask_full(url, "key", "default_model", EX, timeout=5) == {"text": GOOD, "first": GOOD, "retried": False}
        assert "format_retry" not in seen[0]
        assert ee.ask(url, "key", "default_model", EX, timeout=5) == GOOD
    finally:
        srv.shutdown()


def test_endpoint_two_failed_answers_score_invalid_without_an_http_retry_or_an_error():
    srv, url, seen = serve((502, {"error": "zeus_unparseable_answer", "retried": True, "first_answer": "x", "retry_answer": "y"}))
    try:
        errors = []
        got = ee.ask_full(url, "key", "default_model", EX, timeout=5, errors=errors, format_retry=True)
        assert got == {"text": "y", "first": "x", "retried": True} and errors == [] and len(seen) == 1
        r = ev.report_fields([EX], [got["first"]], [got["text"]], [got["retried"]], True)
        assert r["json_valid"] == 0 and r["json_valid_after_retry"] == 0 and r["retries_used"] == 1
    finally:
        srv.shutdown()

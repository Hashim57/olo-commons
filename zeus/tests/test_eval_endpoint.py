"""eval_endpoint.ask never fails silently: a refused or broken endpoint leaves a reason
in the errors list. Checked against a local HTTP server, no network."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import eval_endpoint as ee  # noqa: E402

EX = {"claim": "Gutenberg was founded in 1971.", "passages": [{"id": "p1", "source": "wikipedia", "text": "Founded in 1971 by Hart."}],
      "label": "supported", "evidence": [{"passage": "p1", "quote": "Founded in 1971"}], "rationale": "Stated."}


def serve(handler):
    srv = HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_port}/v1"


class Unauthorized(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.dumps({"error": "unauthorized"}).encode()
        self.send_response(401); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class Answers(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.dumps({"choices": [{"message": {"content": '{"label": "supported", "evidence": [], "rationale": "r"}'}}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def test_a_refused_request_is_recorded_with_its_status_and_body_and_not_retried():
    srv, url = serve(Unauthorized)
    try:
        errors = []
        assert ee.ask(url, "wrong-key", "default_model", EX, timeout=5, errors=errors) == ""
        assert len(errors) == 1 and errors[0].startswith("HTTP 401: ") and "unauthorized" in errors[0]
    finally:
        srv.shutdown()


def test_a_good_answer_comes_back_and_records_nothing():
    srv, url = serve(Answers)
    try:
        errors = []
        text = ee.ask(url, "key", "default_model", EX, timeout=5, errors=errors)
        assert json.loads(text)["label"] == "supported" and errors == []
    finally:
        srv.shutdown()


def test_error_summary_counts_kinds():
    s = ee.error_summary(["HTTP 401: x"] * 3 + ["TimeoutError: timed out"])
    assert s == {"count": 4, "kinds": {"HTTP 401: x": 3, "TimeoutError: timed out": 1}}

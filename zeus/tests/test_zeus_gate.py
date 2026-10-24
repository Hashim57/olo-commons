"""zeus/mac/zeus_gate.py: the gate only forwards authenticated, well-formed chat
requests and never lets the caller choose the model. Runs a fake upstream on a
free port; no network beyond localhost."""
import json, os, socket, sys, threading, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mac"))
import zeus_gate  # noqa: E402

TOKEN = "t" * 40
SEEN = []


class Upstream(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self._reply({"data": [{"id": "default_model"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        SEEN.append(body)
        self._reply({"choices": [{"message": {"content": '{"label": "supported", "evidence": [], "rationale": "ok"}'}}]})

    def _reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def start(server):
    t = threading.Thread(target=server.serve_forever, daemon=True); t.start(); return t


def call(port, path, method="GET", body=None, token=None):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=None if body is None else json.dumps(body).encode(), method=method, headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def test_gate_requires_token_forces_model_and_forwards():
    up_port, gate_port = free_port(), free_port()
    up = ThreadingHTTPServer(("127.0.0.1", up_port), Upstream); start(up)
    best = zeus_gate.load_best(os.path.join(os.path.dirname(__file__), "..", "BEST.json"))
    assert best and best["version"].startswith("v") and 0 < best["label_accuracy"] <= 1
    gate = ThreadingHTTPServer(("127.0.0.1", gate_port), zeus_gate.make_handler(TOKEN, "http://127.0.0.1:%d" % up_port, best)); start(gate)
    try:
        assert call(gate_port, "/v1/models")[0] == 401
        assert call(gate_port, "/v1/models", token="wrong" * 8)[0] == 401
        code, models = call(gate_port, "/v1/models", token=TOKEN)
        assert code == 200 and models["data"] == [{"id": "default_model"}] and models["zeus"]["label_accuracy"] == best["label_accuracy"]
        assert zeus_gate.load_best("/nonexistent/BEST.json") is None
        assert call(gate_port, "/v1/anything", token=TOKEN)[0] == 404
        assert call(gate_port, "/v1/completions", "POST", {"x": 1}, TOKEN)[0] == 404
        code, out = call(gate_port, "/v1/chat/completions", "POST", {"model": "evil/other-model", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 9999, "stream": True}, TOKEN)
        assert code == 200 and "supported" in out["choices"][0]["message"]["content"]
        assert SEEN[-1]["model"] == "default_model" and SEEN[-1]["max_tokens"] == 400 and SEEN[-1]["stream"] is False
        assert SEEN[-1]["messages"][0]["content"] == "hi"
    finally:
        gate.shutdown(); up.shutdown()


def test_gate_reports_upstream_down_instead_of_hanging():
    gate_port = free_port()
    gate = ThreadingHTTPServer(("127.0.0.1", gate_port), zeus_gate.make_handler(TOKEN, "http://127.0.0.1:%d" % free_port())); start(gate)
    try:
        code, out = call(gate_port, "/v1/chat/completions", "POST", {"messages": []}, TOKEN)
        assert code == 502 and out["error"] == "zeus_unavailable"
    finally:
        gate.shutdown()

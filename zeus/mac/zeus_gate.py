#!/usr/bin/env python3
"""A small gate in front of mlx_lm.server so Zeus can be reached through a tunnel
without exposing an unauthenticated model server.

  python3 zeus/mac/zeus_gate.py --token-file ~/.zeus-gate-token --listen 8009 --upstream 8008

Every request must carry  Authorization: Bearer <token>  (what olo-answer sends
when OLO_ZEUS_API_KEY is set). Only POST /v1/chat/completions and GET /v1/models
are forwarded; everything else answers 404. Bodies are capped at 64 KB, upstream
calls time out at 60 s, and the request "model" is forced to "default_model" so
a caller can never make mlx_lm.server load a different model. Standard library
only; no secrets in the repository (the token lives in a file outside it).
"""
import argparse
import hmac
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 64 * 1024
UPSTREAM_TIMEOUT = 60


def load_token(path):
    with open(os.path.expanduser(path), encoding="utf-8") as f:
        t = f.read().strip()
    if len(t) < 24:
        sys.exit("token file is too short (24+ characters)")
    return t


def load_best(path):
    """The measured scores of the version serving (zeus/BEST.json), published on GET /v1/models
    so a caller can show a true number ("this version was right 83.5% of the time on its test")."""
    try:
        with open(os.path.expanduser(path), encoding="utf-8") as f:
            b = json.load(f)
        keep = ("version", "date", "base", "label_accuracy", "evidence_hit", "json_valid", "eval_n", "f1", "promoted_at")
        return {k: b[k] for k in keep if k in b}
    except (OSError, ValueError):
        return None


def make_handler(token, upstream, best=None):
    class Gate(BaseHTTPRequestHandler):
        server_version = "zeus-gate/1"

        def log_message(self, fmt, *args):  # one line per request, no bodies, no tokens
            sys.stderr.write("%s %s %s\n" % (self.log_date_time_string(), self.command, self.path.split("?")[0]))

        def _send(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _authed(self):
            h = self.headers.get("Authorization", "")
            ok = h.startswith("Bearer ") and hmac.compare_digest(h[7:].strip(), token)
            if not ok:
                self._send(401, {"error": "unauthorized"})
            return ok

        def do_GET(self):
            if self.path.split("?")[0] != "/v1/models":
                return self._send(404, {"error": "not_found"})
            if not self._authed():
                return
            self._forward("GET", "/v1/models", None, decorate=best)

        def do_POST(self):
            if self.path.split("?")[0] != "/v1/chat/completions":
                return self._send(404, {"error": "not_found"})
            if not self._authed():
                return
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > MAX_BODY:
                return self._send(413, {"error": "body_too_large_or_empty"})
            raw = self.rfile.read(n)
            try:
                body = json.loads(raw)
                if not isinstance(body, dict):
                    raise ValueError
            except ValueError:
                return self._send(400, {"error": "bad_json"})
            body["model"] = "default_model"  # the adapter mlx_lm.server loaded; never a model name from outside
            body["stream"] = False
            body["max_tokens"] = min(int(body.get("max_tokens") or 200), 400)
            self._forward("POST", "/v1/chat/completions", json.dumps(body).encode())

        def _forward(self, method, path, data, decorate=None):
            req = urllib.request.Request(upstream + path, data=data, method=method, headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as r:
                    body = r.read()
                    if decorate:
                        try:
                            j = json.loads(body)
                            if isinstance(j, dict):
                                j["zeus"] = decorate
                                body = json.dumps(j).encode()
                        except ValueError:
                            pass
                    self._send(r.status, body)
            except urllib.error.HTTPError as e:
                self._send(e.code, e.read() or b"{}")
            except Exception as e:  # upstream down or slow: say so, do not hang
                self._send(502, {"error": "zeus_unavailable", "detail": type(e).__name__})

    return Gate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token-file", default="~/.zeus-gate-token")
    ap.add_argument("--listen", type=int, default=8009)
    ap.add_argument("--upstream", type=int, default=8008)
    ap.add_argument("--best", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "BEST.json"))
    a = ap.parse_args()
    token = load_token(a.token_file)
    srv = ThreadingHTTPServer(("127.0.0.1", a.listen), make_handler(token, "http://127.0.0.1:%d" % a.upstream, load_best(a.best)))
    print("zeus-gate listening on 127.0.0.1:%d, forwarding to 127.0.0.1:%d" % (a.listen, a.upstream), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

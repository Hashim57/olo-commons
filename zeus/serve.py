#!/usr/bin/env python3
"""Serve Zeus as a small HTTP API so helius-olo.io can verify claims.

  python zeus/serve.py --adapter zeus/out/zeus-v1 [--base Qwen/Qwen2.5-7B-Instruct] [--port 8008] [--token SECRET]

POST /verify  {"claim": "...", "passages": [{"id","source","url","text"}]}
  -> {"label": ..., "evidence": [...], "rationale": "..."}
Set --token (or ZEUS_TOKEN) and callers must send Authorization: Bearer <token>.
No request body is logged. Keep this behind your own gateway in production.
"""
import argparse, json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
from train_lora import SYSTEM, render_user  # noqa: E402
from eval import parse  # noqa: E402

MODEL = {}


def load(base, adapter):
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM
    tok = AutoTokenizer.from_pretrained(adapter or base)
    model = AutoModelForCausalLM.from_pretrained(base, torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32, device_map="auto")
    if adapter:
        from peft import PeftModel
        model = PeftModel.from_pretrained(model, adapter)
    model.eval()
    MODEL.update(tok=tok, model=model)


def verify(claim, passages):
    import torch
    tok, model = MODEL["tok"], MODEL["model"]
    ex = {"claim": str(claim)[:1000], "passages": [{"id": str(p.get("id", i))[:12], "source": str(p.get("source", ""))[:40], "text": str(p.get("text", ""))[:1500]} for i, p in enumerate(passages[:8])]}
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}]
    ids = tok.apply_chat_template(msgs, add_generation_prompt=True, return_tensors="pt").to(model.device)
    with torch.no_grad():
        out = model.generate(ids, max_new_tokens=200, do_sample=False)
    return parse(tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True)) or {"label": "not_covered", "evidence": [], "rationale": "Model output was not valid."}


class H(BaseHTTPRequestHandler):
    token = None

    def log_message(self, *a):
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/verify":
            return self._send(404, {"error": "not_found"})
        if self.token and self.headers.get("Authorization") != f"Bearer {self.token}":
            return self._send(403, {"error": "forbidden"})
        n = int(self.headers.get("Content-Length") or 0)
        if n > 200_000:
            return self._send(413, {"error": "too_large"})
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(body.get("claim"), str) or not isinstance(body.get("passages"), list):
                return self._send(400, {"error": "claim (string) and passages (list) required"})
            return self._send(200, verify(body["claim"], body["passages"]))
        except json.JSONDecodeError:
            return self._send(400, {"error": "bad_json"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="Qwen/Qwen2.5-7B-Instruct")
    ap.add_argument("--adapter")
    ap.add_argument("--port", type=int, default=8008)
    ap.add_argument("--token", default=os.environ.get("ZEUS_TOKEN"))
    args = ap.parse_args()
    load(args.base, args.adapter)
    H.token = args.token
    print(f"Zeus listening on :{args.port}")
    ThreadingHTTPServer(("0.0.0.0", args.port), H).serve_forever()


if __name__ == "__main__":
    main()

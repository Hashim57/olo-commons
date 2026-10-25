#!/usr/bin/env python3
"""Score a served Zeus (any OpenAI-compatible endpoint) on the frozen eval split.

  python3 zeus/eval_endpoint.py --url https://zeus.<you>.workers.dev/v1 --out zeus/out/zeus-v6/eval-cloudflare.json
  (the key is read from ZEUS_KEY or ~/.zeus-cf-token; it is never written anywhere)

The same metrics as eval.py (label accuracy, evidence hit, JSON validity,
per-label F1) for the model as it actually answers in production, which can
differ from the adapter measured on the Mac (Cloudflare applies the adapter to
the full-precision base; the Mac trained it on a 4-bit one). A version is
published only with this number recorded next to the local one.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
from eval import LABELS, evidence_ok, parse, score as shared_score  # noqa: E402
from train_lora import SYSTEM, render_user  # noqa: E402


def ask(url, key, model, ex, timeout=60, tries=3, errors=None):
    """The model's answer text, or "" when the endpoint did not answer. Every failure is
    recorded in `errors` (a list) as "HTTP <code>: <body start>" or the exception name,
    so a served model that scores zero never does so silently."""
    body = json.dumps({"model": model, "temperature": 0, "max_tokens": 200,
                       "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}]}).encode()
    last = None
    for attempt in range(tries):
        req = urllib.request.Request(url.rstrip("/") + "/chat/completions", data=body, method="POST",
                                     # A real User-Agent: Cloudflare's bot check answers "403 error code: 1010" to Python's default one.
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + key, "User-Agent": "OloZeusEval/1.0 (+https://heliusnetwork.app/olo)"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read())["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}: {e.read()[:160].decode('utf-8', 'replace')}"
            if 400 <= e.code < 500 and e.code != 429:
                break  # a client error (401 wrong key, 404 wrong path, 413) will not change on retry
        except (urllib.error.URLError, KeyError, ValueError, TimeoutError, OSError) as e:
            last = f"{type(e).__name__}: {str(e)[:120]}"
        time.sleep(2 * (attempt + 1))
    if errors is not None:
        errors.append(last or "no answer")
    return ""


def error_summary(errors):
    """{"count": n, "kinds": {"HTTP 401: {...": 200}} with at most five distinct kinds, for the report."""
    kinds = {}
    for e in errors:
        kinds[e] = kinds.get(e, 0) + 1
    top = sorted(kinds.items(), key=lambda kv: -kv[1])[:5]
    return {"count": len(errors), "kinds": dict(top)}


def score(examples, answers):
    """The shared scorer in eval.py (confusion matrix, per-label rates, binary balanced accuracy)."""
    return shared_score(examples, answers)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", default="default_model")
    ap.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data"))
    ap.add_argument("--limit", type=int, default=200)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--out")
    a = ap.parse_args()
    key = os.environ.get("ZEUS_KEY") or (open(os.path.expanduser("~/.zeus-cf-token")).read().strip() if os.path.exists(os.path.expanduser("~/.zeus-cf-token")) else "")
    if not key:
        sys.exit("set ZEUS_KEY or create ~/.zeus-cf-token (zeus/cloudflare/setup.sh does)")
    examples = [json.loads(l) for l in open(os.path.join(a.data, "eval.jsonl")) if l.strip()][: a.limit]
    t0 = time.time()
    with ThreadPoolExecutor(a.workers) as pool:
        errors = []
        answers = list(pool.map(lambda ex: ask(a.url, key, a.model, ex, errors=errors), examples))
    report = {"served_by": a.url.split("/")[2], "model": a.model, **score(examples, answers), "minutes": round((time.time() - t0) / 60, 1)}
    if errors:
        report["errors"] = error_summary(errors)
        print(f"{len(errors)} of {len(examples)} requests failed; most common: {next(iter(report['errors']['kinds']))}", file=sys.stderr)
    if a.out:
        with open(a.out, "w") as f:
            json.dump(report, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()

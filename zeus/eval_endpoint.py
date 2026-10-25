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


def ask(url, key, model, ex, timeout=60, tries=3):
    body = json.dumps({"model": model, "temperature": 0, "max_tokens": 200,
                       "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": render_user(ex)}]}).encode()
    for attempt in range(tries):
        req = urllib.request.Request(url.rstrip("/") + "/chat/completions", data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read())["choices"][0]["message"]["content"]
        except (urllib.error.URLError, KeyError, ValueError, TimeoutError):
            time.sleep(2 * (attempt + 1))
    return ""


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
        answers = list(pool.map(lambda ex: ask(a.url, key, a.model, ex), examples))
    report = {"served_by": a.url.split("/")[2], "model": a.model, **score(examples, answers), "minutes": round((time.time() - t0) / 60, 1)}
    if a.out:
        with open(a.out, "w") as f:
            json.dump(report, f, indent=2)
    print(json.dumps(report))


if __name__ == "__main__":
    main()

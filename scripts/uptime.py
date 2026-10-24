#!/usr/bin/env python3
"""Checks that Olo, the Commons and Zeus are up. Prints a Markdown report and
exits 1 when anything that should be up is down.

  python3 scripts/uptime.py [--deep]     # --deep also asks olo-answer a real question (costs one model call)

Run every 15 minutes by .github/workflows/uptime.yml, which opens an "outage"
issue (GitHub emails the repository owner) and closes it when everything is
back. Standard library only; no keys: every endpoint checked is public, and
Zeus is checked through its public /health.

Environment: ZEUS_HEALTH_URL (e.g. https://zeus.<you>.workers.dev/health) to
include Zeus; OLO_WEB_URL (default https://helius-olo.io).
"""
import argparse
import calendar
import json
import os
import sys
import time
import urllib.error
import urllib.request

FN = "https://bfldflbkebyapfagsxnr.supabase.co/functions/v1"
UA = {"User-Agent": "olo-uptime/1", "Origin": "https://heliusnetwork.app"}


def get(url, method="GET", body=None, headers=None, timeout=30):
    req = urllib.request.Request(url, data=body, method=method, headers={**UA, **(headers or {})})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read(), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read(), time.time() - t0
    except Exception as e:
        return 0, {}, str(e).encode(), time.time() - t0


def check_status():
    code, _, body, dt = get(f"{FN}/olo-query?status=1")
    if code != 200:
        return False, f"olo-query status call answered {code}"
    j = json.loads(body)
    last = (j.get("stats") or {}).get("last_run")
    age_h = (time.time() - calendar.timegm(time.strptime(last[:19], "%Y-%m-%dT%H:%M:%S"))) / 3600 if last else 99
    if age_h > 2:
        return False, f"the ingester has not finished a run for {age_h:.1f} h"
    return True, f"{(j.get('stats') or {}).get('atoms')} atoms, last ingest {age_h * 60:.0f} min ago, {dt:.1f}s"


def check_preflight(fn):
    code, h, _, dt = get(f"{FN}/{fn}", method="OPTIONS", headers={"Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "apikey,content-type"})
    acao = h.get("Access-Control-Allow-Origin") or h.get("access-control-allow-origin")
    ok = code in (200, 204) and acao == "https://heliusnetwork.app"
    return ok, f"{fn} preflight {code}, allow-origin {acao}, {dt:.1f}s"


def check_answer():
    code, _, body, dt = get(f"{FN}/olo-answer", method="POST", body=b'{"q":"who founded project gutenberg","k":6}', headers={"Content-Type": "application/json"}, timeout=90)
    if code != 200:
        return False, f"olo-answer answered {code}: {body[:160]!r}"
    j = json.loads(body)
    mode = j.get("mode") or "written"
    ok = bool(j.get("passages"))
    return ok, f"olo-answer {mode}, verifier {j.get('verifier')}, {len(j.get('passages') or [])} passages, {dt:.1f}s" + ("" if mode != "extractive" else " (no writing model reachable)")


def check_page(url):
    code, _, body, dt = get(url)
    return code == 200 and len(body) > 500, f"{url} {code}, {len(body)} bytes, {dt:.1f}s"


def check_zeus(url):
    code, _, body, dt = get(url)
    if code != 200:
        return False, f"Zeus health {code}"
    j = json.loads(body)
    return True, f"Zeus {j.get('version') or 'no adapter yet'} ({'serving' if j.get('ok') else 'fallback writer only'}), {dt:.1f}s"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deep", action="store_true")
    a = ap.parse_args()
    checks = [("Commons ingest and read API", check_status), ("olo-query from the browser", lambda: check_preflight("olo-query")),
              ("olo-answer from the browser", lambda: check_preflight("olo-answer")), ("heliusnetwork.app/olo", lambda: check_page("https://heliusnetwork.app/olo/")),
              ("helius-olo.io", lambda: check_page(os.environ.get("OLO_WEB_URL") or "https://helius-olo.io"))]
    if os.environ.get("ZEUS_HEALTH_URL"):
        checks.append(("Zeus on Cloudflare", lambda: check_zeus(os.environ["ZEUS_HEALTH_URL"])))
    if a.deep:
        checks.append(("A real answer", check_answer))
    rows, down = [], []
    for name, fn in checks:
        try:
            ok, detail = fn()
        except Exception as e:
            ok, detail = False, f"check crashed: {e}"
        rows.append(f"| {'up' if ok else 'DOWN'} | {name} | {detail} |")
        if not ok:
            down.append(name)
    print(f"Checked {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())}\n\n| State | What | Detail |\n|---|---|---|\n" + "\n".join(rows))
    if down:
        print(f"\nDown: {', '.join(down)}")
    sys.exit(1 if down else 0)


if __name__ == "__main__":
    main()

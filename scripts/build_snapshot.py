#!/usr/bin/env python3
"""Build the offline snapshot of Olo Commons: every atom's title, summary, link,
origin and licence in one compact JSON file that pages and apps keep on the
device and search when the network or the database is down.

  python3 scripts/build_snapshot.py --out snapshot/commons.json

Reads the keyless export of the olo-query function (GET ?export=1, pages of
500). Standard library only. Run every six hours by .github/workflows/snapshot.yml,
which publishes the file on the "snapshot" branch, served by jsDelivr and GitHub:
  https://cdn.jsdelivr.net/gh/Hashim57/olo-commons@snapshot/commons.json
  https://raw.githubusercontent.com/Hashim57/olo-commons/snapshot/commons.json

Format (v1): {"v":1,"built_at","count","licence_note","fields":[...],"atoms":[[...], ...]}
with fields id, title, text, url, source, licence, published_at. text is the
summary, or the start of the content when the summary is short (at most 600
characters), which is enough to search and to quote with a link to the source.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

EXPORT = os.environ.get("OLO_EXPORT_URL", "https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-query")
FIELDS = ["id", "title", "text", "url", "source", "licence", "published_at"]
TEXT_MAX = 600


def page(after, limit=500, tries=4):
    url = f"{EXPORT}?export=1&after={urllib.request.quote(after)}&limit={limit}"
    last = ""
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "olo-snapshot/1"}), timeout=60) as r:
                data = json.loads(r.read())
            if "atoms" in data:
                return data
            last = f"unexpected response: {str(data)[:200]}"
        except urllib.error.HTTPError as e:
            body = e.read()
            if e.code == 400 and b"q is required" in body:
                # olo-query from before the export was added: nothing to build until it is deployed.
                print("olo-query does not offer ?export=1 yet (deploy functions/olo-query); keeping the current snapshot")
                sys.exit(0)
            last = f"HTTP {e.code}"
        except Exception as e:  # network blips: back off and retry, then give up loudly
            last = str(e)
        time.sleep(5 * (i + 1))
    raise SystemExit(f"export failed after {tries} tries: {last}")


def compact(a):
    summary = (a.get("summary") or "").strip()
    content = (a.get("content") or "").strip()
    text = summary if len(summary) >= 200 or not content else (summary + " " + content).strip()
    text = " ".join(text.split())[:TEXT_MAX]
    return [a.get("id"), (a.get("title") or "").strip()[:300], text, a.get("url") or "", a.get("source") or "", a.get("licence") or "", a.get("published_at")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="snapshot/commons.json")
    ap.add_argument("--max-atoms", type=int, default=60000, help="keep the newest N when the Commons outgrows a comfortable download")
    a = ap.parse_args()
    atoms, after, note = [], "1970-01-01", ""
    while True:
        d = page(after)
        batch = d.get("atoms") or []
        note = d.get("licence_note") or note
        atoms += [compact(x) for x in batch if x.get("url") and (x.get("summary") or x.get("content"))]
        if len(batch) < 500 or not d.get("next_after"):
            break
        after = d["next_after"]
    if not atoms:
        sys.exit("the export returned no atoms; refusing to publish an empty snapshot")
    atoms = atoms[-a.max_atoms:]
    snap = {"v": 1, "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "count": len(atoms),
            "licence_note": note or "Each atom carries its own licence; the compilation is CC BY-SA 4.0. Attribute Olo Commons by Helius Network.",
            "fields": FIELDS, "atoms": atoms}
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(snap, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(atoms)} atoms, {os.path.getsize(a.out) / 1e6:.2f} MB -> {a.out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Check an Olo verification receipt against the public Commons, without trusting olo-answer.

    python3 scripts/verify_receipt.py receipt.json
    curl -s ".../functions/v1/olo-answer?q=..." | python3 scripts/verify_receipt.py -

The receipt is the `receipt` object of an olo-answer response (functions/olo-answer/receipt.ts), or the
whole response. Four checks, each reported line by line:

  1. intact     the receipt's receipt_sha256 is the SHA-256 of its canonical JSON (keys sorted, no
                whitespace, UTF-8), so nothing in it was edited after it was issued;
  2. unchanged  each atom the answer drew on still has the content_hash the receipt recorded, read
                through the public olo_atom RPC (a changed or deleted atom is named, not hidden);
  3. quoted     every piece of evidence is in its atom's own words (title, summary or content), read the
                way olo-answer reads quotes (quoteKey in functions/olo-answer/answer.ts);
  4. licensed   every atom names its source and licence, so the answer can be cited.

A receipt from the check mode over your own passages (docs/CHECK.md) lists each passage's SHA-256, not its
text. Pass the passages you sent with --supplied (the request body, or a JSON list of passages) and each one
is matched to its fingerprint and every quote is looked for in it (check 5, "supplied"); without them those
lines are reported as SKIP, not as a failure.

Exit status 0 when every check that could run holds, 1 when one fails, 2 when the receipt cannot be read. The public
read key comes from OLO_ANON_KEY (the Supabase anon key, public by design; docs/API.md); --offline skips
checks 2 and 3. Standard library only. Never sends the question anywhere.
"""
import argparse, hashlib, json, os, re, sys, urllib.request

DEFAULT_URL = "https://bfldflbkebyapfagsxnr.supabase.co"
FORMAT = "olo-receipt/1"


def canonical_json(v):
    """The same bytes receipt.ts canonicalJson writes for the values a receipt holds."""
    if isinstance(v, float):
        raise ValueError("a receipt holds integers only, never floats")
    if isinstance(v, dict):
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + canonical_json(v[k]) for k in sorted(v)) + "}"
    if isinstance(v, list):
        return "[" + ",".join(canonical_json(x) for x in v) + "]"
    return json.dumps(v, ensure_ascii=False)


def receipt_sha256(r):
    rest = {k: v for k, v in r.items() if k != "receipt_sha256"}
    return hashlib.sha256(canonical_json(rest).encode("utf-8")).hexdigest()


def check_text(t):
    t = re.sub(r"(\d)\s?×", r"\1x", str(t or ""))
    return re.sub(r"[   ]", " ", t)


def quote_key(t):
    """quoteKey from functions/olo-answer/answer.ts: case, curly quotes, dashes and spacing do not make a quote inexact."""
    t = check_text(t).lower()
    t = re.sub(r"[‘’‚′`]", "'", t)
    t = re.sub(r"[“”„″«»]", '"', t)
    t = re.sub(r"[‐-―−]", "-", t)
    t = re.sub(r"[   ]", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    return re.sub(r"[.,;:]+$", "", t)


def fetch_atom(base_url, key, atom_id, timeout=30):
    """The atom as the public olo_atom RPC gives it (content cut at 6,000 characters), or None when it is gone."""
    req = urllib.request.Request(base_url.rstrip("/") + "/rest/v1/rpc/olo_atom", data=json.dumps({"p_id": atom_id}).encode(),
                                 headers={"apikey": key, "Authorization": "Bearer " + key, "Content-Type": "application/json",
                                          "User-Agent": "olo-verify-receipt/1"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return (json.loads(r.read().decode("utf-8")) or {}).get("atom")


def verify(receipt, get_atom=None, supplied=None):
    """[(check, ok, message)] for one receipt; ok is None for a check that could not be run (SKIP).
    get_atom(atom_id) -> atom dict or None; None skips checks 2 and 3. supplied: the passages a check-mode
    caller sent, as a list of strings or {text} objects, in the order sent."""
    out = []
    if receipt.get("format") != FORMAT:
        out.append(("format", False, f"format is {receipt.get('format')!r}, this script reads {FORMAT!r}"))
        return out
    want = receipt.get("receipt_sha256")
    try:
        got = receipt_sha256(receipt)
    except ValueError as e:
        got = None
        out.append(("intact", False, str(e)))
    if got is not None:
        out.append(("intact", got == want, "receipt_sha256 matches its contents" if got == want else f"receipt_sha256 is {want}, its contents hash to {got}: edited after it was issued"))

    atoms = {a.get("atom"): a for a in receipt.get("atoms") or []}
    live = {}
    if get_atom is not None:
        for aid, a in atoms.items():
            try:
                live[aid] = get_atom(aid)
            except Exception as e:  # network or HTTP error: say so, do not guess
                live[aid] = e
            cur = live[aid]
            if isinstance(cur, Exception):
                out.append(("unchanged", False, f"{aid}: could not be read ({cur})"))
            elif cur is None:
                out.append(("unchanged", False, f"{aid}: no longer in the Commons (removed since the answer)"))
            elif a.get("content_hash") is None:
                out.append(("unchanged", False, f"{aid}: the receipt recorded no fingerprint, so a change cannot be ruled out"))
            else:
                same = cur.get("content_hash") == a.get("content_hash")
                out.append(("unchanged", same, f"{aid}: same text as when the answer was written" if same else f"{aid}: its text has changed since the answer (fingerprint {a.get('content_hash')[:12]}... is now {str(cur.get('content_hash'))[:12]}...)"))

    fingerprints = {x.get("supplied"): x.get("sha256") for x in receipt.get("supplied") or []}
    texts = {}
    if supplied is not None:
        for n, sha in fingerprints.items():
            if not isinstance(n, int) or n < 1 or n > len(supplied):
                out.append(("supplied", False, f"passage s{n}: not among the {len(supplied)} passages given"))
                continue
            p = supplied[n - 1]
            t = re.sub(r"\s+", " ", str(p if isinstance(p, str) else (p or {}).get("text", ""))).strip()
            same = hashlib.sha256(t.encode("utf-8")).hexdigest() == sha
            out.append(("supplied", same, f"passage s{n}: the text given is the text that was checked" if same else f"passage s{n}: the text given is not the text that was checked (SHA-256 differs)"))
            if same:
                texts[n] = quote_key(t)

    for s in receipt.get("sentences") or []:
        for e in s.get("evidence") or []:
            if "supplied" in e:
                n, quote = e.get("supplied"), e.get("quote", "")
                if n not in fingerprints:
                    out.append(("supplied", False, f"sentence {s.get('n')}: evidence names passage s{n}, which the receipt does not list"))
                elif n not in texts:
                    out.append(("supplied", None, f"sentence {s.get('n')}: quote from your passage s{n} not checked (pass --supplied with the passages you sent)"))
                else:
                    k = quote_key(quote)
                    found = len(k) >= 3 and k in texts[n]
                    out.append(("supplied", found, f"sentence {s.get('n')} ({s.get('verdict')}): quote found in your passage s{n}" if found else f"sentence {s.get('n')} ({s.get('verdict')}): quote not found in your passage s{n}: {quote[:80]!r}"))
                continue
            aid, quote = e.get("atom"), e.get("quote", "")
            if aid not in atoms:
                out.append(("quoted", False, f"sentence {s.get('n')}: evidence names atom {aid}, which the receipt does not list"))
                continue
            cur = live.get(aid)
            if get_atom is None or cur is None or isinstance(cur, Exception):
                continue
            body = quote_key(" ".join(str(cur.get(f) or "") for f in ("title", "summary", "content")))
            k = quote_key(quote)
            found = len(k) >= 3 and k in body
            out.append(("quoted", found, f"sentence {s.get('n')} ({s.get('verdict')}): quote found in {aid}" if found else f"sentence {s.get('n')} ({s.get('verdict')}): quote not found in {aid}: {quote[:80]!r}"))

    for aid, a in atoms.items():
        ok = bool(a.get("licence")) and bool(a.get("source"))
        out.append(("licensed", ok, f"{aid}: {a.get('source')}, {a.get('licence')}" if ok else f"{aid}: no source or licence recorded"))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Check an Olo verification receipt against the public Commons.")
    ap.add_argument("receipt", help="a receipt or a whole olo-answer response as JSON; - reads standard input")
    ap.add_argument("--supabase-url", default=os.environ.get("OLO_SUPABASE_URL", DEFAULT_URL))
    ap.add_argument("--offline", action="store_true", help="check only the seal and the licences, without the network")
    ap.add_argument("--supplied", help="check mode: the passages you sent, as the request body or a JSON list, to match against their fingerprints")
    a = ap.parse_args(argv)
    try:
        raw = sys.stdin.read() if a.receipt == "-" else open(a.receipt, encoding="utf-8").read()
        doc = json.loads(raw)
    except (OSError, ValueError) as e:
        print(f"cannot read the receipt: {e}", file=sys.stderr)
        return 2
    receipt = doc.get("receipt") if isinstance(doc, dict) and "receipt" in doc else doc
    if not isinstance(receipt, dict):
        print("no receipt in this JSON (an olo-answer response before receipts existed, or an error response)", file=sys.stderr)
        return 2
    get_atom = None
    if not a.offline:
        key = os.environ.get("OLO_ANON_KEY", "")
        if not key:
            print("set OLO_ANON_KEY to the public read key (docs/API.md), or pass --offline", file=sys.stderr)
            return 2
        get_atom = lambda aid: fetch_atom(a.supabase_url, key, aid)
    supplied = None
    if a.supplied:
        try:
            sdoc = json.loads(open(a.supplied, encoding="utf-8").read())
        except (OSError, ValueError) as e:
            print(f"cannot read the supplied passages: {e}", file=sys.stderr)
            return 2
        supplied = sdoc.get("passages") if isinstance(sdoc, dict) else sdoc
        if not isinstance(supplied, list):
            print("--supplied must be the request body (with passages) or a JSON list of passages", file=sys.stderr)
            return 2
    results = verify(receipt, get_atom, supplied)
    for check, ok, msg in results:
        print(f"{'SKIP' if ok is None else 'PASS' if ok else 'FAIL'}  {check:<9} {msg}")
    failed = [r for r in results if r[1] is False]
    results = [r for r in results if r[1] is not None]
    shown = sum(1 for s in receipt.get("sentences") or [] if s.get("shown"))
    print(f"\n{len(results) - len(failed)} of {len(results)} checks hold; {shown} of {len(receipt.get('sentences') or [])} sentences were shown as supported.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

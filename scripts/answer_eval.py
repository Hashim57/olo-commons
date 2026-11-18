#!/usr/bin/env python3
"""Measures Olo's answers on the frozen question set (issue #76, part 1).

  python3 scripts/answer_eval.py                                  # ask the public olo-answer API every question, print a report
  python3 scripts/answer_eval.py --limit 10 --sleep 3             # the first ten, three seconds apart
  python3 scripts/answer_eval.py --save out/answers.jsonl         # keep every response, to score again offline
  python3 scripts/answer_eval.py --replay out/answers.jsonl       # score saved responses, no network

Questions live in tests/answers/questions-v1.jsonl: one JSON object per line, hand-written over atoms
that were in the Commons when the line was written, with the atom ids a good answer must cite, a
short reference answer and the facts the answer should mention ("a|b" lists acceptable spellings).
The set is frozen: a line is never edited once measured; a new set is a new file (questions-v2).

For every question the script scores:
  retrieval     the share of expected atoms among the passages olo-answer retrieved (k passages);
  citation      the share of expected atoms that a shown sentence cites (the sentences a client shows
                by default: supported by the verifier and with their figures found in the sources);
  verification  the share of answer sentences the verifier marked supported;
  facts         the share of expected facts found in the shown answer (digits compared without
                thousands separators, numbers matched on word boundaries so 18 is not found in 2018);
  abstained     whether Olo declined to show an answer (nothing supported).
The report prints the mean of each over the questions asked, broken down by source, and the questions
that scored zero on retrieval, which are the ones to read first. Means are printed with the count they
are over; a run over ten questions is a smoke test, not a measurement.

Read-only: the script only calls olo-answer (the public endpoint, no key, the same call the Olo page
makes) and never writes to the database. It respects the 120 calls an hour per address limit by
sleeping between calls and stopping on a 429. One run over the whole set costs about 70 model calls.
Standard library only, like scripts/uptime.py.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

FN = "https://bfldflbkebyapfagsxnr.supabase.co/functions/v1"
UA = {"User-Agent": "olo-answer-eval/1", "Origin": "https://heliusnetwork.app", "Content-Type": "application/json"}
HERE = os.path.dirname(os.path.abspath(__file__))
QUESTIONS = os.path.join(os.path.dirname(HERE), "tests", "answers", "questions-v1.jsonl")
REQUIRED = ("id", "question", "atoms", "answer", "facts")


def load_questions(path):
    """The question lines, each checked for the required keys so a broken line fails here and not mid-run."""
    rows = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            missing = [k for k in REQUIRED if k not in row]
            if missing:
                raise ValueError(f"{path}:{n}: missing {', '.join(missing)}")
            if not row["atoms"] or not row["facts"]:
                raise ValueError(f"{path}:{n}: atoms and facts must not be empty")
            rows.append(row)
    return rows


def ask(question, k=8, timeout=90):
    """One olo-answer call. Returns (status, body dict or None, seconds)."""
    req = urllib.request.Request(f"{FN}/olo-answer", data=json.dumps({"q": question, "k": k}).encode(), method="POST", headers=UA)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read()), time.time() - t0
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body), time.time() - t0
        except ValueError:
            return e.code, {"error": body[:200].decode("utf-8", "replace")}, time.time() - t0
    except Exception as e:  # network down, timeout: scored as a failed call, not a crash
        return 0, {"error": str(e)}, time.time() - t0


def _norm(s):
    return re.sub(r"(?<=\d),(?=\d)", "", (s or "").lower())


def fact_found(fact, text):
    """True when one spelling of the fact ("a|b") is in the text. Digits are compared without thousands
    separators; a spelling that is all digits and punctuation must match on word boundaries."""
    t = _norm(text)
    for alt in fact.split("|"):
        a = _norm(alt).strip()
        if not a:
            continue
        if re.fullmatch(r"[\d.]+", a):
            if re.search(r"(?<!\d)(?<!\d\.)" + re.escape(a) + r"(?!\d)(?!\.\d)", t):
                return True
        elif a in t:
            return True
    return False


def shown_sentences(resp):
    """The sentences a client shows by default: those still marked supported after the figure check
    (functions/olo-answer/hygiene.ts shownAnswer; `shown` in the response is their count)."""
    return [s for s in (resp.get("sentences") or []) if s.get("verdict") == "supported"]


def score(question, resp):
    """Scores one response against its question line. Every field is a fraction or a bool; a response
    without passages (an error, a 503, nothing retrieved) scores zero on everything and counts as failed."""
    expected = set(question["atoms"])
    passages = resp.get("passages") or []
    if not passages:
        return {"id": question["id"], "ok": False, "retrieval": 0.0, "citation": 0.0, "verification": 0.0, "facts": 0.0,
                "abstained": True, "mode": resp.get("mode"), "verifier": resp.get("verifier"), "error": resp.get("error") or resp.get("code")}
    by_pid = {p.get("id"): p.get("atom") for p in passages}
    retrieved = {p.get("atom") for p in passages}
    retrieval = len(expected & retrieved) / len(expected)
    shown = shown_sentences(resp)
    cited_atoms = {by_pid.get(c) for s in shown for c in (s.get("citations") or [])}
    citation = len(expected & cited_atoms) / len(expected)
    sents = resp.get("sentences") or []
    supported = sum(1 for s in sents if s.get("verdict") == "supported")
    verification = supported / len(sents) if sents else 0.0
    answer_text = " ".join(s.get("text") or "" for s in shown)  # what a client shows; the hidden draft never earns a fact
    facts = sum(1 for f in question["facts"] if fact_found(f, answer_text)) / len(question["facts"])
    abstained = bool(resp.get("abstained")) or not shown
    return {"id": question["id"], "ok": True, "retrieval": retrieval, "citation": citation, "verification": verification,
            "facts": facts, "abstained": abstained, "mode": resp.get("mode") or "written", "verifier": resp.get("verifier"),
            "passages": len(passages), "sentences": len(sents)}


def summarise(questions, scores):
    """Means over the questions scored, overall and by the first expected atom's source."""
    by_id = {q["id"]: q for q in questions}
    keys = ("retrieval", "citation", "verification", "facts")

    def mean(rows, k):
        return sum(r[k] for r in rows) / len(rows) if rows else 0.0

    groups = {}
    for s in scores:
        prov = by_id[s["id"]].get("provenance") or [{}]
        groups.setdefault(prov[0].get("source") or "unknown", []).append(s)
    out = {"n": len(scores), "failed_calls": sum(1 for s in scores if not s["ok"]), "abstained": sum(1 for s in scores if s["abstained"]),
           "by_source": {}, "zero_retrieval": [s["id"] for s in scores if s["ok"] and s["retrieval"] == 0]}
    for k in keys:
        out[k] = round(mean(scores, k), 3)
    for src, rows in sorted(groups.items()):
        out["by_source"][src] = {"n": len(rows), **{k: round(mean(rows, k), 3) for k in keys}}
    modes = {}
    for s in scores:
        modes[f"{s.get('mode')}/{s.get('verifier')}"] = modes.get(f"{s.get('mode')}/{s.get('verifier')}", 0) + 1
    out["answered_by"] = modes
    return out


def report(summary, questions):
    by_id = {q["id"]: q for q in questions}
    lines = [f"# Olo answers on questions-v1 ({summary['n']} asked, {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())})", "",
             "| Measure | Mean | What it is |", "|---|---|---|",
             f"| retrieval | {summary['retrieval']:.3f} | expected atoms among the retrieved passages |",
             f"| citation | {summary['citation']:.3f} | expected atoms cited by a shown sentence |",
             f"| verification | {summary['verification']:.3f} | answer sentences the verifier marked supported |",
             f"| facts | {summary['facts']:.3f} | expected facts found in the shown answer |",
             f"| abstained | {summary['abstained']} of {summary['n']} | Olo showed no answer |",
             f"| failed calls | {summary['failed_calls']} of {summary['n']} | no passages came back (error or outage) |", "",
             "| Source | n | retrieval | citation | verification | facts |", "|---|---|---|---|---|---|"]
    for src, r in summary["by_source"].items():
        lines.append(f"| {src} | {r['n']} | {r['retrieval']:.3f} | {r['citation']:.3f} | {r['verification']:.3f} | {r['facts']:.3f} |")
    lines += ["", "Answered by (mode/verifier): " + ", ".join(f"{k} x{v}" for k, v in sorted(summary["answered_by"].items()))]
    if summary["zero_retrieval"]:
        lines += ["", "Questions whose expected atoms were not retrieved at all:"]
        for qid in summary["zero_retrieval"]:
            lines.append(f"- {qid}: {by_id[qid]['question']}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--questions", default=QUESTIONS)
    ap.add_argument("--limit", type=int, default=0, help="ask only the first N questions (0: all)")
    ap.add_argument("--offset", type=int, default=0, help="skip the first N questions")
    ap.add_argument("--k", type=int, default=8, help="passages to retrieve, as olo-answer's k")
    ap.add_argument("--sleep", type=float, default=2.0, help="seconds between calls (the shared limit is 120 an hour per address)")
    ap.add_argument("--save", help="append every raw response to this JSONL file ({id, question, response})")
    ap.add_argument("--replay", help="score responses saved with --save instead of calling the API")
    ap.add_argument("--json", help="write the summary and per-question scores to this file")
    a = ap.parse_args()

    questions = load_questions(a.questions)
    if a.offset or a.limit:
        questions = questions[a.offset:(a.offset + a.limit) if a.limit else None]
    by_id = {q["id"]: q for q in questions}
    scores = []
    if a.replay:
        with open(a.replay, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    row = json.loads(line)
                    if row.get("id") in by_id:
                        scores.append(score(by_id[row["id"]], row.get("response") or {}))
    else:
        saver = open(a.save, "a", encoding="utf-8") if a.save else None
        for i, q in enumerate(questions):
            status, resp, dt = ask(q["question"], a.k)
            if status == 429:
                print(f"429 after {i} questions; stopping (Retry-After honoured by waiting an hour, not by this script)", file=sys.stderr)
                break
            resp = resp or {}
            if status != 200:
                resp.setdefault("error", f"http {status}")
            s = score(q, resp)
            s["seconds"] = round(dt, 1)
            scores.append(s)
            print(f"{q['id']} retrieval {s['retrieval']:.2f} citation {s['citation']:.2f} verification {s['verification']:.2f} facts {s['facts']:.2f}"
                  f"{' abstained' if s['abstained'] else ''}{' FAILED ' + str(s.get('error')) if not s['ok'] else ''} ({dt:.1f}s)", file=sys.stderr)
            if saver:
                saver.write(json.dumps({"id": q["id"], "question": q["question"], "status": status, "response": resp}, ensure_ascii=False) + "\n")
                saver.flush()
            if i + 1 < len(questions) and a.sleep > 0:
                time.sleep(a.sleep)
        if saver:
            saver.close()
    if not scores:
        print("nothing scored", file=sys.stderr)
        sys.exit(2)
    summary = summarise(questions, scores)
    print(report(summary, questions))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump({"summary": summary, "scores": scores, "questions": a.questions, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f, indent=2, ensure_ascii=False)
    sys.exit(0)


if __name__ == "__main__":
    main()

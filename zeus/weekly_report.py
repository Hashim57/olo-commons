#!/usr/bin/env python3
"""The Zeus weekly learning report: a PDF built only from measured files, for publishing every Friday.

  python3 zeus/weekly_report.py [--date 2026-11-20] [--out zeus/reports/zeus-weekly-2026-11-20.pdf]

Reads zeus/STATUS.md (the date each version was measured), zeus/out/zeus-v*/ (eval.json, eval-external.json,
learning.json, train_summary.json), the measured runs of Olo's answers in docs/OLO_ANSWERS.md (issue #76) and
the week's commits. Writes the PDF and, beside it, a JSON summary of
the same numbers (the post is written from that, so the post and the PDF cannot disagree). Nothing is
estimated: a number that was not measured is printed as "not measured" with the reason when one is recorded.

What the report leads with, and why: the Commons eval split has been at or near 100 percent since v6, so it
no longer shows learning. The numbers that can still move are the ones built from claims people wrote or
from patterns no rule writes: VitaminC dev (held out; since 2026-11-17 Zeus also trains on 4,000 VitaminC
training rows, so part of a gain there is in-distribution, and the report says so), Commons eval v3 and its
patterns, and LLM-AggreFact, the public benchmark, which the report shows only once it has been measured
(it needs the Hugging Face token; until then it is left out of the PDF and the post).
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(HERE, "out")

ROW = re.compile(r"^\| (\d{4}-\d{2}-\d{2}) \| (v\d+) \| ([^|]*) \| ([^|]*) \|")

# Validated categorical slots (dataviz reference palette, light mode): one entity, one colour, every week.
INK, INK2, MUTED, SURFACE, GRID = "#0b0b0b", "#52514e", "#8a8984", "#fcfcfb", "#e4e3df"
SERIES = {"VitaminC dev": "#2a78d6", "Commons eval v3": "#eb6834", "LLM-AggreFact": "#1baf7a"}


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def vnum(v):
    return int(str(v).lstrip("v"))


def measured_versions(status_path=os.path.join(HERE, "STATUS.md")):
    """[(date, version, base, train_examples)] for every measured row of the STATUS table, oldest first."""
    rows = []
    for line in open(status_path, encoding="utf-8"):
        m = ROW.match(line)
        if m:
            rows.append((m.group(1), m.group(2), m.group(3).strip(), m.group(4).strip()))
    return sorted(rows, key=lambda r: (r[0], vnum(r[1])))


def scores(version):
    """The measured numbers of one version, None where a number was not measured."""
    d = os.path.join(OUT, f"zeus-{version}")
    ev, ext, tr, lr = load(os.path.join(d, "eval.json")) or {}, load(os.path.join(d, "eval-external.json")) or {}, load(os.path.join(d, "train_summary.json")) or {}, load(os.path.join(d, "learning.json"))
    vit, ev3, agg = ext.get("vitaminc_dev") or {}, ext.get("eval_v3") or {}, ext.get("llm_aggrefact") or {}
    pat = {k: v.get("accuracy") for k, v in (ev3.get("by_kind") or {}).items()}
    return {
        "version": version,
        "commons_eval": ev.get("label_accuracy"),
        "vitaminc_dev": vit.get("label_accuracy"),
        "vitaminc_n": vit.get("n"),
        "eval3": ev3.get("label_accuracy"),
        "eval3_n": ev3.get("n"),
        "eval3_patterns": pat,
        "eval3_wrong": {k: v.get("wrong") for k, v in (ev3.get("by_kind") or {}).items() if "wrong" in v},
        "aggrefact": (agg.get("balanced_accuracy") / 100) if isinstance(agg.get("balanced_accuracy"), (int, float)) else None,
        "aggrefact_n": agg.get("n"),
        "aggrefact_error": agg.get("error"),
        "minutes": tr.get("minutes"),
        "steps": tr.get("steps"),
        "planned_steps": tr.get("planned_steps"),
        "train_examples": tr.get("train_examples"),
        "priority_rows": tr.get("priority_rows"),
        "learning": lr,
    }


ANSWER_ROW = re.compile(r"^\| (\d{4}-\d{2}-\d{2})([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \|")


def _num(cell):
    m = re.match(r"\s*(\d+(?:\.\d+)?)", cell)
    return float(m.group(1)) if m else None


def answer_runs(path=os.path.join(REPO, "docs", "OLO_ANSWERS.md")):
    """The measured runs of scripts/answer_eval.py over the frozen question set, read from the results table in
    docs/OLO_ANSWERS.md (issue #76, part 1), oldest first. Each run: date, the run's own label (times, halves),
    questions asked, who answered, and the four scores plus abstentions. A cell that is not a number (such as
    "1.000 (by construction)") keeps its leading number; the whole cell is kept as text too. Nothing is computed
    from the responses here: the table is the record, and this reads it."""
    runs = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return runs
    for line in lines:
        m = ANSWER_ROW.match(line)
        if not m:
            continue
        d, rest, questions, by, retrieval, citation, verification, facts, abstained = m.groups()
        asked = re.match(r"\s*(\d+) of (\d+)", questions)
        runs.append({
            "date": d, "label": (d + rest).strip(), "questions": questions.strip(), "asked": int(asked.group(1)) if asked else None,
            "of": int(asked.group(2)) if asked else None, "answered_by": re.sub(r"\s*\(see below\)", "", by).strip(),
            "retrieval": _num(retrieval), "citation": _num(citation), "verification": _num(verification), "verification_note": verification.strip(),
            "facts": _num(facts), "abstained": int(_num(abstained)) if _num(abstained) is not None else None,
        })
    return sorted(runs, key=lambda r: r["date"])


def answers_summary(end, runs=None):
    """The Olo answers section: the runs of the week over the whole set, the latest full run, and the latest full run
    before the week as the comparison. A run that did not ask every question is listed but never compared."""
    runs = runs if runs is not None else answer_runs()
    start, _ = week_window(end)
    full = [r for r in runs if r["asked"] is not None and r["asked"] == r["of"]]
    week = [r for r in runs if start.isoformat() <= r["date"] <= end.isoformat()]
    latest = next((r for r in reversed(full) if r["date"] <= end.isoformat()), None)
    ref = next((r for r in reversed(full) if r["date"] < start.isoformat()), None)
    keys = ["retrieval", "citation", "verification", "facts"]
    return {
        "runs_this_week": week, "latest": latest, "reference": ref, "set": "tests/answers/questions-v1.jsonl",
        "change": {k: delta(latest.get(k), ref.get(k)) for k in keys} if latest and ref else {},
    }


STATS_RPC = "https://bfldflbkebyapfagsxnr.supabase.co/rest/v1/rpc/olo_answer_stats"


def answer_tally(days=7, key=None, fetch=None):
    """What the verifier said about Olo's real answers over the last `days` days, read from the public
    olo_answer_stats function (sql/022, issue #76 part 4): {"measured": True, "totals", "share_supported",
    "share_zeus_checked", "share_zeus_supported", "days"} or {"measured": False, "reason": ...}. The anon key is
    public but is still never written into the repository: it comes from OLO_ANON_KEY or SUPABASE_ANON_KEY, and
    without one the section says so. A function that does not exist yet (sql/022 not run) or a window with no
    answers is reported as not measured, never as zero. `fetch(url, headers, body)` is for tests."""
    key = key if key is not None else (os.environ.get("OLO_ANON_KEY") or os.environ.get("SUPABASE_ANON_KEY") or "")
    if not key:
        return {"measured": False, "reason": "no anon key in OLO_ANON_KEY or SUPABASE_ANON_KEY"}
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    body = json.dumps({"p_days": days}).encode()
    if fetch is None:
        import urllib.error
        import urllib.request

        def fetch(url, headers, body):
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    return r.status, r.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode("utf-8", "replace")
    try:
        status, text = fetch(STATS_RPC, headers, body)
    except Exception as e:  # network down: say so, never invent a number
        return {"measured": False, "reason": f"olo_answer_stats unreachable ({type(e).__name__})"}
    if status == 404:
        return {"measured": False, "reason": "olo_answer_stats does not exist yet (sql/022 has not been run)"}
    if status != 200:
        return {"measured": False, "reason": f"olo_answer_stats answered {status}"}
    try:
        d = json.loads(text)
    except ValueError:
        return {"measured": False, "reason": "olo_answer_stats gave unreadable output"}
    t = d.get("totals") or {}
    if not t.get("answers"):
        return {"measured": False, "reason": f"no answers recorded in the last {d.get('days', days)} days"}
    return {"measured": True, "days": d.get("days", days), "totals": t, "share_supported": d.get("share_supported"),
            "share_zeus_checked": d.get("share_zeus_checked"), "share_zeus_supported": d.get("share_zeus_supported")}


FEEDBACK_RPC = "https://bfldflbkebyapfagsxnr.supabase.co/rest/v1/rpc/olo_feedback_stats"


def review_queue(key=None, fetch=None):
    """How many sentences wait for a person, read from the public olo_feedback_stats function: the flags people sent
    and, since sql/024, the sentences the verifier itself doubted (issue #76 part 4). {"measured": True, "new",
    "accepted", "taught", "from_people", "from_verifier", "candidates_waiting", "candidates_7d"} or {"measured":
    False, "reason": ...}. The verifier's own counts are None when sql/024 has not been run (the function then
    answers without those keys), and the section says so instead of printing a zero. Same key rule and `fetch`
    hook as answer_tally."""
    key = key if key is not None else (os.environ.get("OLO_ANON_KEY") or os.environ.get("SUPABASE_ANON_KEY") or "")
    if not key:
        return {"measured": False, "reason": "no anon key in OLO_ANON_KEY or SUPABASE_ANON_KEY"}
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    if fetch is None:
        import urllib.error
        import urllib.request

        def fetch(url, headers, body):
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    return r.status, r.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode("utf-8", "replace")
    try:
        status, text = fetch(FEEDBACK_RPC, headers, b"{}")
    except Exception as e:
        return {"measured": False, "reason": f"olo_feedback_stats unreachable ({type(e).__name__})"}
    if status != 200:
        return {"measured": False, "reason": f"olo_feedback_stats answered {status}"}
    try:
        d = json.loads(text)
    except ValueError:
        return {"measured": False, "reason": "olo_feedback_stats gave unreadable output"}
    if not isinstance(d, dict) or "new" not in d:
        return {"measured": False, "reason": "olo_feedback_stats gave unreadable output"}
    return {"measured": True, "new": d.get("new"), "accepted": d.get("accepted"), "taught": d.get("taught"),
            "from_people": d.get("from_people"), "from_verifier": d.get("from_verifier"),
            "candidates_waiting": d.get("candidates_waiting"), "candidates_7d": d.get("candidates_7d")}


def week_window(end):
    return end - timedelta(days=6), end


def pick_reference(rows, start):
    """The latest version measured before the week began: what this week is compared with."""
    before = [r for r in rows if r[0] < start.isoformat()]
    return before[-1][1] if before else None


def commits(start, end, repo=REPO):
    """Subjects of the week's commits that touched Zeus or the Commons, newest first, without merges and the
    automatic snapshot and result commits (those are reported from the result files instead)."""
    try:
        out = subprocess.run(["git", "-C", repo, "log", "--no-merges", f"--since={start.isoformat()} 00:00", f"--until={end.isoformat()} 23:59",
                              "--format=%ad\t%s", "--date=short", "--", "zeus", "functions", "sql", "docs"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    keep = []
    for line in out.splitlines():
        d, _, s = line.partition("\t")
        if re.match(r"zeus: v\d+ (trained|served)", s) or s.startswith("snapshot"):
            continue
        keep.append((d, s))
    return keep


def pct(x, digits=1):
    return "not measured" if x is None else f"{100 * x:.{digits}f}%"


def delta(now, then):
    if now is None or then is None:
        return ""
    d = 100 * (now - then)
    return f"{'+' if d >= 0 else ''}{d:.1f} pts"


def headline_keys(history):
    """The benchmarks the report shows. LLM-AggreFact appears only once a version has measured it (it needs the
    Hugging Face token); until then it is left out of the report and the post altogether, at Hashim's request."""
    keys = ["vitaminc_dev", "eval3"]
    if any(h.get("aggrefact") is not None for h in history):
        keys.append("aggrefact")
    return keys


def summarise(end, rows=None):
    rows = rows if rows is not None else measured_versions()
    start, _ = week_window(end)
    week = [r for r in rows if start.isoformat() <= r[0] <= end.isoformat()]
    ref = pick_reference(rows, start)
    latest = week[-1][1] if week else (rows[-1][1] if rows else None)
    s_latest = scores(latest) if latest else {}
    s_ref = scores(ref) if ref else {}
    history = [dict(scores(r[1]), date=r[0]) for r in rows]
    return {
        "week_start": start.isoformat(), "week_end": end.isoformat(),
        "latest": latest, "reference": ref,
        "versions_this_week": [r[1] for r in week],
        "latest_scores": s_latest, "reference_scores": s_ref,
        "headline": {k: {"now": s_latest.get(k), "week_ago": s_ref.get(k), "change": delta(s_latest.get(k), s_ref.get(k))} for k in headline_keys(history)},
        "history": history,
        "commits": commits(start, end),
        "base": week[-1][2] if week else (rows[-1][2] if rows else None),
        "olo_answers": answers_summary(end),
        "answer_tally": answer_tally(7),
        "review_queue": review_queue(),
    }


# ---------------------------------------------------------------------------- charts


def chart_history(summary, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    hist = [h for h in summary["history"] if any(h.get(k) is not None for k in ("vitaminc_dev", "eval3", "aggrefact"))]
    fig, ax = plt.subplots(figsize=(7.2, 3.2), dpi=200)
    fig.patch.set_facecolor(SURFACE); ax.set_facecolor(SURFACE)
    for name, key in (("VitaminC dev", "vitaminc_dev"), ("Commons eval v3", "eval3"), ("LLM-AggreFact", "aggrefact")):
        pts = [(vnum(h["version"]), h[key]) for h in hist if h.get(key) is not None]
        if not pts:
            continue
        xs, ys = zip(*pts)
        ax.plot(xs, [100 * y for y in ys], color=SERIES[name], linewidth=2, marker="o", markersize=4, markeredgecolor=SURFACE, markeredgewidth=1.5, label=name, solid_capstyle="round")
        ax.annotate(f"{name} {100 * ys[-1]:.1f}%", (xs[-1], 100 * ys[-1]), xytext=(6, 0), textcoords="offset points", va="center", fontsize=7.5, color=INK)
    ax.set_ylabel("Label accuracy (%)", fontsize=8, color=INK2)
    ax.set_xlabel("Zeus version", fontsize=8, color=INK2)
    ax.grid(axis="y", color=GRID, linewidth=0.6)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=7.5, length=0)
    ax.xaxis.get_major_locator().set_params(integer=True)
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=3, fontsize=7.5, frameon=False, labelcolor=INK, borderaxespad=0.2)
    ax.margins(x=0.18)
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)


def chart_patterns(summary, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    now = summary["latest_scores"].get("eval3_patterns") or {}
    then = summary["reference_scores"].get("eval3_patterns") or {}
    if not now:
        return False
    kinds = sorted(now)
    fig, ax = plt.subplots(figsize=(7.2, 2.6), dpi=200)
    fig.patch.set_facecolor(SURFACE); ax.set_facecolor(SURFACE)
    y = range(len(kinds))
    h = 0.36
    if then:
        ax.barh([i + h / 2 + 0.02 for i in y], [100 * (then.get(k) or 0) for k in kinds], height=h, color="#c3c2b7", label=f"{summary['reference']} (a week ago)")
    ax.barh([i - h / 2 - 0.02 for i in y], [100 * now[k] for k in kinds], height=h, color=SERIES["Commons eval v3"], label=f"{summary['latest']} (now)")
    for i, k in enumerate(kinds):
        ax.text(100 * now[k] + 1.5, i - h / 2 - 0.02, f"{100 * now[k]:.0f}%", va="center", fontsize=7, color=INK)
    ax.set_yticks(list(y)); ax.set_yticklabels([k.replace("_", " ") for k in kinds], fontsize=7.5, color=INK)
    ax.set_xlim(0, 112); ax.invert_yaxis()
    ax.set_xlabel("Label accuracy (%)", fontsize=8, color=INK2)
    ax.grid(axis="x", color=GRID, linewidth=0.6); ax.set_axisbelow(True)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=7.5, length=0)
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=2, fontsize=7, frameon=False, labelcolor=INK, borderaxespad=0.2)
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)
    return True


# ---------------------------------------------------------------------------- PDF


def build_pdf(summary, path, workdir):
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_LEFT
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import mm
    from reportlab.platypus import Image, KeepTogether, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

    ss = getSampleStyleSheet()
    H1 = ParagraphStyle("h1", parent=ss["Title"], fontName="Helvetica-Bold", fontSize=20, leading=24, alignment=TA_LEFT, textColor=colors.HexColor(INK), spaceAfter=4)
    H2 = ParagraphStyle("h2", parent=ss["Heading2"], fontName="Helvetica-Bold", fontSize=13, leading=16, textColor=colors.HexColor(INK), spaceBefore=10, spaceAfter=4)
    P = ParagraphStyle("p", parent=ss["BodyText"], fontName="Helvetica", fontSize=9.5, leading=13.5, textColor=colors.HexColor(INK))
    S = ParagraphStyle("s", parent=P, fontSize=8, leading=11, textColor=colors.HexColor(INK2))
    BIG = ParagraphStyle("big", parent=P, fontName="Helvetica-Bold", fontSize=20, leading=23)
    LAB = ParagraphStyle("lab", parent=P, fontSize=8, leading=10.5, textColor=colors.HexColor(INK2))

    L, R = summary["latest_scores"], summary["reference_scores"]
    hl = summary["headline"]
    end = datetime.fromisoformat(summary["week_end"]).strftime("%d %B %Y").lstrip("0")
    story = []
    story.append(Paragraph("Zeus weekly learning report", H1))
    story.append(Paragraph(f"Week ending {end}. Latest version {summary['latest'] or 'none'}, compared with {summary['reference'] or 'nothing earlier'}. "
                           f"Every number below was measured; nothing is estimated.", S))
    story.append(Spacer(1, 8))
    story.append(Paragraph("Zeus is the open claim checker behind Olo (heliusnetwork.app/olo). Given a claim and some passages from the Olo Commons, "
                           "it says whether the passages support the claim, contradict it, or do not cover it, and quotes the evidence. "
                           "It is a LoRA adapter on Mistral 7B Instruct, retrained every day in the cloud, and its code and data are public "
                           "(github.com/Hashim57/olo-commons).", P))
    story.append(Spacer(1, 10))

    def tile(label, key, note):
        now = hl[key]["now"]
        ch = hl[key]["change"]
        val = pct(now)
        sub = f"{ch} on the week" if ch else ("not measured a week ago" if now is not None and hl[key]["week_ago"] is None else "")
        return [Paragraph(label, LAB), Paragraph(val if now is not None else "not measured", BIG if now is not None else P), Paragraph(sub, LAB), Paragraph(note, S)]

    tiles = [tile("VitaminC dev (human-written claims)", "vitaminc_dev", f"held out, n={L.get('vitaminc_n') or '?'}"),
             tile("Commons eval v3 (hard patterns)", "eval3", f"frozen, n={L.get('eval3_n') or '?'}")]
    if "aggrefact" in hl:
        tiles.append(tile("LLM-AggreFact (public benchmark)", "aggrefact", f"balanced accuracy, where 50% is chance; sample of {L.get('aggrefact_n')}"))
    t = Table([tiles], colWidths=[174 * mm / len(tiles)] * len(tiles))
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 7), ("TOPPADDING", (0, 0), (-1, -1), 6), ("BOTTOMPADDING", (0, 0), (-1, -1), 7)]
                          + [("BOX", (i, 0), (i, 0), 0.6, colors.HexColor(GRID)) for i in range(len(tiles))]))
    story.append(t)
    story.append(Spacer(1, 6))
    story.append(Paragraph(f"The Commons eval split, the first test set, reads {pct(L.get('commons_eval'))}. It has been at or near 100 percent for weeks, "
                           "so it no longer shows learning and is not the headline. The numbers above can still move.", S))

    img1 = os.path.join(workdir, "history.png")
    chart_history(summary, img1)
    story.append(Paragraph("Held-out accuracy by version", H2))
    story.append(Image(img1, width=180 * mm, height=80 * mm))
    agg = "aggrefact" in hl
    hist_rows = [["Version", "Measured", "VitaminC dev", "Commons eval v3"] + (["LLM-AggreFact"] if agg else []) + ["Training minutes"]]
    for h in summary["history"][-8:]:
        hist_rows.append([h["version"], h["date"], pct(h.get("vitaminc_dev")), pct(h.get("eval3"))] + ([pct(h.get("aggrefact"))] if agg else []) + [str(h.get("minutes") or "")])
    widths = [20 * mm, 24 * mm, 30 * mm, 32 * mm] + ([30 * mm] if agg else []) + [30 * mm]
    story.append(_table(hist_rows, widths, colors, Table, TableStyle))
    story.append(Paragraph("The last eight measured versions. The chart and this table carry the same numbers.", S))

    story.append(PageBreak())
    story.append(Paragraph("Where Zeus is still weak", H2))
    img2 = os.path.join(workdir, "patterns.png")
    if chart_patterns(summary, img2):
        story.append(Image(img2, width=180 * mm, height=65 * mm))
        weakest = sorted((L.get("eval3_patterns") or {}).items(), key=lambda kv: kv[1])[:2]
        if weakest:
            w = "; ".join(f"{k.replace('_', ' ')} {pct(v, 0)}" for k, v in weakest)
            wrong = L.get("eval3_wrong") or {}
            told = ""
            k0 = weakest[0][0]
            if wrong.get(k0):
                told = " On the weakest pattern the wrong answers called the claim " + ", ".join(f"{lab} {n} times" for lab, n in wrong[k0].items()) + "."
            story.append(Paragraph(f"Commons eval v3 splits its claims by pattern. The weakest two this week: {w}.{told}", P))
    else:
        story.append(Paragraph("Commons eval v3 by pattern was not measured for the latest version.", P))

    story.append(Paragraph("Learning from its mistakes", H2))
    lr_rows = [["Version", "Earlier mistakes trained again", "Own rows probed", "Probe accuracy", "New mistakes kept"]]
    any_lr = False
    for h in summary["history"]:
        lr = h.get("learning")
        if h["version"] in summary["versions_this_week"] and lr:
            any_lr = True
            if lr.get("error"):
                lr_rows.append([h["version"], "", "", "probe failed", lr["error"][:40]])
            else:
                lr_rows.append([h["version"], str(lr.get("pool_rows_trained", "")), str(lr.get("probe_n", "")), pct(lr.get("probe_accuracy")), str(lr.get("mistakes", ""))])
    story.append(Paragraph("Every version starts from the base model, so a lesson reaches the next version only through the data. After it is measured, "
                           "a version answers 800 of its own training rows (never a test row). What it gets wrong goes into a pool that the next "
                           "version trains again, early in its order. The pool keeps the newest 2,000 mistakes, so a row Zeus has since learned ages out.", P))
    if any_lr:
        story.append(_table(lr_rows, [22 * mm, 45 * mm, 35 * mm, 35 * mm, 38 * mm], colors, Table, TableStyle))
    else:
        story.append(Paragraph("No version this week has a mistake record yet: the loop started on 17 November 2026 and its first version is the next one trained.", S))

    story.append(Paragraph("This week's training runs", H2))
    run_rows = [["Version", "Measured", "Minutes", "Steps (of planned)", "Training rows", "Hand-written, imported and mistake rows"]]
    for h in summary["history"]:
        if h["version"] in summary["versions_this_week"]:
            run_rows.append([h["version"], h["date"], str(h.get("minutes") or ""), f"{h.get('steps') or '?'} of {h.get('planned_steps') or '?'}",
                             f"{h.get('train_examples'):,}" if isinstance(h.get("train_examples"), int) else "", f"{h.get('priority_rows'):,}" if isinstance(h.get("priority_rows"), int) else ""])
    if len(run_rows) > 1:
        story.append(_table(run_rows, [18 * mm, 22 * mm, 17 * mm, 30 * mm, 26 * mm, 62 * mm], colors, Table, TableStyle))
    else:
        story.append(Paragraph("No version was measured this week.", P))

    story.append(Paragraph("Olo's answers on the frozen question set", H2))
    oa = summary.get("olo_answers") or {}
    la, ra = oa.get("latest"), oa.get("reference")
    story.append(Paragraph("Zeus is the checker; Olo is what people use. Since 18 November 2026 Olo's answers are measured the same way: the same "
                           f"70 hand-written questions every time ({_esc(oa.get('set') or 'tests/answers/questions-v1.jsonl')}), scored by scripts/answer_eval.py "
                           "for retrieval (the expected passages came back), citation (the shown answer cites them), verification (the share of "
                           "sentences the verifier supported) and facts (the expected facts appear in the shown answer). Every row comes from a real "
                           "run recorded in docs/OLO_ANSWERS.md.", P))
    if la:
        when = "this week" if oa.get("runs_this_week") and la in oa["runs_this_week"] else f"last measured {la['date']}"
        ch = oa.get("change") or {}
        line = (f"Latest full run ({_esc(la['label'])}, {when}): facts {pct(la.get('facts'))}, citation {pct(la.get('citation'))}, "
                f"verification {pct(la.get('verification'))}, retrieval {pct(la.get('retrieval'))}, {la.get('abstained')} abstentions of {la.get('of')}. "
                f"Answered by: {_esc(la['answered_by'])}.")
        if ra and any(ch.values()):
            line += f" Against the last full run before the week ({_esc(ra['label'])}): facts {ch.get('facts') or 'no change'}, citation {ch.get('citation') or 'no change'}, verification {ch.get('verification') or 'no change'}."
        elif not ra:
            line += " No full run before this week to compare with."
        story.append(Paragraph(line, P))
        a_rows = [["Run (UTC)", "Questions", "Retrieval", "Citation", "Verification", "Facts", "Abstained"]]
        shown_runs = oa.get("runs_this_week") or [la]
        for r in shown_runs[-6:]:
            a_rows.append([r["label"], r["questions"][:28], pct(r.get("retrieval")), pct(r.get("citation")), pct(r.get("verification")), pct(r.get("facts")), str(r.get("abstained") if r.get("abstained") is not None else "")])
        story.append(_table(a_rows, [38 * mm, 40 * mm, 20 * mm, 20 * mm, 24 * mm, 18 * mm, 18 * mm], colors, Table, TableStyle))
        story.append(Paragraph("A run that asked fewer than all 70 questions is listed when it fell in the week but is never the comparison.", S))
    else:
        story.append(Paragraph("No full run of the question set has been recorded yet.", P))
    tal = summary.get("answer_tally") or {}
    story.append(Paragraph("In real use", H2))
    if tal.get("measured"):
        t = tal["totals"]
        zs = tal.get("share_zeus_supported")
        story.append(Paragraph(
            f"Over the last {tal['days']} days Olo answered {t.get('answers')} questions and wrote {t.get('sentences')} sentences. "
            f"The verifier supported {t.get('supported')} of them ({pct(tal.get('share_supported'))}), called {t.get('contradicted')} contradicted and "
            f"{t.get('not_covered')} not covered. Zeus itself checked {t.get('zeus_checked')} sentences ({pct(tal.get('share_zeus_checked'))} of all) and "
            f"supported {pct(zs)} of those; the fallback verifier checked {t.get('fallback_checked')} and {t.get('unchecked')} went unchecked. "
            f"{t.get('abstained')} answers showed nothing because nothing could be verified, {t.get('uncovered')} of them because the Commons had nothing on the question. "
            "Counts only: no question or answer text is kept (olo_answer_stats, sql/022).", P))
    else:
        story.append(Paragraph(f"What the verifier said about real answers is not measured this week: {_esc(tal.get('reason') or 'no tally')}.", P))
    rq = summary.get("review_queue") or {}
    if rq.get("measured"):
        if rq.get("candidates_waiting") is None:
            story.append(Paragraph(
                f"Review queue: {rq.get('new')} flags from people wait for a reviewer; {rq.get('accepted')} have been accepted and {rq.get('taught')} taught to Zeus. "
                "The verifier's own doubts are not queued yet (sql/024 has not been run).", P))
        else:
            story.append(Paragraph(
                f"Review queue: {rq.get('new')} rows wait for a reviewer, {rq.get('candidates_waiting')} of them sentences the verifier itself doubted "
                f"({rq.get('candidates_7d')} queued this week); {rq.get('accepted')} rows have been accepted and {rq.get('taught')} taught to Zeus. "
                "A candidate becomes gold only once a person sets its label (docs/FEEDBACK.md).", P))
    else:
        story.append(Paragraph(f"The review queue is not measured this week: {_esc(rq.get('reason') or 'no counts')}.", S))

    story.append(Paragraph("What changed this week", H2))
    cs = summary["commits"]
    if cs:
        for d, s in cs[:18]:
            story.append(Paragraph(f"{d}: {_esc(s)}", S))
        if len(cs) > 18:
            story.append(Paragraph(f"and {len(cs) - 18} more commits.", S))
    else:
        story.append(Paragraph("No commits to Zeus or the Commons this week.", S))

    story.append(Paragraph("How to read this, and open problems", H2))
    notes = [
        "VitaminC dev is 300 human-written claims over Wikipedia revisions that Zeus never trains on. Since 17 November 2026 it does train on "
        "4,000 VitaminC training rows from the same corpus, so part of any gain there is in-distribution.",
        "Commons eval v3 is frozen and versioned (eval3-v1): 200 claims in six patterns no rule in the training data writes in the same form.",
        "A version trains for up to two hours a day on one A100 GPU (60 minutes until 17 November 2026). Scores move a few points from one "
        "version to the next on sets of 200 to 300 claims, so a single week's change of one or two points is within that noise.",
    ]
    if "aggrefact" in hl:
        notes.append("LLM-AggreFact (Tang, Laban and Durrett 2024) is scored differently: two labels (supported or not), long documents such as news "
                     "summaries, meeting transcripts and RAG answers, and balanced accuracy, where always giving the same answer scores 50%. "
                     "It is the hardest test here because nothing like it is in Zeus's training data, so it shows how far Zeus carries over to "
                     "text it has not seen. The per-dataset scores are in the JSON summary beside this PDF.")
    for n in notes:
        story.append(Paragraph(n, S))
        story.append(Spacer(1, 3))
    story.append(Spacer(1, 6))
    story.append(Paragraph(f"Generated by zeus/weekly_report.py on {date.today().isoformat()} from zeus/STATUS.md, zeus/out/ and docs/OLO_ANSWERS.md. "
                           "Open source under Apache 2.0; the Commons compilation is CC BY-SA 4.0.", S))

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7.5)
        canvas.setFillColor(colors.HexColor(MUTED))
        canvas.drawString(15 * mm, 10 * mm, f"Zeus weekly learning report, week ending {end}")
        canvas.drawRightString(195 * mm, 10 * mm, f"Page {doc.page}")
        canvas.restoreState()

    doc = SimpleDocTemplate(path, pagesize=A4, leftMargin=15 * mm, rightMargin=15 * mm, topMargin=15 * mm, bottomMargin=16 * mm,
                            title=f"Zeus weekly learning report, week ending {end}", author="Helius Network")
    doc.build(story, onFirstPage=footer, onLaterPages=footer)


def _esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _table(rows, widths, colors, Table, TableStyle):
    t = Table(rows, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("FONT", (0, 0), (-1, 0), "Helvetica-Bold", 7.5), ("FONT", (0, 1), (-1, -1), "Helvetica", 7.5),
        ("TEXTCOLOR", (0, 0), (-1, -1), colors.HexColor(INK)), ("LINEBELOW", (0, 0), (-1, 0), 0.6, colors.HexColor(INK2)),
        ("LINEBELOW", (0, 1), (-1, -1), 0.3, colors.HexColor(GRID)), ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=date.today().isoformat(), help="last day of the week reported (default today)")
    ap.add_argument("--out", default=None, help="PDF path (default zeus/reports/zeus-weekly-<date>.pdf)")
    args = ap.parse_args()
    end = date.fromisoformat(args.date)
    out = args.out or os.path.join(HERE, "reports", f"zeus-weekly-{end.isoformat()}.pdf")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    summary = summarise(end)
    work = os.path.join(os.path.dirname(os.path.abspath(out)), f".charts-{end.isoformat()}")
    os.makedirs(work, exist_ok=True)
    build_pdf(summary, out, work)
    js = os.path.splitext(out)[0] + ".json"
    slim = {k: v for k, v in summary.items() if k != "history"}
    shown = ["version", "date"] + list(summary["headline"]) + ["minutes"]
    slim["history_tail"] = [{k: h.get(k) for k in shown} for h in summary["history"][-8:]]
    if "aggrefact" not in summary["headline"]:
        # left out of the report until measured, so it is left out of what the post is written from too
        for side in ("latest_scores", "reference_scores"):
            slim[side] = {k: v for k, v in (slim.get(side) or {}).items() if not k.startswith("aggrefact")}
    with open(js, "w", encoding="utf-8") as f:
        json.dump(slim, f, indent=2)
    for p in os.listdir(work):
        os.remove(os.path.join(work, p))
    os.rmdir(work)
    print(json.dumps({"pdf": out, "summary": js, "latest": summary["latest"], "headline": summary["headline"]}))


if __name__ == "__main__":
    main()

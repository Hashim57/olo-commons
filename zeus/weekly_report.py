#!/usr/bin/env python3
"""The Zeus weekly learning report: a PDF built only from measured files, for publishing every Friday.

  python3 zeus/weekly_report.py [--date 2026-11-20] [--out zeus/reports/zeus-weekly-2026-11-20.pdf]

Reads zeus/STATUS.md (the date each version was measured), zeus/out/zeus-v*/ (eval.json, eval-external.json,
learning.json, train_summary.json) and the week's commits. Writes the PDF and, beside it, a JSON summary of
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
        sub = f"{ch} on the week" if ch else ("first measurement" if now is not None and hl[key]["week_ago"] is None else "")
        return [Paragraph(label, LAB), Paragraph(val if now is not None else "not measured", BIG if now is not None else P), Paragraph(sub, LAB), Paragraph(note, S)]

    tiles = [tile("VitaminC dev (human-written claims)", "vitaminc_dev", f"held out, n={L.get('vitaminc_n') or '?'}"),
             tile("Commons eval v3 (hard patterns)", "eval3", f"frozen, n={L.get('eval3_n') or '?'}")]
    if "aggrefact" in hl:
        tiles.append(tile("LLM-AggreFact", "aggrefact", f"public grounding benchmark, sample of {L.get('aggrefact_n')}"))
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
    for n in notes:
        story.append(Paragraph(n, S))
        story.append(Spacer(1, 3))
    story.append(Spacer(1, 6))
    story.append(Paragraph(f"Generated by zeus/weekly_report.py on {date.today().isoformat()} from zeus/STATUS.md and zeus/out/. "
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

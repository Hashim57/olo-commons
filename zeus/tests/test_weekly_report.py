"""zeus/weekly_report.py: the Friday report prints only measured numbers and builds a PDF."""
import os, sys
from datetime import date

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import weekly_report as wr  # noqa: E402


def test_unmeasured_numbers_say_so_and_changes_need_both_ends():
    assert wr.pct(None) == "not measured"
    assert wr.pct(0.733) == "73.3%"
    assert wr.delta(0.733, 0.713) == "+2.0 pts"
    assert wr.delta(0.92, 0.965) == "-4.5 pts"
    assert wr.delta(None, 0.9) == "" and wr.delta(0.9, None) == ""


def test_status_rows_are_read_in_measured_order():
    rows = wr.measured_versions()
    assert rows and all(r[1].startswith("v") for r in rows)
    assert [r[0] for r in rows] == sorted(r[0] for r in rows)


def test_reference_is_the_last_version_before_the_week():
    rows = [("2026-11-09", "v19", "b", "1"), ("2026-11-14", "v20", "b", "1"), ("2026-11-16", "v22", "b", "1")]
    assert wr.pick_reference(rows, date(2026, 11, 11)) == "v19"
    assert wr.pick_reference(rows, date(2026, 11, 1)) is None


def test_a_report_builds_from_the_repository(tmp_path):
    rows = wr.measured_versions()
    end = date.fromisoformat(rows[-1][0])
    summary = wr.summarise(end, rows)
    out = tmp_path / "r.pdf"
    wr.build_pdf(summary, str(out), str(tmp_path))
    assert out.read_bytes()[:5] == b"%PDF-" and out.stat().st_size > 20000
    assert summary["latest"] == rows[-1][1]


def test_aggrefact_is_left_out_until_it_is_measured():
    assert wr.headline_keys([{"aggrefact": None}, {}]) == ["vitaminc_dev", "eval3"]
    assert wr.headline_keys([{"aggrefact": None}, {"aggrefact": 0.71}]) == ["vitaminc_dev", "eval3", "aggrefact"]


def test_olo_answer_runs_are_read_from_the_measured_table():
    runs = wr.answer_runs()
    assert len(runs) >= 4 and [r["date"] for r in runs] == sorted(r["date"] for r in runs)
    first = runs[0]
    assert first["asked"] == 70 and first["of"] == 70 and first["verification"] == 1.0 and "by construction" in first["verification_note"]
    partial = next(r for r in runs if r["asked"] == 50)
    assert partial["of"] == 70 and partial["abstained"] == 8
    assert wr.answer_runs(path="/nonexistent/OLO_ANSWERS.md") == []


def test_olo_answers_section_compares_only_full_runs():
    def run(d, asked, facts, label=None):
        return {"date": d, "label": label or d, "questions": f"{asked} of 70", "asked": asked, "of": 70, "answered_by": "x",
                "retrieval": 1.0, "citation": 0.9, "verification": 0.8, "verification_note": "0.8", "facts": facts, "abstained": 1}
    runs = [run("2026-11-10", 70, 0.60), run("2026-11-18", 50, 0.99), run("2026-11-18", 70, 0.871, "2026-11-18 14:17")]
    s = wr.answers_summary(date(2026, 11, 21), runs)
    assert s["latest"]["label"] == "2026-11-18 14:17" and s["reference"]["date"] == "2026-11-10"
    assert s["change"]["facts"] == "+27.1 pts" and s["change"]["retrieval"] == "+0.0 pts"
    assert [r["asked"] for r in s["runs_this_week"]] == [50, 70]
    # a week before any run: nothing to show, nothing invented
    empty = wr.answers_summary(date(2026, 11, 1), runs)
    assert empty["latest"] is None and empty["reference"] is None and empty["change"] == {}
    # the summary of the repository carries the section and the PDF builds with it
    rows = wr.measured_versions()
    summary = wr.summarise(date.fromisoformat(rows[-1][0]), rows)
    assert summary["olo_answers"]["latest"]["facts"] == 0.871


def test_real_use_tally_is_measured_or_says_why_not():
    assert wr.answer_tally(key="")["reason"].startswith("no anon key")
    missing = wr.answer_tally(key="k", fetch=lambda u, h, b: (404, '{"code":"PGRST202"}'))
    assert missing == {"measured": False, "reason": "olo_answer_stats does not exist yet (sql/022 has not been run)"}
    empty = wr.answer_tally(key="k", fetch=lambda u, h, b: (200, '{"days": 7, "totals": {"answers": 0}}'))
    assert empty["measured"] is False and "no answers" in empty["reason"]

    def boom(u, h, b):
        raise OSError("offline")
    assert "unreachable" in wr.answer_tally(key="k", fetch=boom)["reason"]
    seen = {}

    def ok(u, h, b):
        seen.update(url=u, auth=h["Authorization"], body=b)
        return 200, ('{"days": 7, "totals": {"answers": 10, "sentences": 30, "supported": 24, "contradicted": 1, "not_covered": 5,'
                     ' "zeus_checked": 20, "zeus_supported": 17, "fallback_checked": 8, "unchecked": 2, "abstained": 1, "uncovered": 1},'
                     ' "share_supported": 0.8, "share_zeus_checked": 0.667, "share_zeus_supported": 0.85}')
    t = wr.answer_tally(key="k", fetch=ok)
    assert t["measured"] and t["share_zeus_supported"] == 0.85 and t["totals"]["sentences"] == 30
    assert seen["url"].endswith("/rpc/olo_answer_stats") and seen["auth"] == "Bearer k" and b'"p_days": 7' in seen["body"]


def test_a_report_builds_with_and_without_the_tally(tmp_path, monkeypatch):
    monkeypatch.delenv("OLO_ANON_KEY", raising=False)
    monkeypatch.delenv("SUPABASE_ANON_KEY", raising=False)
    rows = wr.measured_versions()
    summary = wr.summarise(date.fromisoformat(rows[-1][0]), rows)
    assert summary["answer_tally"]["measured"] is False
    wr.build_pdf(summary, str(tmp_path / "a.pdf"), str(tmp_path))
    summary["answer_tally"] = {"measured": True, "days": 7, "share_supported": 0.8, "share_zeus_checked": 0.5, "share_zeus_supported": 0.9,
                               "totals": {"answers": 4, "sentences": 10, "supported": 8, "contradicted": 0, "not_covered": 2, "zeus_checked": 5,
                                          "fallback_checked": 5, "unchecked": 0, "abstained": 0, "uncovered": 0}}
    wr.build_pdf(summary, str(tmp_path / "b.pdf"), str(tmp_path))
    assert (tmp_path / "b.pdf").read_bytes()[:5] == b"%PDF-"

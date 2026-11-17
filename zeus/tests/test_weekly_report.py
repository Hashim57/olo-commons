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

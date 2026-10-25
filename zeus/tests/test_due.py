import os, sys
from datetime import date
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud"))
from due import decide

BEST = {"version": "v6", "date": "2026-10-25", "train_examples": "6,353"}


def test_feedback_makes_training_due():
    assert decide(BEST, {"train_total": 6400}, 3, date(2026, 10, 26))[0]


def test_ten_percent_growth_makes_it_due_and_less_does_not():
    assert decide(BEST, {"train_total": 6989}, 0, date(2026, 10, 26))[0]
    due, reason = decide(BEST, {"train_total": 6900}, 0, date(2026, 10, 26))
    assert not due and "nothing new" in reason


def test_a_week_makes_it_due():
    assert decide(BEST, {"train_total": 6353}, 0, date(2026, 11, 1))[0]
    assert not decide(BEST, {"train_total": 6353}, 0, date(2026, 10, 31))[0]


def test_no_best_yet_or_force():
    assert decide({}, {"train_total": 100}, 0, date(2026, 10, 26))[0]
    assert decide(BEST, {"train_total": 1}, 0, date(2026, 10, 25), force=True)[1] == "requested by hand"

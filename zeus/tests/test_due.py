import os, sys
from datetime import date
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud"))
from due import decide, recipe_change

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


def test_a_changed_recipe_makes_it_due_and_an_unknown_one_does_not():
    best = dict(BEST, train_generators=["rules-v1", "hard-v1"])
    due, reason = decide(best, {"train_total": 6400, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}, 0, date(2026, 10, 26))
    assert due and "compose-v1 added" in reason and "v6" in reason
    assert not decide(best, {"train_total": 6400, "train_generators": ["hard-v1", "rules-v1"]}, 0, date(2026, 10, 26))[0]
    # an older BEST.json without the key, or a build without it, never triggers a run by itself
    assert not decide(BEST, {"train_total": 6400, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}, 0, date(2026, 10, 26))[0]
    assert not decide(best, {"train_total": 6400}, 0, date(2026, 10, 26))[0]
    assert recipe_change(["a", "b"], ["b", "c"]) == "c added; a removed"
    assert recipe_change(["a"], ["a"]) == ""

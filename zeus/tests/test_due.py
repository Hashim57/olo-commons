import json, os, sys
from datetime import date
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud"))
from due import decide, last_measured, recipe_change, reference, version_number

BEST = {"version": "v6", "date": "2026-10-25", "train_examples": "6,353"}


def test_feedback_makes_training_due():
    assert decide(BEST, {"train_total": 6400}, 3, date(2026, 10, 26))[0]


def test_ten_percent_growth_makes_it_due_and_less_does_not():
    assert decide(BEST, {"train_total": 6989}, 0, date(2026, 10, 26))[1] == "training set grew from 6,353 to 6,989"
    # less than a tenth is still due the next day, by the daily rule, and says so
    assert decide(BEST, {"train_total": 6900}, 0, date(2026, 10, 26))[1].startswith("daily run")
    # on the day of the last run, less than a tenth is not
    due, reason = decide(BEST, {"train_total": 6900}, 0, date(2026, 10, 25))
    assert not due and "nothing new" in reason


def test_a_week_makes_it_due():
    assert decide(BEST, {"train_total": 6353}, 0, date(2026, 11, 1))[0]
    assert not decide(BEST, {"train_total": 6353}, 0, date(2026, 10, 31))[0]


def test_a_day_with_anything_new_makes_it_due_and_the_same_set_does_not():
    # the day after v6: a dozen gold lines more is enough (the daily hour of training Hashim asked for)
    due, reason = decide(BEST, {"train_total": 6365}, 0, date(2026, 10, 26))
    assert due and reason.startswith("daily run: 6,365 examples against 6,353")
    # fewer examples (a stricter quality gate) is also not the set v6 saw
    assert decide(BEST, {"train_total": 6300}, 0, date(2026, 10, 27))[0]
    # the identical set, or the same day, is not worth an hour of GPU
    assert not decide(BEST, {"train_total": 6353}, 0, date(2026, 10, 26))[0]
    assert not decide(BEST, {"train_total": 6365}, 0, date(2026, 10, 25))[0]


def test_no_best_yet_or_force():
    assert decide({}, {"train_total": 100}, 0, date(2026, 10, 26))[0]
    assert decide(BEST, {"train_total": 1}, 0, date(2026, 10, 25), force=True)[1] == "requested by hand"


def test_a_changed_recipe_makes_it_due_and_an_unknown_one_does_not():
    best = dict(BEST, train_generators=["rules-v1", "hard-v1"])
    due, reason = decide(best, {"train_total": 6400, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}, 0, date(2026, 10, 26))
    assert due and "compose-v1 added" in reason and "v6" in reason
    assert not decide(best, {"train_total": 6400, "train_generators": ["hard-v1", "rules-v1"]}, 0, date(2026, 10, 25))[0]
    # an older BEST.json without the key, or a build without it, never triggers a run by itself
    assert not decide(BEST, {"train_total": 6400, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}, 0, date(2026, 10, 25))[0]
    assert not decide(best, {"train_total": 6400}, 0, date(2026, 10, 25))[0]
    assert recipe_change(["a", "b"], ["b", "c"]) == "c added; a removed"
    assert recipe_change(["a"], ["a"]) == ""


# --- the comparison is with the last trained version, not the best one ---

V16 = {"version": "v16", "date": "2026-11-04", "train_examples": "22,497", "train_generators": ["rules-v1", "hard-v1"]}
TODAY_META = {"train_total": 30722, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}


def zeus_dir(tmp_path, versions, status_rows=()):
    """A zeus/ directory with out/zeus-vN folders: versions is {n: (files, train_summary or None)}."""
    for n, (files, summary) in versions.items():
        d = tmp_path / "out" / f"zeus-v{n}"
        d.mkdir(parents=True)
        for name in files:
            (d / name).write_text("{}")
        if summary is not None:
            (d / "train_summary.json").write_text(json.dumps(summary))
    (tmp_path / "STATUS.md").write_text("# Zeus status\n\n| Date | Version | Base |\n|---|---|---|\n" + "".join(status_rows))
    return str(tmp_path)


def test_against_the_best_version_alone_the_same_data_is_due_every_day():
    # what happened on 2026-11-09: v18 had been trained on this set the day before, BEST.json still said v16
    due, reason = decide(V16, TODAY_META, 0, date(2026, 11, 9))
    assert due and "grew from 22,497" in reason


def test_against_the_last_trained_version_the_same_data_is_not_due():
    v18 = {"version": "v18", "date": "2026-11-08", "train_examples": 32426, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}
    ref = reference(V16, v18)
    assert ref is v18
    due, reason = decide(ref, TODAY_META, 0, date(2026, 11, 8))
    assert not due and "v18 measured 2026-11-08" in reason
    # the next day the daily rule takes it (the set differs by the gold lines and a gate rule), naming what it trains against
    assert decide(ref, TODAY_META, 0, date(2026, 11, 9))[1] == "daily run: 30,722 examples against 32,426 trained in v18 on 2026-11-08"
    # the very same set the next day is not due: the growth, recipe, feedback and weekly rules are all that is left
    assert not decide(ref, dict(TODAY_META, train_total=32426), 0, date(2026, 11, 9))[0]
    # ...and the rules still fire against it: growth, a new generator, feedback, a week
    assert decide(ref, dict(TODAY_META, train_total=35669), 0, date(2026, 11, 9))[0]
    assert "hard-v2 added" in decide(ref, dict(TODAY_META, train_generators=TODAY_META["train_generators"] + ["hard-v2"]), 0, date(2026, 11, 9))[1]
    assert decide(ref, TODAY_META, 2, date(2026, 11, 9))[0]
    assert decide(ref, dict(TODAY_META, train_total=32426), 0, date(2026, 11, 15))[1] == "7 days since v18"
    assert not decide(ref, dict(TODAY_META, train_total=32426), 0, date(2026, 11, 14))[0]


def test_reference_keeps_the_best_version_when_nothing_newer_was_measured():
    assert reference(V16, {}) is V16
    assert reference(V16, {"version": "v16", "train_examples": 22497}) is V16
    assert reference(V16, {"version": "v9", "train_examples": 6618}) is V16
    assert reference({}, {"version": "v1", "train_examples": 400})["version"] == "v1"
    assert version_number("v18") == 18 and version_number("") == -1 and version_number("zeus-v3") == -1


def test_last_measured_reads_the_newest_version_with_results(tmp_path):
    z = zeus_dir(tmp_path, {
        16: (["eval.json"], {"train_examples": 22497, "train_generators": ["rules-v1", "hard-v1"]}),
        18: (["eval.json"], {"train_examples": 32426, "train_generators": ["rules-v1", "hard-v1", "compose-v1"]}),
        19: (["FAILED.txt"], None),   # a failed run is not a measured version
        20: ([], None),               # nor is an empty folder
    }, ["| 2026-11-04 | v16 | m |\n", "| 2026-11-08 | v18 | m |\n", "| 2026-11-01 | v1 | m |\n"])
    assert last_measured(z) == {"version": "v18", "train_examples": 32426, "train_generators": ["rules-v1", "hard-v1", "compose-v1"], "date": "2026-11-08"}


def test_last_measured_leaves_out_what_is_not_on_record(tmp_path):
    z = zeus_dir(tmp_path, {7: (["eval.json"], None)})
    assert last_measured(z) == {"version": "v7"}
    assert last_measured(str(tmp_path / "nowhere")) == {}
    # no date on record: the weekly rule cannot fire, and a known version is not "no measured version yet"
    due, reason = decide({"version": "v7", "train_examples": 6468}, {"train_total": 6500}, 0, date(2027, 1, 1))
    assert not due and "nothing new" in reason
    # no size on record either: the growth rule cannot fire
    assert not decide({"version": "v7"}, {"train_total": 99999}, 0, date(2027, 1, 1))[0]


def test_last_measured_on_this_repository_is_at_least_v18():
    last = last_measured()
    assert version_number(last["version"]) >= 18 and last.get("train_examples") and last.get("date")

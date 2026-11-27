"""Unit tests for the bound-v1 train examples (zeus/bound.py, import_corpora.bound_examples). No network."""
import os, random, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import bound  # noqa: E402


def _num(claim):
    m = re.search(r"(?:more than|over|fewer than|under|less than) ([\d,]+)", claim, re.I)
    return float(m.group(1).replace(",", "")), m.group(0).split()[0].lower()


def _holds(n, claim):
    """Whether the bound in claim is true of the passage's exact number n."""
    b, word = _num(claim)
    return n > b if word in ("more", "over") else n < b


def test_a_pair_bounds_one_number_once_true_and_once_false_in_the_same_words():
    for seed in range(40):
        got = bound.bound_pair("He scored 36 goals for the club in his first season.", random.Random(seed))
        assert got, seed
        sup, con, r_sup, r_con, num = got
        assert num == "36"
        assert _holds(36, sup) and not _holds(36, con), (sup, con)
        assert re.sub(r"[\d,]+", "N", sup) == re.sub(r"[\d,]+", "N", con), "only the bound's number differs"
        assert "36" in r_sup and "36" in r_con and "not" in r_con and "not" not in r_sup


def test_thousands_commas_and_percentages_keep_their_form():
    for seed in range(20):
        sup, con, _, _, _ = bound.bound_pair("The town had 3,412 residents in the last census.", random.Random(seed))
        assert re.search(r"\d,\d{3}", sup) and _holds(3412, sup) and not _holds(3412, con)
        sup, con, _, _, _ = bound.bound_pair("Turnout reached 64% in the northern district.", random.Random(seed))
        assert "%" in sup and _holds(64, sup) and not _holds(64, con)


def test_a_bound_that_opens_the_sentence_takes_the_capital():
    sups = {bound.bound_pair("78 users from the site favoured the film at release.", random.Random(s))[0][0] for s in range(10)}
    assert all(c.isupper() for c in sups)


def test_what_could_make_a_bound_wrong_is_never_rewritten():
    never = [
        "The city has about 500 shops in its centre.",                 # the passage hedges the number
        "The city has over 500 shops in its centre.",                  # the passage already bounds it
        "The festival drew between 400 and 500 visitors this year.",   # a range
        "The festival drew 400-500 visitors this year.",
        "The festival drew 500 or more visitors this year.",
        "The Apollo 11 missions carried crews of trained pilots.",     # part of a name
        "It has 4 stations and 2 depots along the line.",              # two numbers: which one?
        "The team did not win 3 matches in the season.",               # a negation
        "The project is expected to create 300 jobs in the town.",     # a hedge
        "It is 25 miles (40 km) southeast of the capital city.",       # a conversion follows
        "Tiene una población de 430 habitantes en el censo.",          # not English
        "La población era de 2 555 habitantes según el censo.",        # thousands with a space
        "The team won the 3 matches it played in the cup.",            # after a determiner
        "Results were reported with 95% confidence intervals overall.",  # a confidence level, not a quantity
        "In 1995 elections were held across the whole country.",       # a year
    ]
    for s in never:
        assert bound._candidate(s) is None, s


def test_make_pair_quotes_the_passage_and_shows_it_with_the_others():
    own = {"id": "aaaa1111", "source": "wikinews", "text": "Police said 13 people were hurt. 30 sailors were murdered by pirates during 2004."}
    others = [{"id": "bbbb2222", "source": "wikipedia", "text": "Unrelated."}, {"id": "cccc3333", "source": "wikipedia", "text": "Also unrelated."}]
    rows = bound.make_pair("30 sailors were murdered by pirates during 2004.", own, others, random.Random(1), {"atom_id": "aaaa1111x"})
    assert [r["label"] for r in rows] == ["supported", "contradicted"]
    assert [r["kind"] for r in rows] == ["bound_supported", "bound_wrong"]
    for r in rows:
        assert r["generator"] == bound.BOUND_VERSION and r["atom_id"] == "aaaa1111x"
        assert r["evidence"] == [{"passage": "aaaa1111", "quote": "30 sailors were murdered by pirates during 2004."}]
        assert {p["id"] for p in r["passages"]} == {"aaaa1111", "bbbb2222", "cccc3333"}
        assert r["claim"] not in own["text"]
    assert rows[0]["pair"] == rows[1]["pair"]


def test_add_bounded_reads_train_atoms_only_and_leaves_eval_atoms_alone():
    import build_dataset as bd
    atoms = []
    for i in range(60):
        atoms.append({"id": f"{i:02d}" + "f" * 30, "source": "wikinews", "url": "",
                      "summary": f"The council said that {i + 12} residents attended the meeting on the bridge plan. It was the largest meeting in the history of the town."})
    train = []
    made = bound.add_bounded(train, atoms, 0.3)
    assert made and len(made) % 2 == 0 and len(train) == len(made)
    for r in made:
        assert bd.stable_split(r["atom_id"], 0.3) == "train"
    assert len(made) <= 2 * bound.MAX_PAIRS


def test_vitaminc_bound_examples_use_real_revisions_once_per_case():
    import import_corpora as ic
    rows = []
    for i in range(400):
        rows.append({"unique_id": f"u{i}", "case_id": f"c{i}", "page": f"Page {i}", "label": "SUPPORTS", "revision_type": "synthetic" if i % 2 else "real",
                     "claim": "x" * 20, "evidence": f"Stadium number {i} in this town has a capacity of {1000 + i * 7:,} spectators for every home game ."})
    out = ic.bound_examples(rows, 50)
    assert 0 < len(out) <= 100 and len(out) % 2 == 0 and len(out) % 2 == 0
    used = [r["unique_id"] for r in out[::2]]
    assert len(set(used)) == len(used)
    assert all(int(u[1:]) % 2 == 0 for u in used), "real revisions only"
    same_frame = [dict(r, evidence=f"The stadium had a capacity of {1000 + i * 7:,} spectators for every home game .") for i, r in enumerate(rows)]
    assert len(ic.bound_examples(same_frame, 50)) == 6, "one sentence frame gives at most three pairs"
    assert all(r["evidence"][0]["quote"] in [p["text"] for p in r["passages"] if p["id"] == r["evidence"][0]["passage"]][0] for r in out)


def test_main_keeps_eval_files_identical_and_no_bound_reproduces_train(tmp_path):
    import json, subprocess
    import test_longdoc as tl  # its synthetic atoms
    a = tl.atoms(400)
    for i, x in enumerate(a):  # give some atoms a count a bound can be put on
        x["summary"] = x["summary"].rstrip(".") + f". The castle drew {i * 37 + 140} visitors during the spring fair."
    snap = {"v": 1, "fields": ["id", "title", "text", "url", "source", "licence", "published_at"],
            "atoms": [[x["id"], x["title"], x["summary"], x["url"], x["source"], "CC BY-SA 4.0", "2026-10-01"] for x in a]}
    sp = tmp_path / "commons.json"
    sp.write_text(json.dumps(snap))
    script = os.path.join(os.path.dirname(__file__), "..", "build_dataset.py")
    outs = {}
    for name, extra in (("on", []), ("off", ["--no-bound"])):
        out = tmp_path / name
        subprocess.run([sys.executable, script, "--snapshot", str(sp), "--out", str(out), "--eval-share", "0.2"] + extra, check=True, capture_output=True)
        outs[name] = out
    for f in ("eval.jsonl", "eval2.jsonl", "eval3.jsonl"):
        assert (outs["on"] / f).read_bytes() == (outs["off"] / f).read_bytes()
    on = [json.loads(l) for l in (outs["on"] / "train.jsonl").read_text().splitlines()]
    off = [json.loads(l) for l in (outs["off"] / "train.jsonl").read_text().splitlines()]
    assert [x for x in on if x.get("generator") != bound.BOUND_VERSION] == off
    new = [x for x in on if x.get("generator") == bound.BOUND_VERSION]
    assert new and sum(1 for x in new if x["label"] == "supported") == sum(1 for x in new if x["label"] == "contradicted")
    meta = json.loads((outs["on"] / "meta.json").read_text())
    assert bound.BOUND_VERSION in meta["train_generators"] and sum(meta["train_bounded_by_kind"].values()) == len(new)

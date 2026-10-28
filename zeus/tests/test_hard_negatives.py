"""Unit tests for the hard-v1 train negatives in zeus/build_dataset.py (add_hard_negatives and the
hard_* generators). Run with: python3 -m pytest zeus/tests. No network, synthetic atoms only."""
import json, os, random, re, subprocess, sys

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
import build_dataset as bd  # noqa: E402


def rng(seed=1):
    return random.Random(seed)


def one_edit(a, b):
    """The changed middle of b relative to a (common prefix and suffix removed)."""
    i = 0
    while i < min(len(a), len(b)) and a[i] == b[i]:
        i += 1
    j = 0
    while j < min(len(a), len(b)) - i and a[-1 - j] == b[-1 - j]:
        j += 1
    return a[i:len(a) - j], b[i:len(b) - j]


# contradiction generators ------------------------------------------------------------------

def test_antonym_flip_uses_new_pairs_only_and_changes_one_word():
    s = "Exports of copper rose sharply after the new port was completed."
    new, what = bd.hard_antonym_flip(s, [s], rng())
    assert new == "Exports of copper fell sharply after the new port was completed."
    assert what == "rose -> fell"
    assert not set(bd.EXTRA_FLIP_MAP) & set(bd.FLIP_MAP)  # never repeats a FLIPS word
    for s in ["The law will allow farmers to sell directly to shops in the region.", "The protein activates the immune response in the gut lining."]:
        new, _ = bd.hard_antonym_flip(s, [s], rng())
        old, rep = one_edit(s, new)
        assert len(s.split()) == len(new.split()) and old and rep


def test_antonym_flip_refuses_quotes_negation_hedges_and_names():
    p = ["The minister said that \"prices rose sharply\" during the long winter months."]
    assert bd.hard_antonym_flip(p[0], p, rng()) is None                      # inside a quotation
    s = "The share of renewable power did not rise during the decade studied."
    assert bd.hard_antonym_flip(s, [s], rng()) is None                       # negated just before
    s = "Higher tariffs may reduce imports from the region over the next decade."
    assert bd.hard_antonym_flip(s, [s], rng()) is None                       # hedged just before
    s = "Prices rose in spring and fell in autumn in most of the markets studied."
    assert bd.hard_antonym_flip(s, [s], rng()) is None                       # the antonym is there too
    s = "It was once thought a form of the English Elm Ulmus minor by some botanists."
    assert bd.hard_antonym_flip(s, [s], rng()) is None                       # part of a name


def test_antonym_flip_refuses_when_the_flipped_phrase_is_in_a_passage():
    s = "Exports of copper rose sharply after the new port was completed."
    other = "In the north, exports of copper fell sharply after the new port was completed."
    assert bd.hard_antonym_flip(s, [s, other], rng()) is None


def test_order_swap_patterns():
    s = "Coverage rose from 40% to 85% after the campaign began in the region."
    assert bd.hard_order_swap(s, [s], rng())[0] == "Coverage rose from 85% to 40% after the campaign began in the region."
    s = "The two arms stayed in hospital for 12 and 19 days, respectively, after surgery."
    assert bd.hard_order_swap(s, [s], rng())[0] == "The two arms stayed in hospital for 19 and 12 days, respectively, after surgery."
    s = "The Danube is longer than the Rhine and flows into the Black Sea."
    assert bd.hard_order_swap(s, [s], rng())[0] == "The Rhine is longer than the Danube and flows into the Black Sea."
    s = "The museum moved from 1990 to 1995 into a new building on the river."
    assert bd.hard_order_swap(s, [s], rng()) is None  # no change verb: a period, not a change


def test_negation_insert_and_remove_grammatically():
    s = "The bridge has been rebuilt twice since the flood of the old town."
    assert bd.hard_negation(s, [s], rng())[0] == "The bridge has not been rebuilt twice since the flood of the old town."
    s = "The new line will open to passengers at the end of the summer."
    assert bd.hard_negation(s, [s], rng())[0] == "The new line will not open to passengers at the end of the summer."
    s = "The committee did not approve the plan for the northern district."
    assert bd.hard_negation(s, [s], rng())[0] == "The committee did approve the plan for the northern district."
    s = "The club wasn't promoted to the first division that season at all."
    assert bd.hard_negation(s, [s], rng())[0] == "The club was promoted to the first division that season at all."


def test_negation_refuses_double_negatives_hedges_and_fixed_phrases():
    s = "The club did not win and never reached the final in those years."
    assert bd.hard_negation(s, [s], rng()) is None          # two negations already
    s = "The drug may have reduced symptoms in some of the patients studied."
    assert bd.hard_negation(s, [s], rng()) is None          # hedged
    s = "The method is not only faster but also cheaper than the old one."
    assert bd.hard_negation(s, [s], rng()) is None          # "not only" is not a negation of the fact


def test_value_shift_stays_plausible_and_new():
    s = "The library opened in 1902 and holds 70,000 volumes in its main hall."
    for seed in range(30):
        new, what = bd.hard_value_shift(s, [s], rng(seed))
        old, rep = one_edit(s, new)
        if what.startswith("year"):
            assert 1 <= abs(int(new.split("opened in ")[1][:4]) - 1902) <= 3
        else:
            n_old = int(re.search(r"holds ([\d,]+)", s).group(1).replace(",", ""))
            n_new = int(re.search(r"holds ([\d,]+)", new).group(1).replace(",", ""))
            assert n_new != n_old and len(str(n_new)) == len(str(n_old)) and 0.4 < n_new / n_old < 2
            assert "," in re.search(r"holds ([\d,]+)", new).group(1)  # formatting kept
    s = "About 96% of the households in the town had electricity by then."
    for seed in range(30):
        new, _ = bd.hard_value_shift(s, [s], rng(seed))
        assert int(re.search(r"(\d+)%", new).group(1)) <= 100
    s = "The Apollo 11 crew trained at the base with t = 2 and 24 February as key dates."
    assert bd.hard_value_shift(s, [s], rng()) is None    # identifiers, variables and days are left alone
    s = "The census in 2025 counted the population of the island for the first time."
    for seed in range(20):
        new, _ = bd.hard_value_shift(s, [s], rng(seed))
        assert int(re.search(r"in (\d{4})", new).group(1)) <= bd.MAX_YEAR


def test_value_shift_refuses_a_value_already_in_a_passage():
    s = "The bridge was completed in 1931 after six years of work on the river."
    passages = [s + " " + " ".join(f"A flood came in {y}." for y in range(1928, 1935) if y != 1931)]
    for seed in range(20):
        r = bd.hard_value_shift(s, passages, rng(seed))
        assert r is None or "year" not in r[1]


def test_entity_swap_takes_the_substitute_from_the_same_passage():
    own = ("Marie Curie studied in Paris after leaving Warsaw. She worked in Paris for most of her life. "
           "Her sister lived in Krakow for some years before the war.")
    s = "Marie Curie studied in Paris after leaving Warsaw."
    seen = set()
    for seed in range(20):
        r = bd.hard_entity_swap(s, own, [own], rng(seed))
        if r:
            new, what = r
            old, rep = one_edit(s, new)
            assert rep in own and rep not in s          # on topic: the passage really mentions it
            seen.add(rep)
    assert "Krakow" in seen
    own = "The town hall was finished in 1890. A fire destroyed the east wing in 1923, and it reopened in 1926."
    new, what = bd.hard_entity_swap("The town hall was finished in 1890.", own, [own], rng())
    assert what.startswith("year 1890 -> ") and new.split()[-1].rstrip(".") in {"1923", "1926"}


def test_entity_swap_refuses_names_glued_to_other_words():
    own = "The 2008 Open Championship was played at Royal Birkdale. Brooks Koepka did not play in it. The anti-Hindi protests were in Madras."
    s = "The 2008 Open Championship was played at Royal Birkdale."
    r = bd.hard_entity_swap(s, own, [own], rng())
    assert r is None or "Brooks Koepka" not in r[0]


def test_quantifier_flips():
    s = "All participants completed the survey within the first month of the study."
    assert bd.hard_quantifier(s, [s], rng())[0].startswith("No participants completed")
    s = "We tested six models and found that none of them passed the safety check."
    assert "all of them passed" in bd.hard_quantifier(s, [s], rng())[0]
    s = "The tax applies at all times across the whole of the country."
    assert bd.hard_quantifier(s, [s], rng()) is None


# not_covered generators --------------------------------------------------------------------

def test_modal_shift_states_hedges_as_certain():
    s = "Regular exercise may reduce the risk of falls in older adults living alone."
    assert bd.hard_modal_shift(s, [s], rng())[0] == "Regular exercise will reduce the risk of falls in older adults living alone."
    s = "Air pollution is associated with higher rates of asthma among city children."
    new, _ = bd.hard_modal_shift(s, [s], rng())
    assert new == "Air pollution causes higher rates of asthma among city children."
    p = [s, "A trial showed that air pollution causes asthma in mice."]
    assert bd.hard_modal_shift(s, p, rng()) is None                      # "causes" is in a passage: might be covered
    s = "The new drug may not reduce symptoms in all of the patients studied."
    assert bd.hard_modal_shift(s, [s], rng()) is None                    # negated: refused


def test_scope_shift_adds_a_group_or_place_absent_from_all_passages():
    s = "The compound slowed tumour growth in mice over twelve weeks of treatment."
    new, what = bd.hard_scope_shift(s, [s], rng())
    assert new == "The compound slowed tumour growth in humans over twelve weeks of treatment."
    assert bd.hard_scope_shift(s, [s, "No trial in humans has been run yet."], rng()) is None
    s = "The survey of farmers was carried out in France during the dry summer."
    for seed in range(10):
        new, what = bd.hard_scope_shift(s, [s], rng(seed))
        added = new.split("in France and ")[1].split()[0]
        assert added in bd.COUNTRIES and added not in s
    s = "The vaccine was only tested in mice before the trial was stopped."
    assert bd.hard_scope_shift(s, [s], rng()) is None                    # "only": the shift would contradict
    s = "He served as an officer in the United States Army for twenty years."
    assert bd.hard_scope_shift(s, [s], rng()) is None                    # part of a longer name


def test_relation_shift_needs_its_context_and_an_absent_relation():
    s = "Blood at Sundown is a 1966 Western film directed by Alberto Cardone."
    assert bd.hard_relation_shift(s, [s], rng())[0] == "Blood at Sundown is a 1966 Western film produced by Alberto Cardone."
    s = "The Flying Spur is a luxury car produced by Bentley Motors since 2005."
    assert bd.hard_relation_shift(s, [s], rng()) is None                 # no film or album: no shift
    s = "Blood at Sundown is a 1966 Western film directed by Alberto Cardone."
    assert bd.hard_relation_shift(s, [s, "It was produced by Cardone's own company."], rng()) is None


def test_added_clause_only_on_events_and_findings_with_absent_words():
    s = "The stadium was opened in 1931 by the mayor of the city."
    new, what = bd.hard_added_clause(s, [s], rng(), source="wikipedia")
    assert new.startswith(s[:-1]) and new.endswith(".") and new != s
    added = new[len(s) - 1:-1]
    assert added.strip(", ") in [a.strip(", ") for a in bd.ADDONS_GENERAL]
    assert all(bd._absent(w, [s]) for w in bd.content_words(added))
    s = "The stadium is a large building near the river in the old city."
    assert bd.hard_added_clause(s, [s], rng(), source="wikipedia") is None   # no event to qualify
    s = "The trial found that the drug reduced pain in most of the patients."
    new, _ = bd.hard_added_clause(s, [s], rng(), source="pubmed")
    assert new[len(s) - 1:-1].strip(", ") in [a.strip(", ") for a in bd.ADDONS_RESEARCH]


def test_absent_checks_stems_too():
    assert not bd._absent("humans", ["Results in human volunteers were mixed."])
    assert bd._absent("humans", ["Results in mice were mixed."])


# the contrastive sets and the build ----------------------------------------------------------

def atom(i, summary, source="wikipedia"):
    return {"id": f"{i:08x}-1111-4000-8000-{i:012x}", "title": f"Title {i}", "summary": summary, "content": summary,
            "url": f"https://example.org/{i}", "source": source}


TEXTS = [
    "The Danube is longer than the Rhine and flows into the Black Sea. Exports along the river rose sharply after 1990.",
    "The library opened in 1902 and holds 70,000 volumes. It was opened by the mayor of the city with a large ceremony.",
    "Regular exercise may reduce the risk of falls in older adults. The trial found that balance improved in most of the patients.",
    "The compound slowed tumour growth in mice over twelve weeks. All participants completed the survey within the first month.",
    "Blood at Sundown is a 1966 Western film directed by Alberto Cardone. It was released in Italy in the spring of 1967.",
    "The bridge has been rebuilt twice since the flood of 1951. The new line will open to passengers at the end of the summer.",
    "Air pollution is associated with higher rates of asthma among city children. The survey of farmers was carried out in France.",
    "Marie Curie studied in Paris after leaving Warsaw in 1891. Her sister lived in Krakow for some years before the war.",
]


def atoms_n(n):
    return [atom(i, TEXTS[i % len(TEXTS)].replace("The ", f"The {['north', 'south', 'east', 'west', 'old', 'new'][i % 6]} ", 1)
                 if i >= len(TEXTS) else TEXTS[i], source="pubmed" if i % len(TEXTS) in (2, 3, 6) else "wikipedia") for i in range(n)]


def test_contrastive_sets_have_the_right_labels_and_exact_evidence():
    atoms = atoms_n(16)
    train = bd.build(atoms, eval_share=0.0)["train"]
    hard = bd.add_hard_negatives(train, atoms, 0.0)
    assert hard, "no hard examples were made"
    kinds = {ex["kind"] for ex in hard}
    assert "hard_twin_supported" in kinds and len(kinds) >= 5, kinds
    by_pair = {}
    for ex in hard:
        by_pair.setdefault(ex["pair"], []).append(ex)
        assert ex["generator"] == bd.HARD_NEGATIVES_VERSION
        ids = {p["id"] for p in ex["passages"]}
        assert ex["atom_id"][:8] in ids                                  # the true passage is always there
        assert all(p["url"].startswith("https://") and p["source"] and p["text"] for p in ex["passages"])
        if ex["label"] == "not_covered":
            assert ex["evidence"] == []
            assert not bd._in_any(ex["claim"], [p["text"] for p in ex["passages"]])
        else:
            for e in ex["evidence"]:
                text = next(p["text"] for p in ex["passages"] if p["id"] == e["passage"])
                assert e["quote"] in text                                # exact substring
    for pair, group in by_pair.items():
        sup = [g for g in group if g["label"] == "supported"]
        assert len(sup) == 1
        for g in group:
            assert g["passages"] == sup[0]["passages"]                   # same passages: only the edit differs
            if g is not sup[0]:
                assert g["claim"] != sup[0]["claim"]
                assert g["kind"][5:] in bd.CONTRA_GENERATORS + bd.NC_GENERATORS
                assert g["label"] == ("contradicted" if g["kind"][5:] in bd.CONTRA_GENERATORS else "not_covered")
                if g["label"] == "contradicted":
                    assert g["evidence"][0]["quote"] == sup[0]["claim"]


def test_hard_negatives_are_deterministic_and_train_only():
    atoms = atoms_n(40)
    a = bd.build(atoms, 0.3)
    b = bd.build(atoms, 0.3)
    ha = bd.add_hard_negatives(a["train"], atoms, 0.3)
    hb = bd.add_hard_negatives(b["train"], atoms, 0.3)
    assert ha == hb and a["train"] == b["train"]
    eval_ids = {x["id"] for x in atoms if bd.stable_split(x["id"], 0.3) == "eval"}
    assert eval_ids, "the synthetic set needs eval atoms"
    for ex in ha:
        assert ex["atom_id"] not in eval_ids
        assert not {p["id"] for p in ex["passages"]} & {i[:8] for i in eval_ids}   # no eval passage as a distractor
    # the eval split never sees them and the plain train order is untouched
    plain = bd.build(atoms, 0.3)
    assert a["eval"] == plain["eval"]
    assert [x for x in a["train"] if not x.get("generator")] == plain["train"]


def test_an_atom_keeps_its_hard_examples_when_others_are_added():
    small, big = atoms_n(24), atoms_n(48)
    h_small = bd.add_hard_negatives(bd.build(small, 0.0)["train"], small, 0.0)
    h_big = bd.add_hard_negatives(bd.build(big, 0.0)["train"], big, 0.0)
    claims = lambda hs, aid: sorted((x["kind"], x["claim"]) for x in hs if x["atom_id"] == aid)
    same = sum(claims(h_small, x["id"]) == claims(h_big, x["id"]) for x in small)
    assert same >= len(small) // 2  # the distractors may change, the edits mostly do not


def test_main_keeps_eval_files_byte_identical(tmp_path):
    atoms = atoms_n(60)
    snap = {"v": 1, "fields": ["id", "title", "text", "url", "source", "licence", "published_at"],
            "atoms": [[a["id"], a["title"], a["summary"], a["url"], a["source"], "CC BY-SA 4.0", "2026-10-01"] for a in atoms]}
    sp = tmp_path / "commons.json"
    sp.write_text(json.dumps(snap))
    script = os.path.join(HERE, "..", "build_dataset.py")
    outs = {}
    for name, extra in (("on", []), ("off", ["--no-hard-negatives"])):
        out = tmp_path / name
        subprocess.run([sys.executable, script, "--snapshot", str(sp), "--out", str(out), "--eval-share", "0.3"] + extra,
                       check=True, capture_output=True)
        outs[name] = out
    for f in ("eval.jsonl", "eval2.jsonl"):
        assert (outs["on"] / f).read_bytes() == (outs["off"] / f).read_bytes()
    on = [json.loads(l) for l in (outs["on"] / "train.jsonl").read_text().splitlines()]
    off = [json.loads(l) for l in (outs["off"] / "train.jsonl").read_text().splitlines()]
    assert [x for x in on if not x.get("generator")] == off
    assert len(on) > len(off)
    meta_on = json.loads((outs["on"] / "meta.json").read_text())
    meta_off = json.loads((outs["off"] / "meta.json").read_text())
    assert meta_on["train_generators"] == ["rules-v1", bd.HARD_NEGATIVES_VERSION]
    assert meta_off["train_generators"] == ["rules-v1"] and meta_off["train_hard_by_kind"] == {}
    assert sum(meta_on["train_hard_by_kind"].values()) == len(on) - len(off)

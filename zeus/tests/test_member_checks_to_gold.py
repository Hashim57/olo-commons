import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from member_checks_to_gold import as_item, main, pick_items, tidy, to_gold
from build_dataset import stable_split

T1 = "The River Aire rises at Malham Tarn in North Yorkshire and flows through Leeds before joining the Ouse."
T2 = "Leeds is a city in West Yorkshire, England. It stands on the River Aire."


def ex(claim="The River Aire flows through Leeds.", label="supported", **kw):
    base = {"claim": claim, "label": label, "rationale": "r", "atom_id": "aaaaaaaa-0000-4000-8000-000000000001",
            "evidence": [] if label == "not_covered" else [{"passage": "aaaaaaaa", "quote": "flows through Leeds"}],
            "passages": [{"id": "aaaaaaaa", "source": "wikipedia", "url": "https://en.wikipedia.org/wiki/River_Aire", "text": T1},
                         {"id": "bbbbbbbb", "source": "wikipedia", "url": "https://en.wikipedia.org/wiki/Leeds", "text": T2}]}
    base.update(kw)
    return base


def exported(**kw):
    base = {**ex(), "kind": "member_check", "check_id": "c1", "votes": 4, "agree": 3, "rationale": "Checked by 4 verified members of POL Net; 3 agreed."}
    del base["atom_id"]
    base.update(kw)
    return base


def test_an_item_carries_no_answer_and_keeps_provenance():
    it = as_item(ex())
    assert set(it) == {"claim", "passages"}
    assert it["passages"][0]["atom_id"] == "aaaaaaaa-0000-4000-8000-000000000001" and "atom_id" not in it["passages"][1]
    assert as_item(ex(), known="supported")["known"] == "supported"


def test_items_the_api_would_refuse_are_left_out():
    assert as_item(ex(claim="short")) is None
    assert as_item(ex(passages=ex()["passages"][:1])) is None
    bad = ex()
    bad["passages"][1]["url"] = "http://plain.example/x"
    assert as_item(bad) is None


def test_pick_spreads_labels_and_adds_controls_from_gold():
    train = [ex(claim=f"Claim number {i} about the river.", label=l) for i, l in enumerate(["supported", "contradicted", "not_covered"] * 10)]
    gold = [ex(claim=f"A hand-written control claim {i}.", label="contradicted") for i in range(5)]
    items = pick_items(train, gold, 9, 2, seed=3)
    assert len(items) == 11 and sum(1 for x in items if x.get("known") == "contradicted") == 2
    assert len({x["claim"] for x in items}) == 11
    assert items == pick_items(train, gold, 9, 2, seed=3), "the same seed picks the same items"


def test_agreed_export_becomes_a_valid_gold_line():
    g, why = to_gold(exported())
    assert why is None, why
    assert g["kind"] == "member_check" and g["label"] == "supported" and g["evidence"] == [{"passage": "aaaaaaaa", "quote": "flows through Leeds"}]


def test_what_is_left_out_and_why():
    assert "three" in to_gold(exported(agree=2))[1]
    assert "exact substring" in to_gold(exported(evidence=[{"passage": "aaaaaaaa", "quote": "flows through Bradford"}]))[1]
    assert "dash" in to_gold(exported(claim="The River Aire \u2014 a river \u2014 flows through Leeds."))[1]
    held = next(f"{i:08x}-0000-4000-8000-000000000000" for i in range(10000) if stable_split(f"{i:08x}-0000-4000-8000-000000000000", 0.1) == "eval")
    e = exported()
    e["passages"][1]["atom_id"] = held
    assert "eval atom" in to_gold(e)[1]


def test_both_commands_end_to_end(tmp_path, capsys):
    train, gold_dir = tmp_path / "train.jsonl", tmp_path / "gold"
    gold_dir.mkdir()
    train.write_text("\n".join(json.dumps(ex(claim=f"Claim number {i} about the river.", label=l)) for i, l in enumerate(["supported", "contradicted", "not_covered"] * 2)))
    (gold_dir / "gold-2026-01-01.jsonl").write_text(json.dumps(ex(claim="A hand-written control claim.", label="contradicted")) + "\n")
    (gold_dir / "checks-2026-01-01.jsonl").write_text(json.dumps(ex(claim="An earlier member check is not a control.")) + "\n")
    out = tmp_path / "items.json"
    assert main(["items", "--train", str(train), "--gold-dir", str(gold_dir), "--n", "6", "--controls", "5", "--out", str(out)]) == 0
    items = json.loads(out.read_text())["items"]
    assert len(items) == 7 and [x["claim"] for x in items if "known" in x] == ["A hand-written control claim."]
    assert all("label" not in x and "evidence" not in x for x in items)
    exp = tmp_path / "export.json"
    exp.write_text(json.dumps({"examples": [exported(), exported(check_id="c2", agree=1)]}))
    dest = tmp_path / "checks.jsonl"
    capsys.readouterr()
    assert main(["gold", str(exp), "--out", str(dest)]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["kept"] == 1 and report["left_out"][0]["check_id"] == "c2"
    assert [json.loads(l)["check_id"] for l in dest.read_text().splitlines()] == ["c1"]


def test_only_open_sources_go_out_or_come_back():
    closed = ex()
    closed["passages"][1]["source"] = "pubmed"
    assert as_item(closed) is None and as_item(closed, sources=None) is not None
    e = exported()
    e["passages"][1]["source"] = "arxiv"
    assert "not in the open sources" in to_gold(e)[1]


def test_tidy_drops_a_cut_off_ending_and_a_doubled_full_stop_but_not_meaning():
    assert tidy("A debut album 667.. The Neighbour of the Beast. It was reissued. In Tok") == "A debut album 667. The Neighbour of the Beast. It was reissued."
    assert tidy("Wait... what? Yes.") == "Wait... what? Yes."
    short = "One sentence only that was cut off before its e"
    assert tidy(short) == short, "nothing is dropped when too little would remain"
    rule_made = ex()
    rule_made["passages"][0]["text"] = T1 + " It later joins the Humber and then the"
    assert as_item(rule_made)["passages"][0]["text"] == T1
    assert as_item(rule_made, known="supported")["passages"][0]["text"].endswith("and then the"), "a control keeps its text"

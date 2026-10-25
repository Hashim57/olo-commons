"""Unit tests for zeus/build_dataset.py. Run with: python3 -m pytest zeus/tests
No network: atoms are synthetic but shaped like olo_export rows."""
import json, os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import build_dataset as bd  # noqa: E402


def atom(i, summary, title=None, source="wikipedia"):
    return {"id": f"{i:08x}-0000-4000-8000-{i:012x}", "title": title or f"Title {i}", "summary": summary,
            "content": summary, "url": f"https://example.org/{i}", "source": source, "created_at": f"2026-10-{1 + i % 28:02d}T00:00:00Z"}


ATOMS = [
    atom(1, "Project Gutenberg was founded in 1971 by Michael Hart. It offers over 70,000 free books to readers."),
    atom(2, "The Great Barrier Reef lies off the northern coast of Queensland. It is the largest coral reef system on Earth."),
    atom(3, "Marie Curie was born in Warsaw in 1867. She received two Nobel Prizes for her work on radioactivity."),
    atom(4, "The Danube flows east through ten countries before it reaches the Black Sea. It is Europe's second longest river."),
    atom(5, "Vaccination rates increased after the campaign began. Coverage reached 85 percent of children in the region."),
    atom(6, "The library opened in 1902 and was closed for renovation in 2015. It holds more than two million volumes."),
]


def test_export_page_accepts_object_and_list():
    body = {"atoms": ATOMS[:2], "next_after": "2026-10-02T00:00:00Z", "licence_note": "x"}
    atoms, nxt = bd.export_page(body)
    assert len(atoms) == 2 and nxt == "2026-10-02T00:00:00Z"
    atoms, nxt = bd.export_page(ATOMS[:3])
    assert len(atoms) == 3 and nxt == ATOMS[2]["created_at"]
    assert bd.export_page({"atoms": []}) == ([], None)
    assert bd.export_page(None) == ([], None)


def test_sentences_filters_by_length():
    s = bd.sentences("Short. " + ATOMS[0]["summary"] + " " + "x" * 400 + ".")
    assert all(40 <= len(x) <= 300 for x in s)
    assert any("Gutenberg" in x for x in s)


def test_stable_split_is_deterministic():
    ids = [a["id"] for a in ATOMS]
    first = [bd.stable_split(i, 0.5) for i in ids]
    assert first == [bd.stable_split(i, 0.5) for i in ids]
    assert set(first) <= {"train", "eval"}


def test_flip_relation_changes_one_relation_word():
    rng = random.Random(1)
    out = bd.flip_relation("Vaccination rates increased after the campaign began.", rng)
    assert out is not None
    new, what = out
    assert what.startswith("relation ")
    assert new != "Vaccination rates increased after the campaign began."
    # exactly one word differs
    a, b = new.split(), "Vaccination rates increased after the campaign began.".split()
    assert len(a) == len(b) and sum(x != y for x, y in zip(a, b)) == 1


def test_flip_relation_keeps_case_and_negation():
    rng = random.Random(3)
    assert bd.flip_relation("Before the war the town grew.", rng) == ("After the war the town grew.", "relation Before -> After")
    assert bd.flip_relation("The reef is not dead.", rng) == ("The reef is dead.", "relation is not -> is")
    assert bd.flip_relation("The reef is dead.", rng) == ("The reef is not dead.", "relation is -> is not")
    assert bd.flip_relation("Nothing to flip here, just words.", rng) is None


def test_contradict_never_returns_the_original():
    rng = random.Random(5)
    titles = [a["title"] for a in ATOMS]
    for a in ATOMS:
        for s in bd.sentences(a["summary"]):
            c = bd.contradict(s, rng, titles)
            if c is not None:
                assert c[0] != s
                assert " -> " in c[1]


def test_build_makes_all_three_labels_with_provenance():
    data = bd.build(ATOMS, eval_share=0.0)
    train = data["train"]
    assert data["eval"] == []
    labels = {ex["label"] for ex in train}
    assert labels == {"supported", "contradicted", "not_covered"}
    for ex in train:
        assert set(ex) >= {"claim", "passages", "label", "evidence", "rationale", "atom_id"}
        for p in ex["passages"]:
            assert p["url"].startswith("https://") and p["source"] and p["text"]
        if ex["label"] == "not_covered":
            assert ex["evidence"] == []
            assert all(p["id"] != ex["atom_id"][:8] for p in ex["passages"])
        else:
            ids = {p["id"] for p in ex["passages"]}
            for e in ex["evidence"]:
                assert e["passage"] in ids
                text = next(p["text"] for p in ex["passages"] if p["id"] == e["passage"])
                assert e["quote"] in text
    # some contradictions should be relation flips, not only numbers
    kinds = [ex["rationale"] for ex in train if ex["label"] == "contradicted"]
    assert any("relation " in k for k in kinds)


def test_count_gold_counts_valid_lines_only(tmp_path):
    g = tmp_path / "gold"
    g.mkdir()
    good = {"claim": "c", "passages": [{"id": "a", "source": "s", "url": "https://x", "text": "c"}], "label": "supported", "evidence": [{"passage": "a", "quote": "c"}], "rationale": "r"}
    (g / "gold-1.jsonl").write_text(json.dumps(good) + "\n\nnot json\n" + json.dumps({"claim": "x", "label": "weird"}) + "\n")
    (g / "notes.txt").write_text("ignored")
    assert bd.count_gold(str(g)) == (1, 1)
    assert bd.count_gold(str(tmp_path / "missing")) == (0, 0)


def test_near_misses_share_words_but_do_not_cover():
    pool = ATOMS + [atom(7, "Queensland has many beaches and a warm climate. Tourism is a major industry in the northern parts of the state."),
                    atom(8, "The Great Barrier Reef lies off the northern coast of Queensland, and it is the largest coral reef system on Earth today.")]
    claim = "The Great Barrier Reef lies off the northern coast of Queensland."
    near = bd.near_misses(claim, ATOMS[1], pool)
    ids = [o["id"] for o in near]
    assert pool[6]["id"] in ids              # shares Queensland and northern: a near miss
    assert pool[7]["id"] not in ids          # restates the claim: refused, it would support it
    assert ATOMS[1]["id"] not in ids         # never the claim's own atom
    assert bd.near_misses("Zzzz qqqq wwww xxxx.", ATOMS[0], pool) == []


NEAR = ATOMS + [
    atom(9, "Queensland has many beaches and a warm climate. Tourism is a major industry in the northern parts of the state."),
    atom(10, "Warsaw is the capital of Poland and its largest city. The city was rebuilt after heavy damage in the war."),
    atom(11, "The Black Sea is bordered by six countries including Romania and Turkey. Several large rivers drain into it."),
    atom(12, "Michael Hart worked at the University of Illinois. He typed the first electronic text on a mainframe computer."),
]


def test_near_miss_goes_to_train_only_and_keeps_eval_frozen():
    plain = bd.build(NEAR, eval_share=0.5, near_miss=False)
    hard = bd.build(NEAR, eval_share=0.5, near_miss=True)
    assert any(ex.get("kind") == "near_miss" for ex in hard["train"])
    assert hard["eval"] == plain["eval"]
    assert all(ex.get("kind") != "near_miss" for ex in hard["eval"])
    nm = [ex for ex in hard["train"] if ex.get("kind") == "near_miss"]
    for ex in nm:
        assert ex["label"] == "not_covered" and ex["evidence"] == []
        assert all(p["id"] != ex["atom_id"][:8] for p in ex["passages"])
    # the plain train examples keep their order; near misses are only inserted between them
    assert [x for x in hard["train"] if x.get("kind") != "near_miss"] == plain["train"]


def test_snapshot_rows_become_atoms_with_the_same_ids():
    snap = {"v": 1, "fields": ["id", "title", "text", "url", "source", "licence", "published_at"],
            "atoms": [["0b33889b-f1c3-4711-8ed4-96477ffee3ea", "George Washington Watts", "American manufacturer. He founded Watts Hospital in Durham.", "https://en.wikipedia.org/wiki/George_Washington_Watts", "wikipedia", "CC BY-SA 4.0", "2026-10-21"],
                      ["ffffffff-0000-0000-0000-000000000000", "No text", "", "https://example.org", "arxiv", "CC0", None]]}
    atoms = bd.atoms_from_snapshot(snap)
    assert len(atoms) == 1  # the row without text is dropped
    a = atoms[0]
    assert a["id"] == "0b33889b-f1c3-4711-8ed4-96477ffee3ea" and a["summary"].startswith("American manufacturer") and a["source"] == "wikipedia"
    # the split depends only on the id, so a snapshot build keeps the frozen eval split
    assert bd.stable_split(a["id"], 0.1) == bd.stable_split("0b33889b-f1c3-4711-8ed4-96477ffee3ea", 0.1)
    assert bd.passage(a)["text"] == a["summary"]

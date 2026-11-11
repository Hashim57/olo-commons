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


def test_eval2_uses_only_eval_atoms_with_the_hard_patterns():
    from build_dataset import build, build_eval2, stable_split
    def text(i):
        if i % 2 == 0:
            return f"Harbour{i} is a harbour town founded by settlers in 19{50 + i % 40}. Its port is larger than the port of Harbour{i + 2} and busier than before."
        return f"The village of Mine{i} was founded near a river in 19{50 + i % 40} and mined copper. Its mine is deeper than the mine at Mine{i + 2} and older than most."
    atoms = [{"id": f"{i:08x}-0000-0000-0000-000000000000", "title": f"Place {i}", "url": f"https://x/{i}", "source": "wikipedia", "summary": text(i)} for i in range(60)]
    ev2 = build_eval2(atoms, 0.3)
    assert ev2, "eval2 is empty"
    eval_ids = {a["id"] for a in atoms if stable_split(a["id"], 0.3) == "eval"}
    assert all(ex["atom_id"] in eval_ids for ex in ev2)
    kinds = {ex["kind"] for ex in ev2}
    assert {"near_miss", "relation_flip", "true_passage_last"} <= kinds, kinds
    for ex in ev2:
        if ex["kind"] == "true_passage_last":
            assert ex["passages"][-1]["id"] == ex["atom_id"][:8] and ex["label"] == "supported"
        if ex["kind"] == "relation_flip":
            assert ex["label"] == "contradicted" and ex["claim"] != ex["evidence"][0]["quote"]
    # the frozen split is untouched by the extra generator
    assert build(atoms, 0.3)["eval"] == build(atoms, 0.3)["eval"]
    assert build_eval2(atoms, 0.3) == ev2


def test_train_passages_are_shuffled_but_eval_order_is_frozen():
    from build_dataset import build
    atoms = [{"id": f"{i:08x}-0000-0000-0000-000000000000", "title": f"Place {i}", "url": f"https://x/{i}", "source": "wikipedia",
              "summary": f"Harbour{i} is a harbour town founded by settlers in 19{50 + i % 40}. Its port is larger than the port of Harbour{i + 2}."} for i in range(80)]
    d = build(atoms, 0.3)
    train_sup = [ex for ex in d["train"] if ex["label"] == "supported"]
    first = sum(1 for ex in train_sup if ex["passages"][0]["id"] == ex["atom_id"][:8])
    assert 0 < first < len(train_sup), "train passages should be shuffled"
    assert all(ex["passages"][0]["id"] == ex["atom_id"][:8] for ex in d["eval"] if ex["label"] == "supported")
    assert build(atoms, 0.3)["train"] == d["train"]


def test_snapshot_flag_without_a_value_means_the_published_copy(tmp_path):
    """zeus-train.yml falls back to `build_dataset.py --snapshot` with no path when the live export is down;
    argparse used to refuse that (expected one argument), so the fallback never built anything."""
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", nargs="?", const=bd.SNAPSHOT_URL)
    assert ap.parse_args(["--snapshot"]).snapshot == bd.SNAPSHOT_URL
    assert ap.parse_args(["--snapshot", "x.json"]).snapshot == "x.json"
    assert ap.parse_args([]).snapshot is None
    assert bd.SNAPSHOT_URL.startswith("https://") and bd.SNAPSHOT_URL.endswith("/snapshot/commons.json")
    # a local path is opened as before
    f = tmp_path / "commons.json"
    f.write_text(json.dumps({"fields": ["id", "title", "text", "url", "source"], "atoms": [["a1", "T", "Some text here.", "https://x/1", "wikipedia"]]}), encoding="utf-8")
    assert bd.atoms_from_snapshot(bd.load_snapshot(str(f)))[0]["id"] == "a1"


def test_usable_atoms_run_before_the_split_so_a_stub_is_neither_claim_nor_passage():
    import quality
    atoms = [atom(i, f"Sentence number {i} says something true about topic {i} in enough words.") for i in range(6)]
    atoms.append({"id": "stub-1", "title": "New Book", "summary": "new book new book new book new book new book", "content": "", "url": "https://archive.org/details/x", "source": "archive_org"})
    atoms.append(dict(atoms[0]))  # the export repeated a page-boundary atom
    kept, dropped = quality.usable_atoms(atoms)
    assert dropped == {"duplicate": 1, "stub": 1, "housekeeping": 0, "stub_by_rule": {"label": 1}}
    data = bd.build(kept, 0.3, near_miss=False)
    seen = {p["id"] for split in data.values() for ex in split for p in ex["passages"]}
    assert "stub-1"[:8] not in seen
    assert all(ex["claim"] != "new book new book new book new book new book" for split in data.values() for ex in split)


def test_cap_usable_filters_before_it_caps_so_junk_takes_no_slot():
    stub = {"id": "stub-1", "title": "New Book", "summary": "new book new book new book new book new book", "content": "", "url": "https://archive.org/details/x", "source": "archive_org"}
    real = [atom(i, f"Sentence number {i} says something true about topic {i} in enough words.") for i in range(5)]
    atoms = [stub, dict(stub), real[0], real[1], dict(real[1]), real[2], real[3], real[4]]
    kept, dropped, read = bd.cap_usable(atoms, 3)
    assert [a["id"] for a in kept] == [real[0]["id"], real[1]["id"], real[2]["id"]], "the oldest three usable atoms, the stubs and the repeat passed over"
    assert read == 8
    assert dropped["stub"] == 1 and dropped["duplicate"] == 2, "the filter's counts cover every row read, not just the capped ones"
    assert bd.cap_usable(real, 10)[0] == real, "a cap above the pool keeps everything"
    assert bd.enough(atoms, 5) is True and bd.enough(atoms, 6) is False, "paging stops once the rows read hold the cap in usable atoms"


def test_cap_modes_choose_different_atoms_and_keep_export_order():
    real = [atom(i, f"Sentence number {i} says something true about topic {i} in enough words.") for i in range(20)]
    ids = [a["id"] for a in real]
    oldest, _, read = bd.cap_usable(real, 5)
    assert [a["id"] for a in oldest] == ids[:5] and read == 20, "the default is the oldest five, as before"
    assert [a["id"] for a in bd.cap_usable(real, 5, "oldest")[0]] == ids[:5]
    newest = [a["id"] for a in bd.cap_usable(real, 5, "newest")[0]]
    assert newest == ids[-5:], "newest keeps the last five in export order"
    hashed = [a["id"] for a in bd.cap_usable(real, 5, "hash")[0]]
    assert len(hashed) == 5 and hashed == [i for i in ids if i in set(hashed)], "hash keeps five atoms in export order"
    assert hashed == sorted(hashed, key=ids.index)
    assert set(hashed) == set(sorted(ids, key=bd.cap_rank)[:5]), "the five with the lowest cap_rank"
    # a stable sample: adding atoms changes the kept set only at the edge of the cut, never the order
    more = real + [atom(i, f"Sentence number {i} says something true about topic {i} in enough words.") for i in range(20, 30)]
    hashed_more = {a["id"] for a in bd.cap_usable(more, 5, "hash")[0]}
    assert hashed_more == set(sorted([a["id"] for a in more], key=bd.cap_rank)[:5])
    assert all(a["id"] in hashed_more or bd.cap_rank(a["id"]) >= max(bd.cap_rank(i) for i in hashed_more) for a in real if a["id"] in hashed)
    # every mode keeps everything when the cap is above the pool, and refuses an unknown mode
    for mode in bd.CAP_MODES:
        assert bd.cap_usable(real, 50, mode)[0] == real, mode
    try:
        bd.cap_usable(real, 5, "random")
        assert False, "an unknown cap mode must be refused"
    except ValueError:
        pass
    # cap_rank and stable_split read different digits of the hash, so the eval share does not move with the cap
    assert all(0 <= bd.cap_rank(i) < 1 for i in ids)
    assert bd.cap_rank(ids[0]) != int(__import__("hashlib").sha256(ids[0].encode()).hexdigest()[:8], 16) / 0xFFFFFFFF


def test_near_misses_index_matches_a_full_scan_and_follows_the_pool():
    pool = ATOMS + [atom(7, "Queensland has many beaches and a warm climate. Tourism is a major industry in the northern parts of the state."),
                    atom(8, "The Great Barrier Reef lies off the northern coast of Queensland, and it is the largest coral reef system on Earth today.")]
    claim = "The Great Barrier Reef lies off the northern coast of Queensland."
    cw = bd.content_words(claim)

    def full_scan(p):
        scored = []
        for o in p:
            text = o.get("summary") or o.get("content") or ""
            if o["id"] == ATOMS[1]["id"] or claim[:60] in text:
                continue
            shared = len(cw & bd.content_words(text + " " + (o.get("title") or "")))
            if shared and shared / len(cw) <= 0.6:
                scored.append((shared, o["id"], o))
        scored.sort(key=lambda t: (-t[0], t[1]))
        return [o["id"] for _, _, o in scored[:3]]

    assert [o["id"] for o in bd.near_misses(claim, ATOMS[1], pool)] == full_scan(pool)
    # a different pool (the cache must not answer from the last one)
    small = [ATOMS[0], ATOMS[1]]
    assert [o["id"] for o in bd.near_misses(claim, ATOMS[1], small)] == full_scan(small)
    # the same list grown in place is re-indexed too
    small.append(pool[6])
    assert pool[6]["id"] in [o["id"] for o in bd.near_misses(claim, ATOMS[1], small)]

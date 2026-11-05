"""Unit tests for the compose-v1 train examples (zeus/compose.py). Run with: python3 -m pytest zeus/tests.
No network, synthetic atoms only."""
import os, random, sys, uuid

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
import build_dataset as bd  # noqa: E402
import compose  # noqa: E402

TOPICS = ["river", "bridge", "castle", "library", "harbour", "railway", "museum", "theatre", "market", "garden",
          "tower", "canal", "school", "hospital", "airport", "stadium", "cathedral", "factory", "lighthouse", "observatory"]


def atoms(n=60):
    out = []
    for i in range(n):
        t = TOPICS[i % len(TOPICS)]
        year = 1700 + 7 * i
        text = (f"The old {t} number {i} stands beside the main square of the town of Example{i}. "
                f"It was built in {year} by local workers using stone from the nearby hills of the valley. "
                f"Visitors can reach the {t} by a short walk from the central station of the town.")
        out.append({"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://example.org/{i}")), "source": "wikipedia", "url": f"https://example.org/{i}", "summary": text, "title": f"{t} {i}"})
    return out


def build(a):
    train = []
    made = compose.add_composed(train, a, 0.1, bd.compose_contra)
    return train, made


def test_train_atoms_only_and_every_quote_is_in_its_passage():
    a = atoms()
    _, made = build(a)
    assert made, "the synthetic atoms should give composed examples"
    eval_ids = {x["id"][:8] for x in a if bd.stable_split(x["id"], 0.1) == "eval"}
    for ex in made:
        assert ex["generator"] == compose.COMPOSE_VERSION
        texts = {p["id"]: p["text"] for p in ex["passages"]}
        assert not set(texts) & eval_ids, "no eval atom may appear as a passage"
        for ev in ex["evidence"]:
            assert ev["quote"] in texts[ev["passage"]]
        if ex["label"] == "not_covered":
            assert ex["evidence"] == []


def test_composed_set_is_contrastive_over_the_same_claim():
    _, made = build(atoms())
    by_pair = {}
    for ex in made:
        if ex["kind"].startswith("compose_"):
            by_pair.setdefault(ex["pair"], {})[ex["kind"]] = ex
    assert by_pair
    for kinds in by_pair.values():
        sup, miss = kinds["compose_supported"], kinds["compose_missing_half"]
        assert sup["claim"] == miss["claim"]
        assert len(sup["evidence"]) == 2 and sup["evidence"][0]["passage"] != sup["evidence"][1]["passage"]
        # the missing half: the second quote's passage is absent from the not_covered example
        assert sup["evidence"][1]["passage"] not in {p["id"] for p in miss["passages"]}
        assert sup["evidence"][0]["passage"] in {p["id"] for p in miss["passages"]}
        if "compose_false_half" in kinds:
            f = kinds["compose_false_half"]
            assert f["label"] == "contradicted" and f["claim"] != sup["claim"]
            assert f["evidence"] == [sup["evidence"][1]]


def test_never_the_eval3_joint_and_never_a_decade():
    _, made = build(atoms())
    for ex in made:
        assert ", and " not in ex["claim"].replace(ex["evidence"][0]["quote"] if ex["evidence"] else "\0", "")
        assert "0s" not in ex["claim"]


def test_century_rules():
    assert compose.century_of(1863) == 19 and compose.century_of(1801) == 19 and compose.century_of(2001) == 21
    assert compose.century_of(1900) is None  # either century to many readers: no claim
    assert [compose.ordinal(n) for n in (1, 2, 3, 4, 11, 12, 13, 19, 21, 22)] == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "19th", "21st", "22nd"]
    assert compose.YEAR_RE.search("built in 1863 by") and not compose.YEAR_RE.search("in 1863-1865") and not compose.YEAR_RE.search("in the 1990s")
    a = atoms()
    others = a[1:3]
    # atom 0 was built in 1700, which ends in 00, so it gives no pair at all
    assert compose.century_pair(a[0], others, random.Random(1)) == []
    pair = compose.century_pair(a[1], others[1:] + a[3:4], random.Random(1))  # 1707
    good, bad = pair
    assert "in the 18th century" in good["claim"] and good["label"] == "supported"
    assert bad["label"] == "contradicted" and ("in the 17th century" in bad["claim"] or "in the 19th century" in bad["claim"])


def test_a_21st_century_year_is_never_moved_into_the_22nd():
    a = atoms(3)
    a[0]["summary"] = "The new terminal of the airport number 0 opened in 2008 after a long period of building works."
    for seed in range(20):
        good, bad = compose.century_pair(a[0], a[1:], random.Random(seed))
        assert "21st century" in good["claim"] and "20th century" in bad["claim"]


def test_english_joints_only_between_english_sentences():
    es = atoms(4)
    for x in es:
        x["source"] = "wikipedia_es"
        x["summary"] = ("El antiguo puente de la ciudad se encuentra junto a la plaza mayor del pueblo de Ejemplo. "
                        f"Fue construido por trabajadores locales con piedra de las colinas cercanas del valle {x['title']}.")
    for seed in range(10):
        out = compose.composed_set(es[0], es[1], es[2:], random.Random(seed), lambda s, t, r: None)
        for ex in out:
            assert " Also, " not in ex["claim"] and " In addition, " not in ex["claim"] and ", while " not in ex["claim"]


def test_deterministic_and_leaves_other_train_examples_in_order():
    a = atoms()
    base = [{"claim": f"c{i}", "label": "supported"} for i in range(50)]
    t1, m1 = list(base), None
    m1 = compose.add_composed(t1, a, 0.1, bd.compose_contra)
    t2 = list(base)
    m2 = compose.add_composed(t2, list(reversed(a)), 0.1, bd.compose_contra)
    assert m1 == m2 and t1 == t2  # input order does not matter
    assert [x for x in t1 if x.get("generator") != compose.COMPOSE_VERSION] == base


def test_main_keeps_eval_files_identical_and_no_compose_reproduces_train(tmp_path):
    import json, subprocess
    a = atoms(80)
    snap = {"v": 1, "fields": ["id", "title", "text", "url", "source", "licence", "published_at"],
            "atoms": [[x["id"], x["title"], x["summary"], x["url"], x["source"], "CC BY-SA 4.0", "2026-10-01"] for x in a]}
    sp = tmp_path / "commons.json"
    sp.write_text(json.dumps(snap))
    script = os.path.join(HERE, "..", "build_dataset.py")
    outs = {}
    for name, extra in (("on", []), ("off", ["--no-compose"])):
        out = tmp_path / name
        subprocess.run([sys.executable, script, "--snapshot", str(sp), "--out", str(out), "--eval-share", "0.2"] + extra, check=True, capture_output=True)
        outs[name] = out
    for f in ("eval.jsonl", "eval2.jsonl", "eval3.jsonl"):
        assert (outs["on"] / f).read_bytes() == (outs["off"] / f).read_bytes()
    on = [json.loads(l) for l in (outs["on"] / "train.jsonl").read_text().splitlines()]
    off = [json.loads(l) for l in (outs["off"] / "train.jsonl").read_text().splitlines()]
    assert [x for x in on if x.get("generator") != compose.COMPOSE_VERSION] == off
    meta = json.loads((outs["on"] / "meta.json").read_text())
    assert meta["train_generators"][-1] == compose.COMPOSE_VERSION
    assert sum(meta["train_composed_by_kind"].values()) == len(on) - len(off) > 0

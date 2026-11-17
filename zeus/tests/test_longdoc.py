"""Unit tests for the longdoc-v1 train examples (zeus/longdoc.py). No network, synthetic atoms only."""
import os, sys, uuid
from collections import Counter

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
import build_dataset as bd  # noqa: E402
import longdoc  # noqa: E402

TOPICS = ["river", "bridge", "castle", "library", "harbour", "railway", "museum", "theatre", "market", "garden"]


def atoms(n=400, source="wikipedia"):
    out = []
    for i in range(n):
        t = TOPICS[i % len(TOPICS)]
        text = (f"The old {t} number {i} stands beside the main square of the town of Example{i}. "
                f"It was built in {1700 + 3 * i} by local workers using stone from the nearby hills of the valley. "
                f"Visitors can reach the {t} by a short walk from the central station of Example{i}.")
        out.append({"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://example.org/{source}/{i}")), "source": source,
                    "url": f"https://example.org/{i}", "summary": text, "title": f"{t} {i}"})
    return out


def build(a):
    train = [{"claim": "placeholder", "kind": "rule"}] * 5
    made = longdoc.add_longdoc(train, a, 0.1, bd.compose_contra)
    return train, made


def test_one_long_passage_quotes_inside_it_and_train_atoms_only():
    a = atoms()
    _, made = build(a)
    assert made, "the synthetic atoms should give long-document examples"
    eval_ids = {x["id"] for x in a if bd.stable_split(x["id"], 0.1) == "eval"}
    for ex in made:
        assert ex["generator"] == longdoc.LONGDOC_VERSION
        assert len(ex["passages"]) == 1, "one document, as LLM-AggreFact gives"
        doc = ex["passages"][0]["text"]
        assert len(doc) <= longdoc.DOC_CHARS
        assert not set(ex["doc_atoms"]) & eval_ids and ex["atom_id"] not in eval_ids
        for e in ex["evidence"]:
            assert e["quote"] in doc
        if ex["label"] == "not_covered":
            assert ex["evidence"] == [] and ex["claim"] not in doc
        if ex["kind"] == "long_supported":
            assert doc.index(ex["claim"]) > 0, "the claim is never in the first paragraph"


def test_every_document_carries_a_contrastive_set():
    _, made = build(atoms())
    kinds = Counter(ex["kind"] for ex in made)
    assert kinds["long_supported"] and kinds["long_missing"] and kinds["long_summary_supported"] and kinds["long_summary_missing"]
    by_doc = {}
    for ex in made:
        by_doc.setdefault(ex["passages"][0]["text"], set()).add(ex["label"])
    assert all({"supported", "not_covered"} <= labels for labels in by_doc.values()), "no document has only one label"


def test_reproducible_and_inserted_into_train():
    a = atoms()
    t1, m1 = build(a)
    t2, m2 = build(a)
    assert m1 == m2 and t1 == t2
    assert len(t1) == 5 + len(m1)


def test_main_keeps_eval_files_identical_and_no_longdoc_reproduces_train(tmp_path):
    import json, subprocess
    a = atoms(400)
    snap = {"v": 1, "fields": ["id", "title", "text", "url", "source", "licence", "published_at"],
            "atoms": [[x["id"], x["title"], x["summary"], x["url"], x["source"], "CC BY-SA 4.0", "2026-10-01"] for x in a]}
    sp = tmp_path / "commons.json"
    sp.write_text(json.dumps(snap))
    script = os.path.join(HERE, "..", "build_dataset.py")
    outs = {}
    for name, extra in (("on", []), ("off", ["--no-longdoc"])):
        out = tmp_path / name
        subprocess.run([sys.executable, script, "--snapshot", str(sp), "--out", str(out), "--eval-share", "0.2"] + extra, check=True, capture_output=True)
        outs[name] = out
    for f in ("eval.jsonl", "eval2.jsonl", "eval3.jsonl"):
        assert (outs["on"] / f).read_bytes() == (outs["off"] / f).read_bytes()
    on = [json.loads(l) for l in (outs["on"] / "train.jsonl").read_text().splitlines()]
    off = [json.loads(l) for l in (outs["off"] / "train.jsonl").read_text().splitlines()]
    assert [x for x in on if x.get("generator") != longdoc.LONGDOC_VERSION] == off
    meta = json.loads((outs["on"] / "meta.json").read_text())
    assert meta["train_generators"][-1] == longdoc.LONGDOC_VERSION
    assert sum(meta["train_longdoc_by_kind"].values()) == len(on) - len(off) > 0

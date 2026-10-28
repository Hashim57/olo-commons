"""zeus/eval3.py: the versioned eval3 split. No network: a synthetic export shaped like the
snapshot. Checks the freeze (eval and eval2 unchanged, eval3 only over eval atoms, disjoint
from train), determinism, that every line is valid with exact evidence quotes, the pattern
counts and the version pin."""
import hashlib
import json
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud"))
import build_dataset as bd  # noqa: E402
import eval as ev  # noqa: E402
import eval3  # noqa: E402
import validate_gold  # noqa: E402

ZEUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHARE = 0.5

# sha256 of eval3.jsonl for the synthetic export below, per generator version. A change to what
# eval3.py writes must bump EVAL3_VERSION (eval3-v2, ...) and add its hash here, never edit an old one:
# a score on eval3-v1 must always mean the same lines.
PINNED_EVAL3 = {"eval3-v1": "61ca754e8d87d0efda6fd6e2a3306686834f4476161b189180b24968835334c5"}
# eval.jsonl and eval2.jsonl from the same export, computed with build_dataset.py as it was before
# eval3 existed (origin/main at the time), so adding eval3 provably moved neither.
PINNED_EVAL = "9d02b7ec7ade5ac69f42c9342ce9bc587b4de80c3796940d81d596761c8fc83d"
PINNED_EVAL2 = "4f69095d6c6872413621b97b5c779972b24e07c16ae6bb22d9b9058989101692"


def name(i):
    return "Var" + chr(97 + i % 26) + chr(97 + (i // 26) % 26) + "o"


def text(i):
    n, m, r = name(i), name(i + 1), name(i + 7)
    return (f"The town of {n} lies on the northern bank of the river {r} in the old province. "
            f"It was founded in 18{10 + i % 80} by settlers from the coast. "
            f"The harbour of {n} is larger than the harbour of {m}, and the market opened before the railway arrived. "
            f"Local fishermen may catch more salmon near {n} than anywhere else on the coast. "
            f"{n} became a city in 19{10 + i % 80} after a long campaign by its council.")


ATOMS = [{"id": hashlib.sha256(f"atom-{i}".encode()).hexdigest()[:8] + f"-0000-4000-8000-{i:012x}", "title": f"{name(i)} (town)",
          "summary": text(i), "content": "", "url": f"https://example.org/wiki/{name(i)}", "source": ("wikipedia", "arxiv")[i % 2]}
         for i in range(80)]


def snapshot():
    fields = ["id", "title", "text", "url", "source", "licence", "published_at"]
    return {"v": 1, "fields": fields, "atoms": [[a["id"], a["title"], a["summary"], a["url"], a["source"], "CC BY-SA 4.0", "2026-10-25"] for a in ATOMS]}


def eval_ids():
    return {a["id"] for a in ATOMS if bd.stable_split(a["id"], SHARE) == "eval"}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def test_eval3_uses_only_eval_atoms_and_eval_passages():
    lines = eval3.build_eval3(ATOMS, SHARE)
    assert lines, "eval3 is empty"
    ids = eval_ids()
    by_prefix = {a["id"][:8]: a["id"] for a in ATOMS}
    assert all(ex["atom_id"] in ids for ex in lines)
    # every passage, not only the claim's own, comes from an eval atom: no training text in eval3
    assert all(by_prefix[p["id"]] in ids for ex in lines for p in ex["passages"])


def test_eval3_is_disjoint_from_train():
    lines = eval3.build_eval3(ATOMS, SHARE)
    train = bd.build(ATOMS, SHARE)["train"]
    train_atoms = {ex["atom_id"] for ex in train}
    assert train_atoms and not train_atoms & {ex["atom_id"] for ex in lines}
    train_claims = {ex["claim"] for ex in train}
    assert not train_claims & {ex["claim"] for ex in lines}


def test_eval3_is_deterministic_and_ignores_input_order():
    first = eval3.dumps(eval3.build_eval3(ATOMS, SHARE))
    assert eval3.dumps(eval3.build_eval3(ATOMS, SHARE)) == first
    shuffled = list(ATOMS)
    random.Random(5).shuffle(shuffled)
    assert eval3.dumps(eval3.build_eval3(shuffled, SHARE)) == first
    assert eval3.dumps(eval3.build_eval3(list(reversed(ATOMS)), SHARE)) == first


def test_every_line_is_valid_and_quotes_are_exact():
    lines = eval3.build_eval3(ATOMS, SHARE)
    labels = {"near_miss_names": "not_covered", "modal_shift": "not_covered", "relation_flip": "contradicted",
              "before_after": "contradicted", "two_passage": "supported", "paraphrase_decade": "supported"}
    for ex in lines:
        assert validate_gold.check_example(ex) == [], (ex, validate_gold.check_example(ex))
        assert ex["version"] == eval3.EVAL3_VERSION and ex["kind"] in eval3.PATTERNS
        assert ex["label"] == labels[ex["kind"]]
        texts = {p["id"]: p["text"] for p in ex["passages"]}
        assert all(e["quote"] in texts[e["passage"]] for e in ex["evidence"])
        assert all(ex["claim"] not in t for t in texts.values()) or ex["kind"] == "two_passage"
        if ex["kind"] in ("relation_flip", "before_after"):
            assert ex["claim"] != ex["evidence"][0]["quote"]
            a, b = ex["claim"].split(), ex["evidence"][0]["quote"].split()
            assert len(a) == len(b) and sum(x != y for x, y in zip(a, b)) == 1
        if ex["kind"] == "two_passage":
            assert len({e["passage"] for e in ex["evidence"]}) == 2
            assert all(ex["claim"] not in t for t in texts.values())
        if ex["kind"] == "near_miss_names":
            joined = " ".join(texts.values())
            assert all(n in joined for n in eval3.claim_names(ex["claim"]))
    # no claim repeated under the same label
    assert len({(ex["claim"], ex["label"]) for ex in lines}) == len(lines)


def test_all_patterns_present_and_manifest_counts_match():
    lines = eval3.build_eval3(ATOMS, SHARE)
    m = eval3.manifest(lines, SHARE, "test")
    assert set(eval3.PATTERNS) == {ex["kind"] for ex in lines}, m["by_pattern"]
    assert all(m["by_pattern"][k] > 0 for k in eval3.PATTERNS)
    assert sum(m["by_pattern"].values()) == m["lines"] == len(lines) == sum(m["by_label"].values())
    assert m["version"] == eval3.EVAL3_VERSION and m["sha256"] == sha(eval3.dumps(lines).encode())
    assert "sha256(atom_id)" in m["split_rule"] and m["eval_share"] == SHARE


def test_version_pin_bump_eval3_version_when_the_generator_changes():
    got = sha(eval3.dumps(eval3.build_eval3(ATOMS, SHARE)).encode())
    assert eval3.EVAL3_VERSION in PINNED_EVAL3, f"new version {eval3.EVAL3_VERSION}: pin its hash {got} in PINNED_EVAL3"
    assert got == PINNED_EVAL3[eval3.EVAL3_VERSION], (
        f"eval3.py now writes different lines ({got}) under the same version {eval3.EVAL3_VERSION}: "
        "bump EVAL3_VERSION and pin the new hash, so old and new scores are never mixed")


def test_build_dataset_writes_eval3_and_leaves_eval_and_eval2_byte_identical(tmp_path):
    snap = tmp_path / "commons.json"
    snap.write_text(json.dumps(snapshot()))
    out = tmp_path / "data"
    subprocess.run([sys.executable, os.path.join(ZEUS, "build_dataset.py"), "--snapshot", str(snap), "--out", str(out), "--eval-share", str(SHARE)],
                   check=True, capture_output=True)
    files = {f: (out / f).read_bytes() for f in ("train.jsonl", "eval.jsonl", "eval2.jsonl", "eval3.jsonl")}
    # the two older splits are exactly what build() and build_eval2() alone write, and what they wrote before eval3
    atoms = bd.atoms_from_snapshot(snapshot())
    d = bd.build(atoms, SHARE)
    assert files["eval.jsonl"] == "".join(json.dumps(x, ensure_ascii=False) + "\n" for x in d["eval"]).encode()
    assert files["eval2.jsonl"] == "".join(json.dumps(x, ensure_ascii=False) + "\n" for x in bd.build_eval2(atoms, SHARE)).encode()
    assert sha(files["eval.jsonl"]) == PINNED_EVAL
    assert sha(files["eval2.jsonl"]) == PINNED_EVAL2
    # eval3 on disk is the module's output, its manifest matches it, and no eval3 atom is in train
    assert files["eval3.jsonl"] == eval3.dumps(eval3.build_eval3(atoms, SHARE)).encode()
    m = json.loads((out / "eval3.manifest.json").read_text())
    assert m["sha256"] == sha(files["eval3.jsonl"]) and m["from"] == "snapshot" and m["version"] == eval3.EVAL3_VERSION
    train_atoms = {json.loads(l)["atom_id"] for l in files["train.jsonl"].decode().splitlines()}
    assert not train_atoms & {json.loads(l)["atom_id"] for l in files["eval3.jsonl"].decode().splitlines()}
    meta = json.loads((out / "meta.json").read_text())
    assert meta["eval3"] == m["lines"] and meta["eval3_version"] == eval3.EVAL3_VERSION


def test_flip_word_only_touches_lowercase_words():
    rng = random.Random(1)
    assert eval3.flip_word("The river runs through North Carolina towards the East.", eval3.RELATION_MAP, rng) is None
    new, what = eval3.flip_word("The northern bank is higher than the southern one.", eval3.RELATION_MAP, random.Random(2))
    assert new != "The northern bank is higher than the southern one." and " -> " in what
    assert eval3.flip_word("The museum opened in 1902 and closed in 2015.", eval3.RELATION_MAP, rng) is None  # event verbs are not opposites
    new, _ = eval3.flip_word("The bridge was finished before the war began.", eval3.TEMPORAL_MAP, rng)
    assert new == "The bridge was finished after the war began."


def test_claim_sentences_refuse_fragments_pronouns_and_first_person():
    t = ("It was founded by settlers from the northern coast of the island. We propose a new method for the river data here. "
         "However, the town grew quickly during the long nineteenth century. 47 pages : 31 cm with many maps and plates inside. "
         "The town of Varo lies on the northern bank of the old river. The harbour of Varo was rebuilt by the council after the long")
    assert eval3.claim_sentences(t) == ["The town of Varo lies on the northern bank of the old river."]


def test_score_by_kind_and_split_report():
    exs = [{"claim": "c", "passages": [], "label": "supported", "evidence": [], "kind": "two_passage", "version": "eval3-v1"},
           {"claim": "c", "passages": [], "label": "not_covered", "evidence": [], "kind": "modal_shift", "version": "eval3-v1"},
           {"claim": "c", "passages": [], "label": "not_covered", "evidence": [], "kind": "modal_shift", "version": "eval3-v1"}]
    answers = ['{"label": "supported", "evidence": [], "rationale": "r"}', {"label": "supported"}, "not json"]
    assert ev.score_by_kind(exs, answers) == {"modal_shift": {"n": 2, "accuracy": 0.0}, "two_passage": {"n": 1, "accuracy": 1.0}}
    r = ev.split_report(exs, answers)
    assert r["version"] == "eval3-v1" and r["by_kind"]["two_passage"]["n"] == 1 and r["n"] == 3
    plain = [{k: v for k, v in e.items() if k not in ("kind", "version")} for e in exs]
    assert ev.split_report(plain, answers) == ev.score(plain, answers)  # the first split's report is unchanged
    assert ev.SPLITS == {"eval": "eval.jsonl", "eval2": "eval2.jsonl", "eval3": "eval3.jsonl"}


def test_scorecard_shows_eval3_as_not_yet_measured_until_a_run_scores_it():
    import scorecard
    assert "not yet measured" in scorecard.eval3_row({})
    assert "%" not in scorecard.eval3_row({})
    row = scorecard.eval3_row({"n": 10, "version": "eval3-v1", "label_accuracy": 0.5, "evidence_hit": 0.4, "json_valid": 1.0, "binary_balanced_accuracy": 0.6})
    assert "eval3-v1" in row and "50.0%" in row
    assert "not measured (boom)" in scorecard.eval3_row({"error": "boom"})

# Zeus data card

What Zeus trains on, where each part comes from, under which licence, and what it is for. Counts change every run; `zeus/data/meta.json` (gitignored, printed by every build) has the current ones, and `STATUS.md` records what each measured version trained on.

## Task

Claim verification: given one claim and two to four passages with provenance, answer `supported`, `contradicted` or `not_covered`, quote the evidence span and give a one-sentence rationale, as one JSON object (format in `README.md`). Three parts feed it, all through `train_mlx.py` and `train_lora.py`; nothing but the Commons eval split is ever scored.

## 1. Commons examples (rule-made)

Built by `build_dataset.py` from the live Olo Commons through the public `olo_export` RPC. Each atom carries its source licence (Wikipedia CC BY-SA 4.0, Wikidata CC0, arXiv abstracts under the arXiv licence, PubMed abstracts as published with public-domain citation data, Project Gutenberg public domain, Internet Archive as stated per item, Data.gov open licences only). Supported examples take a sentence of an atom as the claim; contradicted examples change one relation word, year, number or name by rule; not_covered examples use passages far from the claim, plus near misses in the train split (passages that share words with the claim but do not state it). The eval split is frozen by a stable hash of the atom id and never receives near misses, gold or imported lines, so versions stay comparable; the harder patterns go into separate frozen splits with their own generators (eval2 and eval3, below), never into it.

Known limits: rule-made contradictions change one token, so the model can learn to spot an odd value rather than read; multi-passage support does not occur in training (eval3 measures it, below); the Commons is English-heavy with a growing Spanish share.

## 2. Gold examples (hand-written)

`data/gold/*.jsonl`, validated by `validate_gold.py` on every build and in CI. Written against real atoms with their ids and urls kept, aimed at what rules cannot make: contradictions that change a relation rather than a number, near-miss claims that sit next to a passage without being stated by it, support that needs two passages, paraphrases with no shared wording. Passage texts are the atoms' own text (or excerpts of it, marked with " ... " when cut). Licence: each passage's source licence; the claims and rationales are released with the repository under Apache 2.0.

## 3. Imported open corpora

`import_corpora.py` converts open fact-checking corpora into the task format and writes them to `data/imported/` (gitignored; rebuilt on the Mac before each training run, `IMPORT_N` lines, default 1,500, balanced across the three labels). Only corpora whose licence allows redistribution and use in a model that serves a product are imported.

| Corpus | Used | Licence | Why |
|---|---|---|---|
| VitaminC (Schuster, Fisch and Barzilay, NAACL 2021) | yes | CC BY-SA 3.0 (Wikipedia-derived; LICENSE in the release zip) | 370k human-written claim and evidence pairs over Wikipedia revisions, labels SUPPORTS / REFUTES / NOT ENOUGH INFO, many contrastive pairs where one word of evidence flips the label: exactly the contradictions a rule cannot write. Evidence is inline, so provenance is a page and revision id. |
| SciFact (Wadden et al., 2020) | no | CC BY-NC 2.0 | Non-commercial, and Zeus serves helius-olo.io. Revisit if the licence changes. |
| Climate-FEVER (Diggelmann et al., 2020) | no | not stated with the data | The authors ask for a citation only; without a stated licence it stays out. |
| FEVER (Thorne et al., 2018) | no (indirectly) | CC BY-SA 3.0 | Evidence is given as page and sentence ids that need the Wikipedia dump; VitaminC already carries FEVER-derived pairs with the sentences inline. |

Each imported line keeps `corpus`, `unique_id`, `case_id`, the Wikipedia page title and revision id in the passage url, `licence` and an `attribution` string. Two distractor passages from other rows are added so the shape matches the Commons examples. A held-out imported set (`--split dev`, written as `*-eval.jsonl`) can be scored with `eval.py --eval-file`; it never trains and is not the frozen Commons eval.

## Attribution

Text from Wikipedia and VitaminC is under CC BY-SA 3.0 or 4.0: attribute Wikipedia and, for VitaminC, Schuster, Fisch and Barzilay (2021). Atoms from other sources carry their own licence field. The compilation of Commons examples is offered under CC BY-SA 4.0, as the Commons itself is.

## Not in the data

No personal data, no query text from the read API, no text the Commons was not allowed to redistribute. Gaps recorded by `olo-answer` are bags of topic words, never questions, and are not training data.


## eval2.jsonl: the harder frozen split (added 25 Oct 2026)

Built over the same eval atoms as `eval.jsonl` and nothing else, with its own generator, so it never overlaps training and leaves the first split byte-identical. Three patterns per atom where the rules allow: a near-miss not covered (passages on the topic that do not state the claim), a relation-flip contradiction with the passages shuffled (both terms of the comparison present, one word changed), and a supported claim whose true passage comes last of four. The first split saturated at v6 (0.995); this one is the Commons-based number to watch, reported per pattern in docs/ZEUS_SCORECARD.md beside the held-out VitaminC dev set.


## eval3.jsonl: the versioned gold-style frozen split (added 26 Oct 2026, eval3-v1)

Built by its own module, `eval3.py` (called from `build_dataset.py`), over the same eval atoms as `eval.jsonl` and `eval2.jsonl` and nothing else: the claim's atom is an eval atom, and so is every passage beside it (distractors and near misses are drawn from eval atoms only), so no training atom's text appears in it, and the two older splits stay byte-identical. Six patterns, each line tagged with its `kind` so it is reported per pattern, made by rule in the style of the hand-made gold patterns (never copied from them: gold trains, this split only measures):

- `near_miss_names` (not covered): the claim's own atom with the claim sentence cut out, plus near-miss atoms; every name in the claim appears in the passages, but none states it. The rest of the atom is refused when it holds more than half of the claim's content words.
- `relation_flip` (contradicted): one strict opposite swapped (higher/lower, larger/smaller, north/south, first/last, inside/outside, always/never and the like), lowercase words only so names such as North Carolina are never touched, both terms of the comparison still in the passage, passages shuffled. Event verbs (born/died, opened/closed) and negations are left out: "died in Warsaw" is not contradicted by "born in Warsaw".
- `before_after` (contradicted): before/after, earlier/later or earliest/latest swapped.
- `modal_shift` (not covered): "may", "might" or "can" in the passage becomes "will" in the claim; the passage says it is possible, not that it happens.
- `two_passage` (supported): the lead sentences of two atoms from the same source joined into one claim, so neither passage alone supports it; made for one eval atom in four (chosen by a hash of the id) so it does not swamp the rest.
- `paraphrase_decade` (supported): "in 1863" restated as "in the 1860s", which the year entails.

Claims are made only from complete sentences of six words or more that are an exact substring of the passage, do not open with a pronoun or linking word ("It", "However", "Here") and are not in the first person, so every evidence quote is exact and every claim stands on its own. Every line passes `validate_gold.check_example`.

Frozen and versioned: the split rule is the same stable hash of the atom id; each atom's choices are seeded by the version, the pattern and the atom id (never the run time or input order), and lines are ordered by a hash, so the same export always gives the same bytes. Each line carries `"version": "eval3-v1"`, and `eval3.manifest.json` beside it records the version, the generator, the split rule, the eval share, counts per pattern and per label, and the sha256 of the file. The content hash moves when the Commons grows (new eval atoms); the version moves only when the rules do: any change to what `eval3.py` writes for the same atoms becomes eval3-v2, enforced by a pinned hash in `tests/test_eval3.py`. Built from the offline snapshot of 26 Oct 2026 (1,851 atoms, summaries of at most 600 characters) it has 58 lines over 46 atoms (near_miss_names 18, relation_flip 6, before_after 4, modal_shift 4, two_passage 22, paraphrase_decade 4); a live build, with longer passages, makes more.

Known limits: rule-made, so the same caveats as the other splits apply in a milder form; a near miss is checked by word overlap, not by a reader, so a rare line may in fact be stated in other words; the joined two-passage claims pair unrelated facts. Not yet scored: no version has been measured on it, and the scorecard shows it as not yet measured until a training run scores it (`eval_v3` in `eval-external.json`, beside eval and eval2, which are scored as before).

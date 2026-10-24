# Zeus data card

What Zeus trains on, where each part comes from, under which licence, and what it is for. Counts change every run; `zeus/data/meta.json` (gitignored, printed by every build) has the current ones, and `STATUS.md` records what each measured version trained on.

## Task

Claim verification: given one claim and two to four passages with provenance, answer `supported`, `contradicted` or `not_covered`, quote the evidence span and give a one-sentence rationale, as one JSON object (format in `README.md`). Three parts feed it, all through `train_mlx.py` and `train_lora.py`; nothing but the Commons eval split is ever scored.

## 1. Commons examples (rule-made)

Built by `build_dataset.py` from the live Olo Commons through the public `olo_export` RPC. Each atom carries its source licence (Wikipedia CC BY-SA 4.0, Wikidata CC0, arXiv abstracts under the arXiv licence, PubMed abstracts as published with public-domain citation data, Project Gutenberg public domain, Internet Archive as stated per item, Data.gov open licences only). Supported examples take a sentence of an atom as the claim; contradicted examples change one relation word, year, number or name by rule; not_covered examples use passages far from the claim, plus near misses in the train split (passages that share words with the claim but do not state it). The eval split is frozen by a stable hash of the atom id and never receives near misses, gold or imported lines, so versions stay comparable.

Known limits: rule-made contradictions change one token, so the model can learn to spot an odd value rather than read; multi-passage support does not occur; the Commons is English-heavy with a growing Spanish share.

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

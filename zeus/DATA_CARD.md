# Zeus data card

What Zeus trains on, where each part comes from, under which licence, and what it is for. Counts change every run; `zeus/data/meta.json` (gitignored, printed by every build) has the current ones, and `STATUS.md` records what each measured version trained on.

## Task

Claim verification: given one claim and two to four passages with provenance, answer `supported`, `contradicted` or `not_covered`, quote the evidence span and give a one-sentence rationale, as one JSON object (format in `README.md`). Three parts feed it, all through `train_mlx.py` and `train_lora.py`; nothing but the Commons eval split is ever scored.

## 1. Commons examples (rule-made)

Built by `build_dataset.py` from the live Olo Commons through the public `olo_export` RPC. Each atom carries its source licence (Wikipedia CC BY-SA 4.0, Wikidata CC0, arXiv abstracts under the arXiv licence, PubMed abstracts as published with public-domain citation data, Project Gutenberg public domain, Internet Archive as stated per item, Data.gov open licences only). Supported examples take a sentence of an atom as the claim; contradicted examples change one relation word, year, number or name by rule; not_covered examples use passages far from the claim, plus near misses in the train split (passages that share words with the claim but do not state it). The eval split is frozen by a stable hash of the atom id and never receives near misses, gold or imported lines, so versions stay comparable.

Known limits: rule-made contradictions change one token, so the model can learn to spot an odd value rather than read; multi-passage support does not occur; the Commons is English-heavy with a growing Spanish share.

### 1b. Harder train negatives (generator `hard-v1`, added 26 Oct 2026)

Contradicted and not covered were the labels Zeus found hardest on the held-out VitaminC set, and VitaminC is built from minimal, contrastive edits: one fact changed, or a claim that sits right next to its evidence without being stated by it. `add_hard_negatives()` in `build_dataset.py` adds that kind of example to the **train split only**. For each train atom it picks one English sentence and emits a contrastive set over the very same passages (the atom itself plus two distractors from other train atoms, in a shuffled order): the sentence as `supported`, and up to one `contradicted` and one `not_covered` twin. The model sees the same passages three times and only the edit differs, so it has to read the edit, not the topic. Every hard example keeps the true passage among its passages, which the older not_covered examples never do.

Contradicted twins (one fact changed; the evidence quotes the original sentence, an exact substring of the passage):

- `hard_antonym_flip`: one lower-case word swapped for an antonym the first FLIPS list does not have (rose/fell, allow/forbid, earlier/later, win/lose, activates/inhibits, improves/worsens, public/private, majority/minority, less to more).
- `hard_order_swap`: two values or names that both stay in the sentence trade places ("rose from 10 to 20" to "rose from 20 to 10", "12 and 19 days, respectively" swapped, "A is longer than B" to "B is longer than A").
- `hard_negation`: one negation inserted or removed grammatically ("has been" to "has not been", "will open" to "will not open", "did not approve" to "did approve", "wasn't" to "was").
- `hard_value_shift`: a year moved by one to three (never past 2026), a month moved to a nearby month, or a number moved by a fifth to a half of itself with the same number of digits (percentages stay at most 100), so the value stays plausible.
- `hard_entity_swap`: a year or a name replaced by another of the same kind that the same passage mentions elsewhere ("studied in Paris" to "studied in Krakow" when the passage names Krakow). Names must sit in the same slot (the same preposition before both).
- `hard_quantifier`: "All X" to "No X", "all of" to "none of", "none of" to "all of", "most of" to "few of".

Not covered twins (the claim keeps the sentence's people, places and things but says something no passage states; evidence is empty):

- `hard_modal_shift`: a hedge, plan or correlation stated as certain, done or causal ("may reduce" to "will reduce", "is associated with" to "causes", "was proposed" to "was adopted", "suggests that" to "proves that").
- `hard_scope_shift`: the finding carried to a group or place never mentioned ("in mice" to "in humans", "in adults" to "in children", "in Europe" to "worldwide", "in France" to "in France and Japan").
- `hard_relation_shift`: the same entities in a relation the passage neither states nor rules out ("film directed by" to "film produced by", "studied at" to "taught at", "was nominated for" to "won", "member of the band" to "founder of the band").
- `hard_added_clause`: the true sentence plus a qualifier no passage supports, only on sentences that report an event (Wikipedia and other sources) or a finding (arXiv, PubMed), so it reads as a plausible extra detail ("..., according to a later independent review", "... despite strong public opposition", "..., a result later replicated in a second independent cohort").

Guards against label noise, each covered by a test in `zeus/tests/test_hard_negatives.py`:

- An edit is never made inside a quotation, never right after a negation or a hedge (not, never, may, might, can, could, or), and never in a sentence that asks or supposes rather than asserts (whether, if, hypothesis). Negation is inserted only into a sentence with no negation and removed only from a sentence with exactly one, so there are no double negatives.
- A contradiction is dropped when the new claim, or the edited span with two words of context on each side, is written in any passage of the example (the passage might state both). An antonym flip is dropped when the antonym is already in the sentence, and a word that is part of a name ("Ulmus minor", "Upper Silesia") is never flipped. A shifted value is dropped when the new value appears in any passage. Identifiers ("Apollo 11"), variables ("t = 2"), days of the month, year ranges, decades and confidence levels are never shifted.
- A not covered twin is dropped when any content word it adds (or that word's stem, so "humans" also catches "human") occurs in any passage of the example, or when the new claim is in a passage. Scope and modal shifts are refused in negated sentences and after "only"; relation shifts need their context word ("film", "album", "band", "patients") so "produced by" never becomes "directed by" for a car.
- Not English sentences (the Spanish Wikipedia atoms) are skipped.

These are still rules. They catch the common failure cases, not all of them: a name swap matched only by its slot can put a person where a place was, an added clause can read oddly on an unusual sentence, and a not covered twin can occasionally be false by world knowledge (which does not change its label, since Zeus judges against the passages). Hand-written gold lines and VitaminC remain the human-grade part of the data.

Determinism and versioning: each atom draws from its own generator seeded by its id, and the hard examples are inserted into the train order by their own generator, after the near misses. Nothing draws from `build()`'s generators, so `eval.jsonl` and `eval2.jsonl` are byte-identical with or without them, and `--no-hard-negatives` reproduces the earlier train split byte for byte. Every hard example carries `"generator": "hard-v1"`, a `kind`, the `edit` it made and a `pair` id shared by its contrastive set; `meta.json` records `train_generators` (`["rules-v1", "hard-v1"]`) and `train_hard_by_kind`. A rule change bumps the version.

Example counts from an offline build of the 26 Oct 2026 snapshot (1,851 atoms; counts of examples, not scores): 1,725 hard examples in 781 contrastive sets, that is 781 supported twins, 694 contradicted (291 value shift, 255 antonym flip, 92 negation, 51 entity swap, 5 quantifier, 0 order swap, a pattern the snapshot's short summaries rarely contain) and 250 not covered (153 added clause, 47 modal shift, 29 scope shift, 21 relation shift). The rule-made train split grows from 5,766 to 7,491 examples: supported 1,496 to 2,277, contradicted 1,314 to 2,008, not covered 2,956 to 3,206, so the hard sets also pull the labels closer to balance (not covered had been the largest by far, because of the near misses).

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

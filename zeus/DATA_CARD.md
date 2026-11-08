# Zeus data card

What Zeus trains on, where each part comes from, under which licence, and what it is for. Counts change every run; `zeus/data/meta.json` (gitignored, printed by every build) has the current ones, and `STATUS.md` records what each measured version trained on.

## Task

Claim verification: given one claim and two to four passages with provenance, answer `supported`, `contradicted` or `not_covered`, quote the evidence span and give a one-sentence rationale, as one JSON object (format in `README.md`). Three parts feed it, all through `train_mlx.py` and `train_lora.py`; nothing but the Commons eval split is ever scored.

## 1. Commons examples (rule-made)

Built by `build_dataset.py` from the live Olo Commons through the public `olo_export` RPC. Each atom carries its source licence (Wikipedia CC BY-SA 4.0, Wikidata CC0, arXiv abstracts under the arXiv licence, PubMed abstracts as published with public-domain citation data, Project Gutenberg public domain, Internet Archive as stated per item, Data.gov open licences only). Supported examples take a sentence of an atom as the claim; contradicted examples change one relation word, year, number or name by rule; not_covered examples use passages far from the claim, plus near misses in the train split (passages that share words with the claim but do not state it). The eval split is frozen by a stable hash of the atom id and never receives near misses, gold or imported lines, so versions stay comparable; the harder patterns go into separate frozen splits with their own generators (eval2 and eval3, below), never into it.

Known limits: rule-made contradictions change one token, so the model can learn to spot an odd value rather than read; multi-passage support does not occur in training (eval3 measures it, below); the Commons is English-heavy with a growing Spanish share.

Atoms the build leaves out (since 3 Nov 2026, `zeus/quality.py`, counted in `meta.json` as `atoms_dropped`): an id the export listed twice (the keyless export repeated the last atom of every page until olo-query kept the cursor's microseconds), a stub (a label, one line repeated, or nothing beyond the title and authors: the rule is the ingester's `isStub`, and a third of the archive_org atoms stored before the ingester had it were stubs such as "new book new book"), and a Wikidata item that describes a Wikimedia page rather than a thing in the world (a category, a template, a disambiguation page). They are dropped before any split, so a stub is neither a claim nor a passage in any split. On the 3 Nov 2026 snapshot that was 10 duplicates, 330 stubs and 35 housekeeping items out of 5,000 atoms; 104 of them had been claims or passages before. Since 8 Nov 2026 `atoms_dropped.stub_by_rule` names the rule that refused each stub (`label`, `repeat`, `link_notice`, `catalogue_record`, `shelf_mark`, `no_rest`; the ingester's rules in the ingester's order), so a build can say which rule is doing the work: on the 8 Nov 2026 snapshot, 7,000 atoms in, 835 stubs were 360 catalogue records, 319 labels, 72 shelf marks, 55 link notices, 28 with nothing beyond title, authors and physical description, and 1 repeat.

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

### 1c. Composed train examples (generator `compose-v1`, added 5 Nov 2026)

Why: v16 scored 0.0 on eval3's two_passage pattern (59 supported claims whose halves come from two passages) and 0.18 on paraphrase_decade. Every rule-made and hard-v1 supported example was one sentence quoted from one passage, so the model had learned that a supported claim has exactly one quote. `zeus/compose.py` adds, over train atoms only with train distractors only:

- `compose_supported` (supported): a sentence from atom A and one from atom B of the same source in one claim, A and B both among the passages; the evidence quotes both.
- `compose_missing_half` (not_covered): the same claim with B left out of the passages.
- `compose_false_half` (contradicted): the same claim with B's half edited by a hard-v1 contradiction rule; the evidence quotes B.
- `century_supported` (supported) and `century_wrong` (contradicted): "in 1863" restated as "in the 19th century", and as the century before or after (never a century that has not begun; years ending in 00 are skipped).

One train atom in five starts a composed set, one in two may give a century pair. The joints are "; ", ", while ", " Also, " and " In addition, " (English joints only between English sentences), never eval3's ", and", and years become centuries, never decades, so a gain on eval3 after this change measures transfer of the skill rather than a copied template. On the 2026-11-05 snapshot it adds 1,988 examples (773 supported, 773 missing half, 216 false half, 113 and 113 century). `eval.jsonl`, `eval2.jsonl` and `eval3.jsonl` are byte-identical with or without it, and `--no-compose` reproduces the train split without it; `meta.json` records `compose-v1` in `train_generators` and the counts in `train_composed_by_kind`.

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

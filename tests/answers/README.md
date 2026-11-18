# Frozen question sets for Olo's answers

`questions-v1.jsonl` holds 70 questions written by hand on 18 November 2026 over atoms that were in the Commons that morning (the snapshot of 07:22 UTC), so that Olo's answers can be measured the way Zeus is: the same questions every time, scored the same way, with the numbers recorded, not asserted (issue #76, part 1).

One JSON object per line:

```json
{ "id": "q012", "question": "When was AaB Fodbold founded, and what sport did the club start with?",
  "atoms": ["c1c0ff7d-9692-4cd0-a3a4-a0dcef2d0f3c"],
  "answer": "AaB was founded on 13 May 1885 as a cricket club by English railway engineers and adopted football in 1902.",
  "facts": ["1885", "cricket"], "lang": "en",
  "provenance": [{ "id": "c1c0ff7d-...", "source": "wikipedia", "title": "AaB Fodbold", "url": "https://en.wikipedia.org/wiki/AaB_Fodbold", "licence": "CC BY-SA 4.0" }] }
```

- `atoms`: the Commons atoms a good answer must retrieve and cite. Two questions need two atoms (q038, q043), the rest one.
- `answer`: a short reference answer written from the atom's text, for a reader; the scorer does not compare against it.
- `facts`: what the shown answer must mention. `"14 million|fourteen million"` lists acceptable spellings; digits are compared without thousands separators and on word boundaries.
- `lang`: `es` for the ten questions over Spanish Wikipedia, asked in Spanish.
- `provenance`: source, title, URL and licence of every expected atom, so the set is checkable and attributable on its own.

Where the questions come from: 26 over English Wikipedia (CC BY-SA 4.0), 10 over Spanish Wikipedia (CC BY-SA 4.0), 14 over Wikinews (CC BY 2.5), 7 over PubMed abstracts, 6 over arXiv abstracts, 4 over data.gov dataset descriptions, 2 over Wikidata descriptions (CC0) and 1 over an OpenAlex abstract. Nothing from Project Gutenberg (its summaries are machine-written, issue #55) and nothing from the Internet Archive (the stubs and records issue #50 is about). Every question is answerable from its atom's text alone; every fact is a word or figure in that text.

Rules: a line is never edited or removed once a measurement has been recorded against the set. Corrections and new questions go in `questions-v2.jsonl`, and the report names the set it was run on. Keep em dashes and en dashes out of every line.

Scoring: `python3 scripts/answer_eval.py` (read-only, calls the public olo-answer endpoint, two seconds between calls, stops on a 429). `--save` keeps the raw responses so a run can be scored again with `--replay` after the scorer changes, without asking the model again. Measures, each a fraction per question and a mean over the set: retrieval (expected atoms among the retrieved passages), citation (expected atoms cited by a shown sentence), verification (sentences the verifier marked supported), facts (expected facts in the shown answer), and the count of abstentions and failed calls. The first measured run goes in `docs/ZEUS_SCORECARD.md`'s neighbour for Olo once it exists, and in the Friday report (issue #76).

# Olo answers: measured results

How well olo-answer answers the frozen question set `tests/answers/questions-v1.jsonl` (70 hand-written questions over Commons atoms), scored by `scripts/answer_eval.py`. Every row here comes from a real run; the method is in `tests/answers/README.md`. Issue #76 is the plan this belongs to.

| Run (UTC) | Questions | Answered by | Retrieval | Citation | Verification | Facts | Abstained |
|---|---|---|---|---|---|---|---|
| 2026-11-18 11:10 | 70 of 70 | extractive (no writer reachable) | 1.000 | 0.936 | 1.000 (by construction) | 0.607 | 0 |
| 2026-11-18 11:54 | 50 of 70 (stopped by the hourly limit) | written, checked by Zeus v22 | 1.000 | 0.780 | 0.670 | 0.673 | 8 |

By source, facts found in the shown answer:

| Source | Extractive (n) | Written + Zeus (n) |
|---|---|---|
| Wikipedia | 0.615 (26) | 0.846 (26) |
| Wikinews | 0.536 (14) | 0.500 (14) |
| Wikipedia en español | 0.667 (10) | 0.467 (10) |
| PubMed | 0.548 (7) | not yet run |
| arXiv | 0.750 (6) | not yet run |
| data.gov | 0.500 (4) | not yet run |
| Wikidata | 1.000 (2) | not yet run |
| OpenAlex | 0.000 (1) | not yet run |

## What the two runs showed

The first run was extractive because both writers were down: the main provider's key in the `OLO_LLM_API_KEY` secret was not a live Groq key (401), and the Cloudflare fallback named a model that does not exist (`@google/gemini-4-argon`; the catalogue id has no `@`), then had no unified billing credits for it. Hashim set a fresh key; the second run is the first of written, Zeus-checked answers.

In the second run Zeus and the figure check hid 37 sentences. Read one by one, about 6 deserved it: a writer's over-claim my question invited (q037, "all 20 seats were contested"), the writer's own subtraction (q049), and two claims the passage does not quite make (q035, q040). The other 31 came from the checking:

| Cause | Sentences | Fixed by |
|---|---|---|
| The sentence splitter cut after "St.", "George A.", "William F." | 4 | splitSentences keeps initials and abbreviations (18 Nov) |
| A pronoun with no subject, checked alone ("She established it in 1924") | 4 | the writer names each sentence's subject (18 Nov) |
| A year only the story's date states (Wikinews "On April 30th") | 3 | news and paper passages start with "Published <date>." (18 Nov) |
| Citations written as 【p1】; a supported quote that differed in punctuation | 2 | both read (18 Nov) |
| Zeus wrong on Spanish, a language it has never been trained on | 8 | non-English sentences go to the fallback verifier (18 Nov); first Spanish gold |
| Zeus wrong on English sentences its passage states | 10 | gold-2026-11-18-answers.jsonl teaches the same patterns over other atoms |

The next run after these fixes are deployed measures how much of the gap between written and extractive was the checking. The remaining 20 questions (PubMed, arXiv, data.gov, Wikidata, OpenAlex) have not been asked of the written path yet.

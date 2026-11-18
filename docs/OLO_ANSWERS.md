# Olo answers: measured results

How well olo-answer answers the frozen question set `tests/answers/questions-v1.jsonl` (70 hand-written questions over Commons atoms), scored by `scripts/answer_eval.py`. Every row here comes from a real run; the method is in `tests/answers/README.md`. Issue #76 is the plan this belongs to.

| Run (UTC) | Questions | Answered by | Retrieval | Citation | Verification | Facts | Abstained |
|---|---|---|---|---|---|---|---|
| 2026-11-18 11:10 | 70 of 70 | extractive (no writer reachable) | 1.000 | 0.936 | 1.000 (by construction) | 0.607 | 0 |
| 2026-11-18 11:54 | 50 of 70 (stopped by the hourly limit) | written, checked by Zeus v22 | 1.000 | 0.780 | 0.670 | 0.673 | 8 |
| 2026-11-18 12:21 and 13:42 | 70 of 70 (two halves of 35) | written, checked by Zeus v22 (fallback verifier for Spanish); after PR #87 | 1.000 | 0.921 | 0.795 | 0.781 | 5 |

Like for like, the first 50 questions before and after PR #87: facts shown 0.673 to 0.833, sentences supported 0.670 to 0.837, abstentions 8 to 1. In the fixed run the writer was the main provider for 64 answers and the Cloudflare fallback for 6 (the main provider's per-minute limit); Zeus checked most of the sentences in 59 answers and the fallback verifier in 11 (the 10 Spanish answers, as designed, and one other).

By source, facts found in the shown answer:

| Source | Extractive (n) | Written + Zeus, before PR #87 (n) | Written + Zeus, after PR #87 (n) |
|---|---|---|---|
| Wikipedia | 0.615 (26) | 0.846 (26) | 0.865 (26) |
| Wikinews | 0.536 (14) | 0.500 (14) | 0.714 (14) |
| Wikipedia en español | 0.667 (10) | 0.467 (10) | 0.916 (10) |
| PubMed | 0.548 (7) | not run | 0.714 (7) |
| arXiv | 0.750 (6) | not run | 0.583 (6) |
| data.gov | 0.500 (4) | not run | 0.625 (4) |
| Wikidata | 1.000 (2) | not run | 1.000 (2) |
| OpenAlex | 0.000 (1) | not run | 0.000 (1) |

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

## After the fixes (PR #87, deployed 18 November)

Spanish gained most (facts 0.467 to 0.916) once its sentences went to the fallback verifier instead of a Zeus that has never read Spanish; Wikinews gained from the publication dates (facts 0.500 to 0.714, citation 0.643 to 0.893); the split names ("St. Mark's", "George A. Romero") now score in full. The weakest sources are now research abstracts, which this run reached for the first time on the written path: arXiv 0.583 facts (below the extractive 0.750) and PubMed 0.714, with four of the five abstentions on paper questions. Why is not yet read from the saved responses; Zeus has not yet trained on gold-2026-11-18-answers.jsonl either, so the English Zeus mistakes of the first written run are still in this one.

## Second round (18 November, after the 13:42 run)

The 22 sentences hidden in questions q036 to q070 (papers, datasets, Wikinews) pointed at three more checking problems and one Zeus weakness, fixed in the pull request after PR #88:

| Cause | Example | Fixed by |
|---|---|---|
| The writer saw each passage's title and Zeus did not | TUTTI's "under 3 ms on CPU" is in its title only (q063) | every passage now leads with its title, for the writer, Zeus and the figure check |
| The "name the subject" rule made the writer use paper titles as names | "When will androids outnumber humans paper states that..." read as a name swap (q061) | the writer names a study with a plain noun phrase ("The meta-analysis of ...") |
| A multiplication sign against a letter x | "10×" called a different value from the abstract's "10x" (q059) | the checks read a number's × as x; the shown text is unchanged |
| "U.S." split in two | "the U.S. Census Bureau" (q064) | the splitter keeps dotted abbreviations together |
| Zeus wrong on numbers its abstract states | "Eight RCTs comprising 636 participants" (q053), "320 sites" (q067), "biennially since 1983" (q064) | gold-2026-11-18-papers.jsonl, 16 lines over other abstracts and datasets |

Fair to hide in that half: q037 (the question's wording invited "20 seats contested"; it will be reworded in questions-v2, v1 stays frozen), q049 (the writer's own subtraction), q069 ("in the region" for North India and Pakistan), q042 (borderline: a year read from the story's date by inference).

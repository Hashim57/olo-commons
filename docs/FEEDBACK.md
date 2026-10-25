# How Olo and Zeus learn from being used

Every Olo app (helius-olo.io, iPhone, Mac, the Commons page) lets a person flag one sentence of an answer: "Zeus said supported, but the source does not say this", "this is contradicted", "wrong source", or "unclear", with an optional note and the exact words that decide it. That flag is the unit of learning. Nothing else from a conversation is used to train Zeus.

## The loop

1. **Flag.** The app posts the sentence, the verdict Zeus gave, the person's verdict, the passages the sentence was checked against (atom ids or urls, with quotes), and a note, to `POST /functions/v1/olo-feedback`. Never the question, never who asked. Sixty flags an hour per address; a flag that agrees with the verdict and adds nothing is counted but not stored; the same flag from the same address within a day counts once.
2. **Review.** A person opens the `olo_feedback` table (Supabase dashboard, status `new`) and sets each row to `accepted` or `rejected`. For a `supported` or `contradicted` acceptance the row needs the exact evidence words in `evidence_quote` if the flag did not carry them; `reviewer_note` replaces the rationale when it needs sharpening. Duplicates become `duplicate`.
3. **Gold.** The daily training run (`.github/workflows/zeus-train.yml`, 03:23 UTC) runs `zeus/feedback_to_gold.py`: accepted rows that no version has trained on become lines in `zeus/data/gold/feedback-<date>.jsonl`, rebuilt with the passages' real text from the Commons and validated exactly like hand-written gold (every quote an exact substring, two passages at least). Rows are marked `used_in = <version>`. Flags with `wrong_source` or `unclear` are kept for analysis and make no example.
4. **Train.** New gold lines make training due (`zeus/cloud/due.py`), so a reviewed flag reaches Zeus the next morning. Training also runs when the set has grown a tenth or a week has passed.
5. **Measure and publish.** The new version is measured on the frozen split, on held-out VitaminC and on an LLM-AggreFact sample, written to `docs/ZEUS_SCORECARD.md`, promoted only if not worse, and published to the Worker. The public counts (`GET /functions/v1/olo-feedback?stats=1`: total, new, accepted, taught, disagreement rate) go on the Commons page.

## Rules

- Zeus never trains on its own labels. A flag is a person's judgement, and a reviewer confirms it before it becomes a label. Model output is never re-ingested as a fact either (docs/TRUST.md).
- The frozen eval split and the held-out sets never receive feedback lines, so scores stay comparable.
- The Commons improves from use too: a question Olo could not answer records its topic words as a curiosity gap (capped per address), and the ingester reads sources on it; a flag of `wrong_source` on a passage is a signal to re-check that atom at its source.
- What is stored is small and bounded: a sentence of at most 600 characters, verdicts from a fixed list, passage ids, a quote and a note of at most 500 characters, and a daily-salted address hash for the rate limit. Rows are readable only by the service role.

## For app builders

```
POST https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-feedback
Content-Type: application/json
{ "client": "web" | "ios" | "macos" | "commons" | "api",
  "answer_source": "olo" | "commons" | "offline",
  "claim": "<the sentence as shown>",
  "verdict_given": "supported" | "contradicted" | "not_covered",
  "verdict_user": "supported" | "contradicted" | "not_covered" | "wrong_source" | "unclear",
  "passages": [{ "atom": "<uuid>", "url": "https://...", "quote": "<words from the source>" }],
  "evidence_quote": "<optional exact words that decide it>",
  "note": "<optional, 500 characters>" }
-> { "ok": true, "id": "<uuid>", "stored": true }
```

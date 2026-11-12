# How Olo and Zeus learn from being used

Every Olo app (helius-olo.io, iPhone, Mac, the Commons page) lets a person flag one sentence of an answer: "Zeus said supported, but the source does not say this", "this is contradicted", "wrong source", or "unclear", with an optional note and the exact words that decide it. That flag is the unit of learning. Nothing else from a conversation is used to train Zeus.

## The loop

1. **Flag.** The app posts the sentence, the verdict Zeus gave, the person's verdict, the passages the sentence was checked against (atom ids or urls, with quotes), and a note, to `POST /functions/v1/olo-feedback`. Never the question, never who asked. Sixty flags an hour per address; a flag that agrees with the verdict and adds nothing is counted but not stored; the same flag from the same address within a day counts once.
2. **Review.** A person opens the `olo_feedback` table (Supabase dashboard, status `new`) and sets each row to `accepted` or `rejected`. For a `supported` or `contradicted` acceptance the row needs the exact evidence words in `evidence_quote` if the flag did not carry them; `reviewer_note` replaces the rationale when it needs sharpening. Duplicates become `duplicate`.
3. **Gold.** The daily training run (`.github/workflows/zeus-train.yml`, 03:23 UTC) runs `zeus/feedback_to_gold.py`: accepted rows that no version has trained on become lines in `zeus/data/gold/feedback-<date>.jsonl`, rebuilt with the passages' real text from the Commons and validated exactly like hand-written gold (every quote an exact substring, two passages at least). Rows are marked `used_in = <version>`. Flags with `wrong_source` or `unclear` are kept for analysis and make no example.
4. **Train.** New gold lines make training due (`zeus/cloud/due.py`), so a reviewed flag reaches Zeus the next morning. Training also runs when the set has grown a tenth or a week has passed.
5. **Measure and publish.** The new version is measured on the frozen split, on held-out VitaminC and on an LLM-AggreFact sample, written to `docs/ZEUS_SCORECARD.md`, promoted only if not worse, and published to the Worker. The public counts (`GET /functions/v1/olo-feedback?stats=1`: total, new, accepted, taught, disagreement rate) go on the Commons page.

## Checks by POL Net members (Teach Zeus)

The second way people teach Zeus, built in November 2026 (`polnet://teach/`, API under `/v1/checks`, migration `apps/polnet/server/supabase/migrations/004_polnet_checks.sql`). A flag starts from a sentence Olo wrote; a check starts from a claim nobody has confirmed.

1. **Items.** `python3 zeus/member_checks_to_gold.py items` picks rule-made examples from the train side of the eval hash, removes the label, the evidence and the rationale, and adds a few hand-written gold examples as controls. Only passages from clearly open sources go out (Wikipedia, Wikinews, Project Gutenberg, data.gov, Wikidata); abstracts from PubMed, arXiv and OpenAlex and Internet Archive items are left out because their licence lines in the Commons are mixed or unclear, and the `gold` step refuses them too, so items uploaded before this rule cannot become gold. Rule-made passages are tidied for reading (a doubled full stop, a last sentence cut off by the length cap). A person uploads them with the admin secret (apps/polnet/DEPLOY.md, section 6).
2. **Check.** A member of POL Net (one Proof-of-Life check, one account) sees one claim and its two to four passages with their sources, and answers supported, contradicted or not covered. For the first two the member selects the exact words in one passage that decide it, and the server refuses a quote that is not in that passage. One answer per member per item, 120 an hour. Nobody sees anyone else's answer before the item is settled.
3. **Agree.** Three members with the same label settle an item as agreed. Five answers without that settle it as disputed, and it is set aside. A member is told only whether an item settled with their answer, and their own totals.
4. **Gold.** `python3 zeus/member_checks_to_gold.py gold export.json` turns agreed items into lines of `zeus/data/gold/checks-<date>.jsonl` (kind `member_check`), validated exactly like hand-written gold and left out if any passage is an eval atom. A person reads the file before it is committed. From there the loop above carries on at step 4.

Controls measure care: `GET /v1/checks/stats` on the POL Net API publishes how many checks, people and lessons there are, and what share of answers on control items matched the hand-written label. Control items are never exported. No member id, handle or address is in an exported line.

What this is and is not: it is real people's judgement reaching a real neural network through a measured, reviewed path. It is not a model that updates itself while people use it; training still runs in the daily job and a version is promoted only if it is not worse. Checks are unpaid for now; paying for them through Tasks needs a funder and is not built.

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

# The Olo brain: questions people share

The public Olo brain at https://heliusnetwork.app/olo#brain shows the Commons as a living graph of atoms. Since October 2026 it also shows the questions people chose to add: each one a small glowing orb, coloured by the app it came from, linked by faint lines to the atoms that answered it. Hover or tap an orb to read the question and how many times it has been asked.

Adding a question is opt in. Olo's apps ask once ("Add my questions to the Olo brain?"), remember the answer as the account default, and show a per-chat toggle. Private chats are never added.

## What is stored

One row per distinct question in `olo_brain_questions` (sql/003):

| column | what it holds |
| --- | --- |
| `text` | the question after scrubbing (below), at most 500 characters |
| `norm_hash` | SHA-256 of the scrubbed text in lower case without punctuation; the same question is stored once |
| `client` | `web`, `ios` or `macos` |
| `atoms` | up to 12 Commons atom ids that answered it (UUIDs only) |
| `answered` | whether Olo could answer it from the Commons |
| `asks` | how many times it has been asked (one address counts once a day) |
| `status` | `published` (shown), `held` (waiting for a person) or `rejected` |
| `reason` | why it was held, or a reviewer's note |
| `created_at`, `updated_at`, `last_asked_at` | timestamps |

Two small tables keep the rate limit and the once-a-day rule, keyed by a hash of the caller's address with a daily salt: `olo_brain_rate` (hits per hour) and `olo_brain_seen` (which question an address hash already asked today). Their rows are deleted after two days. `olo_brain_daily` keeps one number per day, the asks, for "N questions asked today".

## What is never stored

No user id or account, no IP address (only the salted hash above, for two days), no conversation, no answer text, no device id, no location. The apps send only the question, the client name, the atom ids and whether it was answered.

## Scrubbing, before anything is written

`functions/olo-brain-ask/brain.ts`, tested in `tests/brain_test.ts`:

- email addresses become `[email]`
- phone numbers, UK (07700 900123, (020) 7946 0958) and international (+44 ..., 0033 ..., (415) 555-0132), become `[phone]`
- URLs keep only the domain: `https://www.bbc.co.uk/news/x?ref=me` becomes `bbc.co.uk`
- IBAN-like strings become `[account]`, national insurance numbers `[id]`
- UK postcodes become `[postcode]`
- runs of six or more digits (order numbers, card numbers, dates written as digits) become `[number]`
- `@handles` become `[handle]`
- a name after "my name is", or a capitalised name after "I am", "I'm" or "call me", becomes `[name]`

Invisible characters are removed and compatibility forms normalised first, so a zero-width space or fullwidth digits cannot slip a detail past the patterns.

## Held, never shown

A question is held when, after scrubbing:

- it still looks personal: "my address", "my passport number", "my NHS number", "I live at", "born on", a street address next to "I" or "my", a named relative ("my son Oliver"), or three or more different kinds of detail removed from one question (`personal`)
- it reads as crisis or self-harm, using the same first-person patterns as olo-web's crisis banner (`client/src/lib/crisis.ts`) plus requests for methods (`crisis`). A question about the topic ("suicide rates in the UK") is published.
- it contains a slur or a threat from a small, conservative list (`abuse`)
- fewer than 8 characters are left once placeholders are removed (`too_short`)

Held questions are counted in the stats but never returned by `olo_brain_recent`.

## Reviewing held questions

In the Supabase SQL editor (service role):

```sql
-- What is waiting, oldest first
select id, created_at, client, reason, asks, text
from public.olo_brain_questions
where status = 'held'
order by created_at
limit 100;

-- Publish one that is harmless (for example a too_short false alarm)
update public.olo_brain_questions set status = 'published', reason = 'reviewed: fine' where id = 123;

-- Reject one (it stays out even if asked again; its text is cleared after 30 days)
update public.olo_brain_questions set status = 'rejected', reason = 'reviewed: personal' where id = 124;

-- Take a published question down
update public.olo_brain_questions set status = 'rejected', reason = 'taken down on request' where id = 125;
```

Crisis items are held, not answered here: the person already saw the helplines in the app. Nobody should try to identify the author; nothing in the row can.

## Retention

`olo_brain_retention()` runs daily at 03:17 UTC through pg_cron (scheduled by sql/003 as `olo_brain_retention_daily`):

- held rows older than 30 days are deleted
- rejected rows untouched for 30 days have their text replaced by `[removed]`; the hash stays so the same text stays out
- rate-limit and once-a-day rows older than two days are deleted

If pg_cron is not enabled, sql/003 prints a notice; run the same thing by hand:

```sql
select public.olo_brain_retention();
```

Published questions are kept, because they are the public record of what people asked. Take one down with the `rejected` update above.

## How it feeds the Commons

When a published question was not answered (`answered: false`), `olo_brain_record` calls `olo_record_gap` (sql/002): at most six of its content words become a topic in `olo_gaps`, and the ingester reads sources on topics asked more than once. The per-address cap of 20 topics a day applies; olo-web's server calls are not capped there because one address speaks for every user.

## Endpoints

See docs/API.md, "The Olo brain: shared questions". Rate limit 30 questions an hour per address hash; 3,000 for the service key (olo-web).

## Deploying

1. Run `sql/003_brain_questions.sql` in the SQL editor (after 001 and 002). It is safe to run again.
2. Deploy the function: the "Deploy Edge Functions" workflow picks up `functions/olo-brain-ask` on the next push to main and waits for approval, or run it by hand with `olo-brain-ask` in the list. By hand: `supabase functions deploy olo-brain-ask --no-verify-jwt`.

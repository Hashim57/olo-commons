# Adding a source connector

A connector is one async function in `functions/olo-ingest/index.ts` plus one row in `olo_sources`. Use the arXiv connector as the model.

## 1. The registry row

```sql
insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust, enabled)
values ('europeana', 'Europeana', 'archive', 'https://www.europeana.eu', 'https://api.europeana.eu/record/v2', 'Varies (CC0, CC BY, CC BY-SA per record)', 'https://www.europeana.eu/en/rights', 'Cultural heritage records from European museums, libraries and archives.', 80, false);
```

`enabled = false` until the connector is merged and reviewed. The ingester never fetches a source that is not enabled.

## 2. The discover function

Put the mapping in a pure module next to `index.ts` (no I/O, so `deno test tests/` covers it), and keep the fetch in `index.ts`. The Europeana connector is a complete example: `europeana.ts` maps a search response to candidates, `tests/europeana_test.ts` tests it, and `index.ts` does the call:

```ts
async europeana(n, src) {
  const topic = EUROPEANA_TOPICS[Math.floor(Math.random() * EUROPEANA_TOPICS.length)];
  const rows = Math.min(n * 4, 40);
  const r: any = await getEuropeana(europeanaSearchUrl(src.api_base || EUROPEANA_API, Deno.env.get('EUROPEANA_KEY') || EUROPEANA_DEMO_KEY, topic, rows, 1 + Math.floor(Math.random() * 200)));
  return pick(europeanaCandidates(r, n * 3), n);
}
```

Europeana's `guid` carries the API key in its tracking parameters, so the connector builds the URL from the record id instead, and redacts the key from error messages. Watch for the same in any API that takes its key in the query string.

Rules that keep the Commons safe and clean:

- A discover function is called as `fn(n, src)`, where `src` is the source's registry row. Read `src.api_base` rather than hard-coding a host when the source might move (the `data_gov` connector does this).
- Set `lang` on each candidate when the source is not English (ISO 639-1, for example `es`); the ingester stores `lang` and defaults to `en`. `wikipedia_es` is the model for a second language edition.
- If the source is a CKAN portal (data.gov, data.gov.uk, data.europa.eu and many city portals), reuse `ckanCandidates()` from `ckan.ts`: it keeps only packages under an open licence id and is unit tested in `tests/ckan_test.ts`.

- Return at most `n` candidates. Randomise the window so repeated runs discover new items.
- `url` must be https and stable; `external_id` is the source's own identifier.
- Everything passes through `clean()` (in `text.ts`): tags stripped, entities decoded, whitespace collapsed. Never return HTML. If the source carries LaTeX (arXiv does), wrap the field in `delatex()` first so summaries read as plain text.
- `licence` must be a real licence string for that item or the source's default. When the source mixes licences per item (Europeana, data.gov), check each item and drop the ones that are not open.
- Keys go in Supabase secrets (`supabase secrets set EUROPEANA_KEY=...`), never in code.
- Respect the source's rate limits; the ingester runs hourly with a small budget per source.

## 3. Quality and trust

`trust` (0 to 100) is the source's baseline; `quality()` adjusts per atom (length, authors, date). Say in the PR why you chose the number.

## 4. Test locally

```bash
supabase functions serve olo-ingest --no-verify-jwt
curl -X POST http://localhost:54321/functions/v1/olo-ingest -H "Authorization: Bearer $SERVICE_ROLE_KEY" -d '{"budget": 10}'
```

Then `select slug, atoms, last_run_at from olo_sources;` and look at a few atoms with `select title, summary, url, licence from olo_atoms order by created_at desc limit 10;`.

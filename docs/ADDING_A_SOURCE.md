# Adding a source connector

A connector is one async function in `functions/olo-ingest/index.ts` plus one row in `olo_sources`. Use the arXiv connector as the model.

## 1. The registry row

```sql
insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust, enabled)
values ('europeana', 'Europeana', 'archive', 'https://www.europeana.eu', 'https://api.europeana.eu/record/v2', 'Varies (CC0, CC BY, CC BY-SA per record)', 'https://www.europeana.eu/en/rights', 'Cultural heritage records from European museums, libraries and archives.', 80, false);
```

`enabled = false` until the connector is merged and reviewed. The ingester never fetches a source that is not enabled.

## 2. The discover function

```ts
async europeana(n) {
  const r: any = await get(`https://api.europeana.eu/record/v2/search.json?wskey=${Deno.env.get('EUROPEANA_KEY')}&query=*&rows=${n}&start=${1 + Math.floor(Math.random() * 1000)}&profile=rich`);
  return (r.items || []).filter((i: any) => i.title && i.dcDescription).map((i: any) => ({
    external_id: i.id, url: i.guid, title: clean(i.title[0]).slice(0, 200),
    summary: clean(i.dcDescription[0]).slice(0, 600), content: clean(i.dcDescription.join(' ')),
    authors: i.dcCreator, published_at: undefined, licence: i.rights?.[0] || 'See record',
  }));
}
```

Rules that keep the Commons safe and clean:

- Return at most `n` candidates. Randomise the window so repeated runs discover new items.
- `url` must be https and stable; `external_id` is the source's own identifier.
- Everything passes through `clean()`: tags stripped, whitespace collapsed. Never return HTML.
- `licence` must be a real licence string for that item or the source's default.
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

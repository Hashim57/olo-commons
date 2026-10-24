# Olo Commons read API

Base: `https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-query`

## Query

`POST` with JSON `{ "q": "<question or topic>", "k": 8, "mode": "hybrid" }`, or `GET ?q=...&k=8`.

- `q`: 2 to 400 characters. Never stored.
- `k`: 1 to 20 results.
- `mode`: `hybrid` (default: meaning search merged with keyword search), `semantic`, or `keyword`. Anything else is treated as `hybrid`.

In `hybrid` mode the two result lists are merged by reciprocal rank fusion: each retriever contributes `1 / (60 + position)` and an atom found by both is placed first. Each result carries `match` (`both`, `semantic` or `keyword`) so you can see which retriever found it. `similarity` is the cosine score from the meaning search and is `null` for keyword-only hits.

Response:

```json
{
  "q": "...",
  "k": 8,
  "mode": "hybrid",
  "results": [
    {
      "id": "uuid", "title": "...", "summary": "...", "content": "up to 2000 chars or null",
      "url": "https://...", "source": "Wikipedia", "source_slug": "wikipedia", "licence": "CC BY-SA 4.0",
      "published_at": "2024-03-01", "retrieved_at": "2026-10-20T17:00:00Z", "similarity": 0.81, "match": "both",
      "citation": "Title (Wikipedia, CC BY-SA 4.0). https://..."
    }
  ],
  "attribution": "..."
}
```

## Answer: a checked answer in one call

`POST https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-answer` with `{ "q": "<question>", "k": 8 }` (or `GET ?q=...`). Olo retrieves passages exactly as the query call does, drafts two to four sentences with a hosted open-weight model (every sentence cites the passages it rests on), then has every sentence checked by the verifier: supported, contradicted or not covered, with the quoted evidence. Nothing is asserted that the passages cannot show: a verdict whose quote is not found in its passage is downgraded to not covered.

```json
{ "q": "...", "covered": true,
  "answer": "Project Gutenberg was founded in 1971 by Michael S. Hart. It is the oldest digital library.",
  "sentences": [
    { "text": "Project Gutenberg was founded in 1971 by Michael S. Hart.", "citations": ["p1"], "verdict": "supported",
      "evidence": [{ "passage": "p1", "quote": "founded in 1971 by American writer Michael S. Hart" }], "rationale": "The passage states it directly.", "evidence_checked": true },
    { "text": "It is the oldest digital library.", "citations": ["p1"], "verdict": "supported", "evidence": [{ "passage": "p1", "quote": "the oldest digital library" }], "rationale": "...", "evidence_checked": true }
  ],
  "summary": { "supported": 2, "contradicted": 0, "not_covered": 0 },
  "passages": [ { "id": "p1", "atom": "uuid", "title": "Project Gutenberg", "url": "https://en.wikipedia.org/wiki/Project_Gutenberg", "source": "Wikipedia", "source_slug": "wikipedia", "licence": "CC BY-SA 4.0", "published_at": null, "retrieved_at": "...", "summary": "...", "similarity": 0.83, "match": "both", "citation": "Project Gutenberg (Wikipedia, CC BY-SA 4.0). https://en.wikipedia.org/wiki/Project_Gutenberg" } ],
  "verifier": "llm-fallback", "model": "openai/gpt-oss-120b",
  "attribution": "..." }
```

`verifier` says what checked the sentences: `zeus:<model>` when a served Zeus adapter did (`OLO_ZEUS_URL` set), or `llm-fallback` when the drafting model ran the Zeus prompt instead. The page shows this, so nobody mistakes the fallback for Zeus. When the Commons has nothing on the question, `covered` is false, `answer` is "The Commons does not cover this yet." and the topic words of the question (never the question itself) are recorded as a gap for the ingester to fill (see Gaps below). Same limits as the query call; the two share one counter. A `503 answering_not_configured` means the project has no model key yet; a `502 model_unavailable` means the provider did not answer in time.

## Status

`GET ?status=1` (or `POST {"status": true}`) returns the health of the Commons without any key:

```json
{ "ok": true, "at": "2026-10-24T12:00:00Z",
  "stats": { "atoms": 1200, "links": 4100, "sources": 8, "atoms_24h": 90, "last_run": "...", "by_source": [ { "slug": "wikipedia", "atoms": 310, "last_run_at": "..." } ] },
  "runs": [ { "started_at": "...", "finished_at": "...", "fetched": 8, "added": 6, "skipped": 2, "failed": 0, "linked": 20, "note": "cron" } ],
  "runs_unfinished": 0, "runs_with_failures": 0 }
```

`stats` is exactly `olo_stats()` (below); `runs` is the last twelve rows of `olo_ingest_runs`, newest first. Both are readable with the anon key already, so this exposes nothing new; it just needs no key in the URL. Cacheable for a minute.

Limits: 120 requests per hour per address; 3,000 with a partner key sent as `x-olo-key`. Helius Citizens (heliusnetwork.app/citizen) get a key on their profile; partner keys are also issued by hand. A 429 carries `Retry-After`.

## Direct SQL functions (anon key)

Also callable through PostgREST with the project's anon key (public read key; the `ANON` constant in `examples/graph-export.mjs`): `olo_stats()`, `olo_growth(p_days)`, `olo_recent(p_k)`, `olo_search_text(p_q, p_k)`, `olo_graph_sample(p_n)`, `olo_atom(p_id)`, `olo_export(p_after, p_limit)`, `olo_links_export(p_after, p_limit)`. The tables `olo_sources`, `olo_atoms`, `olo_links`, `olo_daily`, `olo_ingest_runs` and the view `olo_projects_public` are readable. Everything is read-only and bounded; `olo_match` and `olo_neighbours` are server-only.

Call shape (PostgREST): `POST https://bfldflbkebyapfagsxnr.supabase.co/rest/v1/rpc/<function>` with headers `apikey: <anon key>`, `Authorization: Bearer <anon key>`, `Content-Type: application/json` and the arguments as a JSON object using the parameter names above.

```bash
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/olo_search_text" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"p_q": "coral reef recovery", "p_k": 5}'
```

### Bulk export

`olo_export(p_after, p_limit)` returns pages of atoms in creation order, without embeddings:

```json
{ "atoms": [ { "id": "...", "title": "...", "summary": "...", "content": "...", "url": "...", "source": "wikipedia",
               "licence": "CC BY-SA 4.0", "authors": null, "published_at": null, "content_hash": "...", "quality": 83,
               "retrieved_at": "...", "created_at": "..." } ],
  "next_after": "2026-10-20T17:12:03.1Z",
  "licence_note": "Each atom carries its own licence; the compilation is CC BY-SA 4.0. Attribute Olo Commons by Helius Network." }
```

Page with `p_after` = the `next_after` you received (`p_limit` up to 500; start at `1970-01-01`). `next_after` is null when there is nothing after `p_after`. `olo_links_export(p_after, p_limit)` does the same for links (`from`, `to`, `relation`, `weight`, `created_at`; up to 2,000 per page). `examples/graph-export.mjs` walks both to the end.

### Gaps

`olo_gaps_recent(p_k)` returns what Olo is learning from being used: `open` (topics people asked about that the Commons could not cover, with how often they were asked), `filled` (topics the ingester has since read sources for, with how many atoms it added), and the counters `open_count`, `filled_24h`, `atoms_added_24h`. A topic is a bag of at most six lower-case content words from the question, such as `founded gutenberg project`; the question itself is never stored. The table `olo_gaps` is readable too.

### Stats

`olo_stats()` returns `atoms`, `links`, `sources`, `atoms_24h`, `links_24h`, `queries_24h`, `queries_total`, `projects`, `last_run` and `by_source` (one entry per enabled source with `slug`, `name`, `kind`, `licence`, `homepage`, `atoms`, `trust`, `last_run_at`). It is what the live page shows.

## Using it in an assistant

Call the API first, pass the `results` to the model as context, and ask it to cite with `citation`. Respect each result's `licence`.

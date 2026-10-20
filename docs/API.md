# Olo Commons read API

Base: `https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-query`

## Query

`POST` with JSON `{ "q": "<question or topic>", "k": 8, "mode": "hybrid" }`, or `GET ?q=...&k=8`.

- `q`: 2 to 400 characters. Never stored.
- `k`: 1 to 20 results.
- `mode`: `hybrid` (default: meaning search merged with keyword search), `semantic`, or `keyword`.

Response:

```json
{
  "q": "...",
  "k": 8,
  "results": [
    {
      "id": "uuid", "title": "...", "summary": "...", "content": "up to 2000 chars or null",
      "url": "https://...", "source": "Wikipedia", "source_slug": "wikipedia", "licence": "CC BY-SA 4.0",
      "published_at": "2024-03-01", "retrieved_at": "2026-10-20T17:00:00Z", "similarity": 0.81,
      "citation": "Title (Wikipedia, CC BY-SA 4.0). https://..."
    }
  ],
  "attribution": "..."
}
```

Limits: 120 requests per hour per address; 3000 with a partner key sent as `x-olo-key`. A 429 carries `Retry-After`.

## Direct SQL functions (anon key)

Also callable through PostgREST with the project's anon key: `olo_stats()`, `olo_growth(days)`, `olo_recent(k)`, `olo_search_text(q, k)`, `olo_graph_sample(n)`, `olo_atom(id)`. The views `olo_sources`, `olo_atoms`, `olo_links`, `olo_daily`, `olo_projects_public` are readable.

## Using it in an assistant

Call the API first, pass the `results` to the model as context, and ask it to cite with `citation`. Respect each result's `licence`.

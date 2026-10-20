# How Olo Commons works inside

```
 trusted sources ──(their public APIs)──▶ olo-ingest (hourly, service role)
                                              │  clean → hash → embed (gte-small, in Supabase)
                                              ▼
                              ┌──────── Postgres + pgvector ────────┐
                              │ olo_sources   registry, trust       │
                              │ olo_atoms     provenance + vector   │
                              │ olo_links     nearest neighbours    │
                              │ olo_daily     growth snapshots      │
                              └──────────────┬──────────────────────┘
          read-only functions (anon key)      │        olo-query (public API)
          olo_stats / olo_search_text /       │        embed question → olo_match
          olo_graph_sample / olo_export ...   │        + keyword, merged, cited
                                              ▼
            heliusnetwork.app/olo    helius-olo.io    Helius app (Olo)    your project
```

**Write path.** Only `olo-ingest` writes, with the service role. It reads the registry, calls each enabled source's discover function, cleans and caps the text, computes a SHA-256 of title + summary + content, refuses duplicates (unique on hash and URL), embeds the title and summary with `gte-small` (384 dimensions) inside the Supabase Edge runtime, inserts the atom, then asks `olo_neighbours` for the five closest atoms by cosine similarity and links any above 0.72 in both directions. It logs the run and snapshots counts.

**Read path.** `olo-query` embeds the question the same way, calls `olo_match` (HNSW index, cosine), merges with a keyword search (`tsvector`), and returns atoms with provenance and a ready citation. Rate limited per hashed address. The SQL functions are callable directly with the anon key for stats, graph samples, single atoms and bulk export.

**Trust.** Row Level Security gives clients read-only access to knowledge and no access to the queue or query log. Projects and proposals are the only client-writable tables, and a trigger stops projects approving themselves. Nothing personal is stored: queries are counted, not kept.

**Why a graph.** Links are cheap to compute at insert time and expensive to compute later. They give the page something true to show (the Commons thickening), give the API a way to expand a result to its neighbours, and give researchers a dataset (see `examples/graph-export.mjs`).

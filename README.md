# Olo Commons

An open, verifiable knowledge base that an AI can think with, and that belongs to everyone.

Olo Commons grows every hour from sources the world already trusts (Wikipedia, Wikidata, the Internet Archive, arXiv, Project Gutenberg, PubMed). Every unit of knowledge (an "atom") keeps its provenance: source, URL, licence, authors, publication date, a SHA-256 fingerprint of its content and the time it was retrieved. Atoms are embedded and linked to their nearest neighbours, so the Commons is a graph that thickens as it learns. Anyone can read it through one free API. Only allow-listed sources, fetched by the server, can write to it.

Live: https://heliusnetwork.app/olo

## Why

Language models are good at reasoning and bad at remembering. The fix is not a bigger model; it is a shared, citable memory that is open to inspect, open to correct and open to build on, in the spirit of the Internet Archive and Wikipedia. Olo Commons is that memory for Olo (helius-olo.io and the Olo inside the Helius Network app), and for anyone else.

## What is in this repository

- `sql/001_olo_commons.sql`: the schema for Postgres with pgvector. Sources registry, atoms, links, queue, run log, daily snapshots, projects, read-only API functions, Row Level Security, scheduled jobs.
- `functions/olo-ingest`: the hourly ingester (Supabase Edge Function, Deno). One discovery routine per source, using that source's own public API. Embeds with `gte-small` inside Supabase; no external AI key.
- `functions/olo-query`: the read API. Meaning search merged with keyword search, provenance on every result, rate limiting by hashed address, CORS for known origins.
- `docs/API.md`: how to call it.
- `SECURITY.md`: what is enforced and how to report a problem.

## Run your own

1. Create a Supabase project. In the SQL editor run `sql/001_olo_commons.sql`. Store your service-role key in Vault as `service_role_key` (the schedule uses it).
2. `supabase functions deploy olo-ingest --no-verify-jwt` and `supabase functions deploy olo-query --no-verify-jwt`.
3. Optional secrets: `OLO_API_KEYS` (comma-separated partner keys for a higher rate limit), `OLO_SALT` (for address hashing).
4. Trigger the first ingest by hand: `select public.run_olo_ingest();`. From then on it runs at 15 past every hour.

## Build on it

- `examples/cited-chat.mjs`: a chatbot that asks the Commons first and cites.
- `examples/notebook.py`: a topic's atoms as a pandas DataFrame with provenance.
- `examples/graph-export.mjs`: the whole graph as GraphML or JSON.
- `docs/API.md`: the read API; `docs/ARCHITECTURE.md`: how it works inside.

## Starting points for contributors

Issues labelled `good first issue` are small and real: a new source connector, a better `clean()`, a language other than English, tests for a connector. Templates: propose a source, report an atom, bug.

## Adding a source

See `docs/ADDING_A_SOURCE.md`. In short: open a pull request that adds a `discover` routine in `functions/olo-ingest/index.ts` and a row in `olo_sources`. Requirements: a public API or dump, an open licence that allows redistribution with attribution, no personal data, and a `trust` value with a one-line justification. A source that is not `enabled` in the registry is never fetched.

## Licences

- Code: Apache License 2.0 (see `LICENSE`).
- Data: each atom carries the licence of its source and must be used under that licence. The Commons as a compilation is offered under CC BY-SA 4.0.

## Governance

Sources, trust levels and project approvals are reviewed by Helius Network Ltd for now, in public, through issues in this repository. The intent is to move that to an open editorial group as contributors arrive.

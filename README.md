# Olo Commons

An open, verifiable knowledge base that an AI can think with, and that belongs to everyone.

Olo Commons grows every 15 minutes from sources the world already trusts (Wikipedia, Wikidata, the Internet Archive, arXiv, Project Gutenberg, PubMed; connectors for data.gov and the Spanish Wikipedia are in review). Every unit of knowledge (an "atom") keeps its provenance: source, URL, licence, authors, publication date, a SHA-256 fingerprint of its content and the time it was retrieved. Atoms are embedded and linked to their nearest neighbours, so the Commons is a graph that thickens as it learns. Anyone can read it through one free API. Only allow-listed sources, fetched by the server, can write to it.

Live: https://heliusnetwork.app/olo

## Why

Language models are good at reasoning and bad at remembering. The fix is not a bigger model; it is a shared, citable memory that is open to inspect, open to correct and open to build on, in the spirit of the Internet Archive and Wikipedia. Olo Commons is that memory for Olo (helius-olo.io and the Olo inside the Helius Network app), and for anyone else.

## What is in this repository

- `sql/001_olo_commons.sql`: the schema for Postgres with pgvector. Sources registry, atoms, links, queue, run log, daily snapshots, projects, read-only API functions, Row Level Security, scheduled jobs.
- `functions/olo-ingest`: the hourly ingester (Supabase Edge Function, Deno). One discovery routine per source, using that source's own public API. Embeds with `gte-small` inside Supabase; no external AI key.
- `functions/olo-query`: the read API. Meaning search merged with keyword search, provenance on every result, rate limiting by hashed address, CORS for known origins.
- `functions/olo-answer`: the answer API. Retrieves like olo-query, drafts two to four cited sentences with a hosted open-weight model, and has every sentence checked (supported, contradicted, not covered, with quoted evidence) by Zeus when a served adapter is configured, otherwise by the drafting model under the Zeus prompt, and says which. Uncovered questions become gaps the ingester fills next.
- `docs/API.md`: how to call it.
- `SECURITY.md`: what is enforced and how to report a problem.

## Run your own

1. Create a Supabase project. In the SQL editor run `sql/001_olo_commons.sql`. Store your service-role key in Vault as `service_role_key` (the schedule uses it).
2. `supabase functions deploy olo-ingest --no-verify-jwt` and `supabase functions deploy olo-query --no-verify-jwt`. (This repository also ships `.github/workflows/deploy-functions.yml`, which deploys both after a human approves the run; see the comments at the top of that file for the two-step setup.)
3. Optional secrets: `OLO_API_KEYS` (comma-separated partner keys for a higher rate limit), `OLO_SALT` (for address hashing). For answers: `OLO_LLM_API_KEY` (an OpenAI-compatible provider key; without it olo-answer returns 503), `OLO_LLM_BASE_URL` (default Groq), `OLO_LLM_MODEL` (default `qwen/qwen3-32b`), and `OLO_ZEUS_URL` once a Zeus adapter is served.
4. Trigger the first ingest by hand: `select public.run_olo_ingest();`. From then on it runs at 15 past every hour.

## Zeus: the verification model

`zeus/` holds the open build of Zeus, Olo's claim verification layer: a LoRA fine-tune of an open-weight instruction model (Qwen2.5-7B-Instruct by default) trained on examples made from the Commons itself. `build_dataset.py` makes the data, `train_lora.py` trains on one GPU, `eval.py` scores every version on a frozen split, `serve.py` exposes it over HTTP. `zeus/STATUS.md` records each build. Hand-written examples in `zeus/data/gold/` are the most useful contribution you can make.

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

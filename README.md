# Olo Commons

An open, verifiable knowledge base that an AI can think with, and that belongs to everyone.

Olo Commons grows every 15 minutes from sources the world already trusts (Wikipedia, Wikidata, the Internet Archive, arXiv, Project Gutenberg, PubMed; connectors for data.gov and the Spanish Wikipedia are in review). Every unit of knowledge (an "atom") keeps its provenance: source, URL, licence, authors, publication date, a SHA-256 fingerprint of its content and the time it was retrieved. Atoms are embedded and linked to their nearest neighbours, so the Commons is a graph that thickens as it learns. Anyone can read it through one free API. Only allow-listed sources, fetched by the server, can write to it.

Live: https://heliusnetwork.app/olo

Since October 2026 every atom also carries trust and time: a status (candidate, verified, disputed, superseded, retracted), a computed credibility, validity dates, the revision of its source and what replaced it (docs/TRUST.md). Sources are re-read and nothing is overwritten. Sentence flags from Olo's apps, reviewed by a person, teach Zeus every day (docs/FEEDBACK.md); Zeus's measured numbers are in docs/ZEUS_SCORECARD.md. Olo, Zeus and the Commons together are Helius Network's WEBOCTA system (docs/WEBOCTA.md).

## Why

Language models are good at reasoning and bad at remembering. The fix is not a bigger model; it is a shared, citable memory that is open to inspect, open to correct and open to build on, in the spirit of the Internet Archive and Wikipedia. Olo Commons is that memory for Olo (helius-olo.io and the Olo inside the Helius Network app), and for anyone else.

## What is in this repository

- `sql/001_olo_commons.sql`: the schema for Postgres with pgvector. Sources registry, atoms, links, queue, run log, daily snapshots, projects, read-only API functions, Row Level Security, scheduled jobs.
- `sql/002_trust_time_provenance.sql`: status, credibility, validity dates, source revisions, supersession, the feedback table, retractions and the per-address cap on curiosity gaps. Run after 001.
- `functions/olo-ingest`: the hourly ingester (Supabase Edge Function, Deno). One discovery routine per source, using that source's own public API. Embeds with `gte-small` inside Supabase; no external AI key.
- `functions/olo-query`: the read API. Meaning search merged with keyword search, provenance on every result, rate limiting by hashed address, CORS for known origins.
- `functions/olo-answer`: the answer API. Retrieves like olo-query, drafts two to four cited sentences with a hosted open-weight model, and has every sentence checked (supported, contradicted, not covered, with quoted evidence) by Zeus when a served adapter is configured, otherwise by the drafting model under the Zeus prompt, and says which. Uncovered questions become gaps the ingester fills next.
- `functions/olo-feedback`: sentence flags from the apps, bounded and rate limited, reviewed before they teach Zeus.
- `docs/API.md`: how to call it. `docs/TRUST.md`, `docs/FEEDBACK.md`, `docs/ZEUS_SCORECARD.md`, `docs/WEBOCTA.md`.
- `SECURITY.md`: what is enforced and how to report a problem.

## Run your own

1. Create a Supabase project. In the SQL editor run `sql/001_olo_commons.sql`. Store your service-role key in Vault as `service_role_key` (the schedule uses it).
2. `supabase functions deploy olo-ingest --no-verify-jwt` and `supabase functions deploy olo-query --no-verify-jwt`. (This repository also ships `.github/workflows/deploy-functions.yml`, which deploys both after a human approves the run; see the comments at the top of that file for the two-step setup.)
3. Optional secrets: `OLO_API_KEYS` (comma-separated partner keys for a higher rate limit), `OLO_SALT` (for address hashing). For answers: `OLO_LLM_API_KEY` (an OpenAI-compatible provider key; without it olo-answer returns 503), `OLO_LLM_BASE_URL` (default Groq), `OLO_LLM_MODEL` (default `openai/gpt-oss-120b`), and `OLO_ZEUS_URL` once a Zeus adapter is served.
4. Trigger the first ingest by hand: `select public.run_olo_ingest();`. From then on it runs at 15 past every hour.

## Zeus: the verification model

`zeus/` holds the open build of Zeus, Olo's claim verification layer: a rank-8 LoRA on Mistral 7B Instruct v0.2 (Apache 2.0) trained on examples made from the Commons, open fact-checking corpora, hand-written gold and reviewed feedback. It trains in the cloud every day when there is something new to learn (`.github/workflows/zeus-train.yml`, `zeus/cloud/`), is measured on a frozen split, on held-out VitaminC and on an LLM-AggreFact sample, and serves on Cloudflare Workers AI (`zeus/cloudflare/`). `zeus/STATUS.md` records each build; `docs/ZEUS_SCORECARD.md` is the current scorecard. Hand-written examples in `zeus/data/gold/` are the most useful contribution you can make.

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

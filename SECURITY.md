# Security

## What is enforced

- Knowledge is write-only by the server. `olo_atoms`, `olo_links`, `olo_sources`, the queue and the logs have no insert, update or delete policy for any client role; only the service role (the ingester) writes. Clients cannot even see the queue or the query log.
- The ingester fetches only sources that are `enabled` in `olo_sources`, with a fixed User-Agent, from each source's documented public API. Content is reduced to plain text and capped in size. HTML is stripped before storage.
- Every atom carries a SHA-256 content hash and a retrieval time. Duplicate content is refused at the database (unique index).
- The read API is read-only, bounded (k up to 20, query up to 400 characters), rate limited per hashed address with a daily salt, and never stores query text.
- Projects submitted by members start as `pending` and cannot approve themselves (trigger). URLs must be http(s).
- Embeddings are computed inside Supabase (`gte-small`); no data is sent to a third-party AI provider.
- The website renders everything as text nodes, runs under a Content-Security-Policy, and ships no secret: the Supabase anon key is public by design and Row Level Security is the control.

## What is not claimed

No system is impenetrable. What this design does is make the write path small and server-only, keep the read path harmless, and make tampering detectable. Report anything that contradicts this.

## Reporting

Email security@heliusnetwork.com with details. Please do not open a public issue for an unpatched vulnerability. We acknowledge within two working days.

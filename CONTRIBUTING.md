# Contributing

- Sources: see README "Adding a source". Licence first, code second.
- Code: TypeScript for functions, plain SQL for schema. Keep the write path small. No new table may be writable by `anon` or `authenticated` without a trigger that limits what can be set.
- Pull requests need a one-paragraph explanation of what the change lets the Commons learn, and from whom.
- Tests: `deno test tests/` (no network needed). Pure helpers live in `functions/olo-ingest/text.ts` and `functions/olo-ingest/ckan.ts`; add a test when you change one.

# Contributing

- Sources: see README "Adding a source". Licence first, code second.
- Code: TypeScript for functions, plain SQL for schema. Keep the write path small. No new table may be writable by `anon` or `authenticated` without a trigger that limits what can be set.
- Pull requests need a one-paragraph explanation of what the change lets the Commons learn, and from whom.
- Tests: `deno test --allow-read tests/` (no network needed). Pure helpers live in `functions/olo-ingest/text.ts`, `ckan.ts`, `datagov.ts`, `europeana.ts`, `doaj.ts`, `sources.ts` and `runlog.ts`, `functions/olo-query/rank.ts`, `functions/olo-answer/answer.ts` and `functions/olo-brain-ask/brain.ts`; add a test when you change one. `olo-answer/rank.ts` is a copy of `olo-query/rank.ts` (each function deploys from its own folder); a test keeps them identical.

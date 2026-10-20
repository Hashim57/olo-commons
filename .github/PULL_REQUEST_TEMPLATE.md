## What this lets the Commons learn, and from whom

<!-- one paragraph -->

## Checklist

- [ ] Source is `enabled` only through a registry row with licence, licence_url and trust
- [ ] Connector uses the source's documented public API with the Commons User-Agent
- [ ] Output is plain text (no HTML), capped, with a stable `url` and `external_id`
- [ ] No table becomes writable by `anon` or `authenticated` without a guard trigger
- [ ] I ran `deno check functions/olo-ingest/index.ts`

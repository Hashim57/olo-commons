# POL Net

A private, safe browser for real people, with Olo built in, that pays members for real work. POL means Proof of Life: one real person, one account.

- `browser/`: the desktop browser (Electron). `npm install`, `npm start`. Tests: `npm test` (unit), `xvfb-run -a npm run e2e` (the real browser against the dev API; needs deno).
- `server/`: the POL Net API (a Supabase Edge Function in Deno). `deno task test` (add `POLNET_TEST_PG=postgres://...` to run against Postgres too), `deno task dev` for a local API on port 8787 with a fake Proof-of-Life that accepts any token starting `dev-`.
- `proxy/`: the Netlify site that serves polnet.heliusnetwork.app (the join page, and everything else passed to the API).
- `DEPLOY.md`: putting the API live and turning on payouts.
- The design, the protocol stages, the threat model and the economics: [docs/POLNET.md](../../docs/POLNET.md).

## Try it locally

```
cd apps/polnet/server && deno task dev        # API on http://localhost:8787
cd apps/polnet/browser && npm install && npm start
```

In the browser: menu > Settings > Servers, set the POL Net server to `http://localhost:8787`. Joining needs Proof-of-Life; with the dev API, get a pass with
`curl -s localhost:8787/v1/join -H 'content-type: application/json' -d '{"pol_token":"dev-you-1234","handle":"you"}'`.

## What it does

Shields (trackers, third-party cookies, tracking parameters, https everywhere, Global Privacy Control), lookalike and reported-site warnings, scam-page warnings (fake virus alerts, support-line scams, gift-card and crypto-doubling tricks, "safe account" requests, seed-phrase grabs), download warnings, protected mode and family help for people scammers target, per-site permissions, private windows, the pol:// members' network with pairwise ids per site, Tasks that pay, a Wallet with Stripe Connect payouts, pol:// Names, local-only History, Ask Olo with page context (and "Check this claim"), private by default, and trust tools any website can use (a consented, pairwise "real person" pass: `trust/polnet-trust.mjs`, docs/TRUST_TOOLS.md). No telemetry.

Pilot-town task templates: `pilot/tasks.json` (docs/PILOT_TOWN.md).

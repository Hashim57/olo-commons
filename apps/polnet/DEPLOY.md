# Deploying POL Net

About an hour, once. Nothing here deploys itself.

## 1. The API

1. Use the Proof-of-Life Supabase project (`helius-pol`) or a new one. SQL editor: run `server/supabase/migrations/001_polnet.sql`, then `002_polnet_helpers.sql` (family help) `003_polnet_square.sql` (the Square) and `004_polnet_checks.sql` (Teach Zeus; all four safe to run again). Optional: `select cron.schedule('polnet-hits', '23 * * * *', 'select polnet.purge_hits()');`
2. In the Proof-of-Life console, create a site "POL Net" with hostname `polnet.heliusnetwork.app`. Keep its `pk_` and `sk_` keys.
3. From `apps/polnet/server`: `deno task keys` prints `POLNET_SIGNING_JWK` and `POLNET_ADMIN_SECRET`. Keep them in a password manager; never commit them.
4. Secrets and deploy (from `server/`; `server/supabase/config.toml` lets the CLI find the function, and `--use-api` deploys without Docker):
   ```
   supabase secrets set --project-ref YOUR-PROJECT \
     POLNET_SIGNING_JWK='...' POLNET_ADMIN_SECRET='...' \
     POLNET_ISSUER='https://polnet.heliusnetwork.app' POLNET_PUBLIC_URL='https://polnet.heliusnetwork.app' \
     POL_SITEKEY='pk_...' POL_SECRET='sk_...'
   supabase functions deploy polnet-api --no-verify-jwt --use-api --project-ref YOUR-PROJECT
   ```
5. Point `polnet.heliusnetwork.app` at the function with the ready Netlify site in `proxy/`: replace `YOUR-POLNET-PROJECT` in `proxy/netlify.toml`, then from `proxy/` run `netlify deploy --prod` (choose "Create & configure a new project", for example `helius-polnet`; never link it to another site), and add `polnet.heliusnetwork.app` under Domain management. The join page is served there as a static page, because Supabase shows HTML from Edge Functions on its own domain as plain text; it reads the Proof-of-Life site key from `/v1/config`, so it needs no editing. Check:
   - `curl https://polnet.heliusnetwork.app/v1/health` answers `{"ok":true,"service":"polnet",...}`
   - https://polnet.heliusnetwork.app/join shows "Join POL Net" with the Proof-of-Life box

## 2. Payouts (when ready)

Before switching on: legal advice on worker status and the platform terms, an external security review, and an 18+ rule in the join terms and in Stripe Connect.

1. Stripe dashboard: enable Connect (Express accounts, UK and EU). Copy the secret key.
2. Webhook endpoint `https://polnet.heliusnetwork.app/v1/stripe/webhook` for `checkout.session.completed` and `account.updated`; copy its signing secret.
3. `supabase secrets set STRIPE_SECRET_KEY='sk_live_...' STRIPE_WEBHOOK_SECRET='whsec_...'` (optional: `POLNET_FEE_BPS`, default 1000 = 10%; `POLNET_MIN_PAYOUT_PENCE`, default 1000) and redeploy.

## 3. Approving an organisation

After checking who they are: `curl -X POST https://polnet.heliusnetwork.app/v1/admin/posters/MEMBER_ID -H "authorization: Bearer $POLNET_ADMIN_SECRET"`. To fund a task paid by bank transfer: `POST /v1/admin/tasks/TASK_ID/fund`. To review takedowns: `POST /v1/admin/names/NAME/restore`, `/v1/admin/members/ID/suspend` or `/restore`.

## 4. The Square, HeliusTV and the services page

The services page (`polnet://services/`, `GET /v1/services`) needs nothing: it is live once the function is deployed. The Square and HeliusTV are built but closed until `supabase secrets set POLNET_SQUARE=on` and a redeploy; read "Why the Square is shipped closed" in docs/WEBOCTA_SERVICES.md first (two Ofcom assessments, community rules, a named reviewer). To moderate: `POST /v1/admin/posts/POST_ID/remove` or `/restore` with the admin secret. When an eSIM supplier's store exists, `supabase secrets set POLNET_ESIM_STORE_URL='https://...'` turns eSIMs from "planned" to live in the catalogue.

## 5. The Mac app

The `POL Net browser` workflow builds a `.dmg` for Apple Silicon and Intel on every change (Actions > the run > Artifacts). Without a Developer ID the app is ad-hoc signed (`browser/scripts/after-pack.js`), which stops macOS calling it "damaged"; the first time, open it with right-click > Open, or System Settings > Privacy & Security > Open Anyway. To sign and notarise, add an Apple Developer ID certificate and set `mac.identity` in `browser/package.json`. POL Net is meant to ship as a direct download. On every push to main that passes, the `release` job replaces the GitHub Release `polnet-browser` with the new dmg files under fixed names, so websites (helius-olo.io, heliusnetwork.app) can link to addresses that always serve the newest build:

- Apple Silicon: https://github.com/Hashim57/olo-commons/releases/download/polnet-browser/POL-Net-mac-apple-silicon.dmg
- Intel: https://github.com/Hashim57/olo-commons/releases/download/polnet-browser/POL-Net-mac-intel.dmg

Until the app is signed with a Developer ID and notarised, say on the download page that the first open needs Control-click > Open, or System Settings > Privacy & Security > Open Anyway.

## 5. Teach Zeus

Members check claims against passages at `polnet://teach/`; three members who give the same answer make a lesson for Zeus (docs/FEEDBACK.md, "Checks by POL Net members"). It needs migration 004 and a redeploy of the function, then claims to check. From the repository root:

```
python3 zeus/member_checks_to_gold.py items --out items.json        # 200 rule-made claims and 20 controls
curl -sS -X POST https://polnet.heliusnetwork.app/v1/admin/checks -H "authorization: Bearer $POLNET_ADMIN_SECRET" -H "content-type: application/json" --data @items.json
```

To bring back what members agreed on: `curl -sS https://polnet.heliusnetwork.app/v1/admin/checks/export -H "authorization: Bearer $POLNET_ADMIN_SECRET" > export.json`, then `python3 zeus/member_checks_to_gold.py gold export.json`, read the file it writes in `zeus/data/gold/`, and commit it through a pull request. `GET /v1/checks/stats` is public: counts of checks, people and lessons, and the share of control answers that were right. Do not commit `items.json` or `export.json`.

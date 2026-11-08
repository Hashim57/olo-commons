# Deploying POL Net

About an hour, once. Nothing here deploys itself.

## 1. The API

1. Use the Proof-of-Life Supabase project (`helius-pol`) or a new one. SQL editor: run `server/supabase/migrations/001_polnet.sql` (safe to run again). Optional: `select cron.schedule('polnet-hits', '23 * * * *', 'select polnet.purge_hits()');`
2. In the Proof-of-Life console, create a site "POL Net" with hostname `polnet.heliusnetwork.app`. Keep its `pk_` and `sk_` keys.
3. From `apps/polnet/server`: `deno task keys` prints `POLNET_SIGNING_JWK` and `POLNET_ADMIN_SECRET`. Keep them in a password manager; never commit them.
4. Secrets and deploy:
   ```
   supabase secrets set --project-ref YOUR-PROJECT \
     POLNET_SIGNING_JWK='...' POLNET_ADMIN_SECRET='...' \
     POLNET_ISSUER='https://polnet.heliusnetwork.app' POLNET_PUBLIC_URL='https://polnet.heliusnetwork.app' \
     POL_SITEKEY='pk_...' POL_SECRET='sk_...'
   supabase functions deploy polnet-api --no-verify-jwt --project-ref YOUR-PROJECT
   ```
5. Point `polnet.heliusnetwork.app` at the function: a Netlify site with one redirect, `/* https://YOUR-PROJECT.supabase.co/functions/v1/polnet-api/:splat 200`, and the domain alias. Check: `curl https://polnet.heliusnetwork.app/v1/health`.

## 2. Payouts (when ready)

Before switching on: legal advice on worker status and the platform terms, an external security review, and an 18+ rule in the join terms and in Stripe Connect.

1. Stripe dashboard: enable Connect (Express accounts, UK and EU). Copy the secret key.
2. Webhook endpoint `https://polnet.heliusnetwork.app/v1/stripe/webhook` for `checkout.session.completed` and `account.updated`; copy its signing secret.
3. `supabase secrets set STRIPE_SECRET_KEY='sk_live_...' STRIPE_WEBHOOK_SECRET='whsec_...'` (optional: `POLNET_FEE_BPS`, default 1000 = 10%; `POLNET_MIN_PAYOUT_PENCE`, default 1000) and redeploy.

## 3. Approving an organisation

After checking who they are: `curl -X POST https://polnet.heliusnetwork.app/v1/admin/posters/MEMBER_ID -H "authorization: Bearer $POLNET_ADMIN_SECRET"`. To fund a task paid by bank transfer: `POST /v1/admin/tasks/TASK_ID/fund`. To review takedowns: `POST /v1/admin/names/NAME/restore`, `/v1/admin/members/ID/suspend` or `/restore`.

## 4. The Mac app

The `POL Net browser` workflow builds an unsigned `.dmg` for Apple Silicon and Intel on every change (Actions > the run > Artifacts). Unsigned apps open with right-click > Open the first time. To sign and notarise, add an Apple Developer ID certificate and set `mac.identity` in `browser/package.json`. POL Net is meant to ship as a direct download from heliusnetwork.app.

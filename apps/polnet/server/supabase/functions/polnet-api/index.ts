// POL Net API as a Supabase Edge Function. Deploy with:
//   supabase functions deploy polnet-api --no-verify-jwt --project-ref <POL Net project>
// Secrets (supabase secrets set ...): POLNET_SIGNING_JWK, POLNET_ADMIN_SECRET, POLNET_ISSUER, POLNET_PUBLIC_URL,
// POL_SITEKEY, POL_SECRET, optional POL_API, POLNET_FEE_BPS, POLNET_MIN_PAYOUT_PENCE, STRIPE_SECRET_KEY,
// STRIPE_WEBHOOK_SECRET. SUPABASE_DB_URL is provided by Supabase.
import { createApi } from "../_shared/api.ts";
import { loadSigner } from "../_shared/jwt.ts";
import { PgStore } from "../_shared/store_pg.ts";

const env = (k: string, d?: string) => {
  const v = Deno.env.get(k) ?? d;
  if (v === undefined) throw new Error(`Missing secret ${k}`);
  return v;
};

const handle = createApi({
  store: PgStore.connect(env("SUPABASE_DB_URL")),
  signer: await loadSigner(env("POLNET_SIGNING_JWK")),
  config: {
    issuer: env("POLNET_ISSUER"),
    publicUrl: env("POLNET_PUBLIC_URL", env("POLNET_ISSUER")),
    polApi: env("POL_API", "https://api.heliusnetwork.app"),
    polSitekey: env("POL_SITEKEY"),
    polSecret: env("POL_SECRET"),
    adminSecret: env("POLNET_ADMIN_SECRET"),
    feeBps: Number(env("POLNET_FEE_BPS", "1000")),
    minPayoutPence: Number(env("POLNET_MIN_PAYOUT_PENCE", "1000")),
    stripeSecret: Deno.env.get("STRIPE_SECRET_KEY") || undefined,
    stripeWebhookSecret: Deno.env.get("STRIPE_WEBHOOK_SECRET") || undefined,
    minUniqueness: (Deno.env.get("POLNET_MIN_UNIQUENESS") as "none" | "device" | "history" | "vouched" | undefined) ?? "device",
  },
});

Deno.serve(handle);

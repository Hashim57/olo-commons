// Runs the API locally on http://localhost:8787 with an in-memory store and a fake Proof-of-Life that passes
// any token starting "dev-" (subject = the rest of the token). For trying the browser against it:
//   deno run -A scripts/dev.ts
// then in the browser's settings set the POL Net server to http://localhost:8787. Never used in production.
import { createApi } from "../supabase/functions/_shared/api.ts";
import { loadSigner, newSigningJwk } from "../supabase/functions/_shared/jwt.ts";
import { MemoryStore } from "../supabase/functions/_shared/store.ts";

const store = new MemoryStore();
const fakePol: typeof fetch = async (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.endsWith("/v1/siteverify")) {
    const b = JSON.parse(String(init?.body ?? "{}"));
    const ok = typeof b.response === "string" && b.response.startsWith("dev-");
    return Response.json(ok ? { success: true, human: true, subject: `sub_${b.response.slice(4)}`, uniqueness_level: "history", "error-codes": [] } : { success: false, "error-codes": ["invalid-input-response"] });
  }
  return fetch(input, init);
};
const handle = createApi({
  store, fetch: fakePol, signer: await loadSigner(await newSigningJwk()),
  config: { issuer: "http://localhost:8787", publicUrl: "http://localhost:8787", polApi: "https://pol.invalid", polSitekey: "pk_dev", polSecret: "sk_dev", adminSecret: "dev-admin", feeBps: 1000, minPayoutPence: 1000, allowLocalTargets: true, minUniqueness: "device" },
});
console.log("POL Net dev API on http://localhost:8787 (admin secret: dev-admin; join with pol_token \"dev-<anything>\")");
Deno.serve({ port: Number(Deno.env.get("PORT") ?? 8787), onListen: ({ port }) => console.log(`listening ${port}`) }, handle);

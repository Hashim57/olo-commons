// The trust tools sites use (apps/polnet/trust/polnet-trust.mjs), checked against passes this server signs.
import { loadSigner, newSigningJwk, sign } from "../supabase/functions/_shared/jwt.ts";
import { checkClaim, humanLink, newNonce, readHumanPass, verifyHumanPass, verifyPass, verifyVisitPass } from "../../trust/polnet-trust.mjs";

function assert(cond: unknown, msg = "assertion failed"): asserts cond {
  if (!cond) throw new Error(msg);
}

const ISS = "https://polnet.test";
const NOW = Date.parse("2026-11-08T12:00:00Z");

Deno.test("trust: a human pass verifies only for its origin, nonce, type and time", async () => {
  const signer = await loadSigner(await newSigningJwk());
  const keys = [signer.publicJwk];
  const iat = Math.floor(NOW / 1000);
  const pass = await sign(signer, { iss: ISS, aud: "https://shop.example", sub: "abc", typ: "human", nonce: "nonce-123", iat, exp: iat + 300 });
  const ok = await verifyHumanPass(pass, { origin: "https://shop.example/any/path", nonce: "nonce-123", issuer: ISS, keys, now: NOW });
  assert(ok && ok.sub === "abc");
  assert(!(await verifyHumanPass(pass, { origin: "https://evil.example", nonce: "nonce-123", issuer: ISS, keys, now: NOW })), "other origin");
  assert(!(await verifyHumanPass(pass, { origin: "https://shop.example", nonce: "nonce-999", issuer: ISS, keys, now: NOW })), "other nonce");
  assert(!(await verifyHumanPass(pass, { origin: "https://shop.example", nonce: "nonce-123", issuer: "https://other.test", keys, now: NOW })), "other issuer");
  assert(!(await verifyHumanPass(pass, { origin: "https://shop.example", nonce: "nonce-123", issuer: ISS, keys, now: NOW + 400_000 })), "expired");
  assert(!(await verifyVisitPass(pass, { name: "shop", issuer: ISS, keys, now: NOW })), "a human pass is not a visit pass");
  const [h, b, s] = pass.split(".");
  const forged = `${h}.${btoa(JSON.stringify({ iss: ISS, aud: "https://shop.example", sub: "zzz", typ: "human", nonce: "nonce-123", iat, exp: iat + 300 })).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")}.${s}`;
  assert(b !== forged.split(".")[1]);
  assert(!(await verifyPass(forged, { issuer: ISS, keys, now: NOW })), "tampered claims fail the signature");
  const other = await loadSigner(await newSigningJwk());
  assert(!(await verifyPass(pass, { issuer: ISS, keys: [other.publicJwk], now: NOW })), "wrong key");
});

Deno.test("trust: visit passes, keys fetched from the JWKS address", async () => {
  const signer = await loadSigner(await newSigningJwk());
  const iat = Math.floor(NOW / 1000);
  const pass = await sign(signer, { iss: ISS, aud: "pol://community-garden", sub: "v1", typ: "visit", iat, exp: iat + 600 });
  let fetched = 0;
  const fakeFetch = (async (url: string) => {
    fetched++;
    assert(url === `${ISS}/.well-known/jwks.json`);
    return Response.json({ keys: [signer.publicJwk] });
  }) as unknown as typeof fetch;
  const c = await verifyVisitPass(pass, { name: "community-garden", issuer: ISS, jwksUrl: `${ISS}/.well-known/jwks.json`, fetch: fakeFetch, now: NOW });
  assert(c && c.sub === "v1");
  assert(!(await verifyVisitPass(pass, { name: "other-site", issuer: ISS, jwksUrl: `${ISS}/.well-known/jwks.json`, fetch: fakeFetch, now: NOW })));
  assert(fetched === 1, "keys are cached");
});

Deno.test("trust: links and fragments", () => {
  const n = newNonce();
  assert(/^[A-Za-z0-9_-]{24}$/.test(n), n);
  const link = humanLink({ origin: "https://shop.example", returnTo: "https://shop.example/verified", nonce: n });
  const u = new URL(link.replace("polnet://", "https://"));
  assert(u.hostname === "human" && u.searchParams.get("origin") === "https://shop.example" && u.searchParams.get("nonce") === n);
  let threw = false;
  try { humanLink({ origin: "https://shop.example", returnTo: "https://evil.example/", nonce: n }); } catch { threw = true; }
  assert(threw, "the pass can only return to the asking origin");
  assert(readHumanPass("https://shop.example/verified#pol_human=a.b.c") === "a.b.c");
  assert(readHumanPass("https://shop.example/verified") === null);
});

Deno.test("trust: checkClaim reports what the sources say", async () => {
  const fakeFetch = (async (_url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    assert(body.q === "Project Gutenberg was founded in 1971");
    assert((init.headers as Record<string, string>)["x-olo-key"] === "partner");
    return Response.json({ covered: true, summary: { supported: 1, contradicted: 0, not_covered: 0 }, sentences: [{ text: "Project Gutenberg was founded in 1971 by Michael Hart.", label: "supported", evidence: ["founded in 1971"] }], sources: [{ title: "Project Gutenberg", url: "https://en.wikipedia.org/wiki/Project_Gutenberg", licence: "CC BY-SA 4.0" }], verifier: "zeus:test" });
  }) as unknown as typeof fetch;
  const r = await checkClaim("Project Gutenberg was founded in 1971", { endpoint: "https://olo.test/answer", key: "partner", fetch: fakeFetch });
  assert(r.covered && r.supported === 1 && r.sentences[0].label === "supported" && r.sources[0].licence === "CC BY-SA 4.0");
});

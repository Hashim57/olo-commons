// POL Net trust tools for any website: "a real person" and "what the sources say".
//
// One file, no dependencies, Web Crypto only: runs in Node 18+, Deno, Bun, Cloudflare Workers and
// browsers. Apache License 2.0, like the rest of the repository. Guide: docs/TRUST_TOOLS.md.
//
//   import { humanLink, newNonce, readHumanPass, verifyHumanPass } from "./polnet-trust.mjs";
//
// 1. Real person, with consent. Your page links to humanLink(...). In the POL Net browser the member
//    sees who is asking and what you will get, and chooses. If they agree, the browser returns to your
//    page with #pol_human=<pass>. Your server checks it with verifyHumanPass(...). You learn that a
//    verified person is here, and an id for them that only your site sees. No name, no email, nothing
//    that links them to other sites.
// 2. Visitors of a pol:// site. The browser sends x-polnet-visit; check it with verifyVisitPass(...).
// 3. Claims. checkClaim(...) asks Olo, which answers from the open Olo Commons and has every sentence
//    checked by Zeus. It tells you what the sources say about a statement, not whether it is true in
//    the world: "not covered" means the Commons has nothing on it.

export const DEFAULT_ISSUER = "https://polnet.heliusnetwork.app";
export const DEFAULT_JWKS = `${DEFAULT_ISSUER}/.well-known/jwks.json`;

const b64urlToBytes = (s) => {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "="));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
};
const bytesToB64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** A random nonce for one verification attempt. Store it in the visitor's session and check it comes back. */
export function newNonce() {
  return bytesToB64url(crypto.getRandomValues(new Uint8Array(18)));
}

/**
 * The link that asks a POL Net member to show they are a real person.
 * `returnTo` must be on your own origin: the browser refuses to hand the pass to any other site.
 * @param {{ origin: string, returnTo: string, nonce: string }} options
 */
export function humanLink({ origin, returnTo, nonce }) {
  const o = new URL(origin).origin;
  if (new URL(returnTo).origin !== o) throw new Error("returnTo must be on the same origin");
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(nonce)) throw new Error("nonce must be 8 to 128 letters, digits, - or _");
  return `polnet://human/?${new URLSearchParams({ origin: o, return: returnTo, nonce })}`;
}

/**
 * Reads the pass from the address the browser returned to (the #pol_human fragment never reaches servers on its own).
 * @param {string} href
 */
export function readHumanPass(href) {
  const hash = new URL(href).hash.replace(/^#/, "");
  return new URLSearchParams(hash).get("pol_human");
}

/**
 * @typedef {object} KeyOptions
 * @property {Array<object>} [keys] POL Net public keys (JWKs); fetched from jwksUrl when not given.
 * @property {string} [jwksUrl] Where the keys are published.
 * @property {typeof fetch} [fetch] A fetch to use instead of the global one.
 * @property {string} [issuer] The POL Net server that signed the pass.
 * @property {number} [now] The time to check against, in milliseconds.
 */

const keyCache = new Map();

async function keysFrom({ keys, jwksUrl = DEFAULT_JWKS, fetch: f = globalThis.fetch }) {
  if (keys) return keys;
  const hit = keyCache.get(jwksUrl);
  if (hit && Date.now() - hit.at < 300_000) return hit.keys;
  const r = await f(jwksUrl);
  if (!r.ok) throw new Error(`could not fetch POL Net keys: ${r.status}`);
  const j = await r.json();
  keyCache.set(jwksUrl, { at: Date.now(), keys: j.keys || [] });
  return j.keys || [];
}

/**
 * Checks a POL Net pass (ES256 JWT). Returns its claims, or null if anything is wrong: the signature,
 * the issuer, the type, the audience, the nonce, or the time.
 * @param {string} token
 * @param {KeyOptions & { type?: string, audience?: string, nonce?: string }} [options]
 * @returns {Promise<Record<string, any> | null>}
 */
export async function verifyPass(token, { type, audience, nonce, issuer = DEFAULT_ISSUER, now = Date.now(), ...keyOpts } = {}) {
  if (typeof token !== "string" || token.length > 4096) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  let header, claims;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  } catch {
    return null;
  }
  if (header.alg !== "ES256") return null;
  const keys = await keysFrom(keyOpts);
  const jwk = keys.find((k) => k.kid === header.kid) ?? (keys.length === 1 ? keys[0] : null);
  if (!jwk || jwk.kty !== "EC" || jwk.crv !== "P-256") return null;
  const key = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, b64urlToBytes(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!ok) return null;
  const t = Math.floor(now / 1000);
  if (claims.iss !== issuer) return null;
  if (typeof claims.exp !== "number" || claims.exp < t - 30) return null;
  if (typeof claims.iat === "number" && claims.iat > t + 60) return null;
  if (type && claims.typ !== type) return null;
  if (audience && claims.aud !== audience) return null;
  if (nonce !== undefined && claims.nonce !== nonce) return null;
  return claims;
}

/**
 * A "real person" pass for your origin. `claims.sub` is this person's id on your site only.
 * @param {string} token
 * @param {KeyOptions & { origin: string, nonce: string }} options
 */
export function verifyHumanPass(token, { origin, nonce, ...opts }) {
  if (!origin || !nonce) throw new Error("origin and nonce are required");
  return verifyPass(token, { ...opts, type: "human", audience: new URL(origin).origin, nonce });
}

/**
 * The x-polnet-visit header your pol:// site receives. `claims.sub` is the visitor's id on your site only.
 * @param {string} token
 * @param {KeyOptions & { name: string }} options
 */
export function verifyVisitPass(token, { name, ...opts }) {
  if (!name) throw new Error("name is required");
  return verifyPass(token, { ...opts, type: "visit", audience: `pol://${name}` });
}

/**
 * What the open sources say about a statement, from Olo (every sentence checked by Zeus).
 * Call it from your server with your partner key; questions are not stored by Olo.
 * Returns { covered, supported, contradicted, not_covered, sentences: [{text, label, evidence}], sources }.
 * @param {string} statement
 * @param {{ endpoint: string, key?: string, fetch?: typeof fetch }} options
 */
export async function checkClaim(statement, { endpoint, key, fetch: f = globalThis.fetch }) {
  if (!endpoint) throw new Error("endpoint is required (your Olo answer endpoint)");
  const q = String(statement || "").trim().slice(0, 400);
  if (!q) throw new Error("statement is empty");
  const r = await f(endpoint, { method: "POST", headers: { "content-type": "application/json", ...(key ? { "x-olo-key": key } : {}) }, body: JSON.stringify({ q }) });
  if (!r.ok) throw new Error(`Olo answered ${r.status}`);
  const j = await r.json();
  const summary = j.summary || { supported: 0, contradicted: 0, not_covered: 0 };
  return {
    covered: Boolean(j.covered),
    ...summary,
    sentences: (j.sentences || []).map((s) => ({ text: s.text ?? s.sentence ?? "", label: s.label ?? s.verdict ?? "not_covered", evidence: s.evidence ?? [] })),
    sources: (j.sources || []).map((s) => ({ title: s.title, url: s.url, licence: s.licence ?? s.license })),
    verifier: j.verifier ?? null,
  };
}

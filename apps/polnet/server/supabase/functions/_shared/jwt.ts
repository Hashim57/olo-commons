// ES256 member passes for POL Net. Signed with the server's private key, verifiable by anyone with the
// public key at /.well-known/jwks.json, so a pol:// site's own server can check that a visitor is a
// member without calling POL Net. Web Crypto only, no dependencies.

const enc = new TextEncoder();
const dec = new TextDecoder();

export function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64url(s: string): Uint8Array<ArrayBuffer> {
  const t = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(t + "===".slice((t.length + 3) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export type Signer = { kid: string; privateKey: CryptoKey; publicJwk: JsonWebKey & { kid: string } };

/** Loads the signing key from a private JWK (POLNET_SIGNING_JWK, made by scripts/keys.ts). */
export async function loadSigner(privateJwkJson: string): Promise<Signer> {
  const jwk = JSON.parse(privateJwkJson) as JsonWebKey & { kid?: string };
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.d) throw new Error("POLNET_SIGNING_JWK must be a private P-256 JWK");
  const privateKey = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const kid = jwk.kid ?? (await thumbprint(jwk));
  return { kid, privateKey, publicJwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, kid, alg: "ES256", use: "sig" } };
}

/** A fresh signing key, for tests and for scripts/keys.ts. */
export async function newSigningJwk(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return JSON.stringify({ ...jwk, kid: await thumbprint(jwk) });
}

async function thumbprint(jwk: JsonWebKey): Promise<string> {
  const canonical = JSON.stringify({ crv: jwk.crv, kty: jwk.kty, x: jwk.x, y: jwk.y });
  return b64url(await crypto.subtle.digest("SHA-256", enc.encode(canonical))).slice(0, 16);
}

export async function sign(signer: Signer, claims: Record<string, unknown>): Promise<string> {
  const head = b64url(enc.encode(JSON.stringify({ alg: "ES256", typ: "JWT", kid: signer.kid })));
  const body = b64url(enc.encode(JSON.stringify(claims)));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer.privateKey, enc.encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(sig)}`;
}

/** The claims of a valid, unexpired token signed by one of `keys` with the given issuer, or null. */
export async function verify(token: string, keys: JsonWebKey[], issuer: string, nowMs = Date.now()): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  let head: { alg?: string; kid?: string };
  let claims: Record<string, unknown>;
  try {
    head = JSON.parse(dec.decode(unb64url(parts[0])));
    claims = JSON.parse(dec.decode(unb64url(parts[1])));
  } catch {
    return null;
  }
  if (head.alg !== "ES256") return null;
  const jwk = keys.find((k) => (k as { kid?: string }).kid === head.kid);
  if (!jwk) return null;
  const key = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  let ok = false;
  try {
    ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, unb64url(parts[2]), enc.encode(`${parts[0]}.${parts[1]}`));
  } catch {
    return null;
  }
  if (!ok) return null;
  if (typeof claims.exp !== "number" || claims.exp * 1000 < nowMs) return null;
  if (claims.iss !== issuer) return null;
  return claims;
}

/** Constant-time comparison for shared secrets. */
export function safeEqual(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** Stripe's webhook signature: "t=...,v1=..." over `${t}.${payload}` with HMAC-SHA256. */
export async function stripeSignatureOk(payload: string, header: string, secret: string, nowMs = Date.now(), toleranceS = 300): Promise<boolean> {
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=", 2) as [string, string]));
  const t = Number(parts.t);
  const given = header.split(",").filter((p) => p.startsWith("v1=")).map((p) => p.slice(3));
  if (!Number.isFinite(t) || given.length === 0) return false;
  if (Math.abs(nowMs / 1000 - t) > toleranceS) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${payload}`)));
  const hex = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  return given.some((g) => safeEqual(g, hex));
}

# POL Net trust tools for websites

Two open tools any website can use, so the benefits of POL Net reach beyond people who use the browser for everything:

1. **A real person is here.** With the person's consent, your site learns that a verified human (one Proof-of-Life check, one account) is visiting, and gets an id for them that only your site sees. Useful for sign-ups without bots, one-person-one-vote polls, reviews that cannot be faked in bulk, and community spaces.
2. **What the sources say.** Ask Olo about a statement and get its answer from the open Olo Commons with every sentence checked by Zeus, with sources and licences.

Code: `apps/polnet/trust/polnet-trust.mjs`. One file, no dependencies, Web Crypto only. Runs on Node 18+, Deno, Bun, Cloudflare Workers and in browsers. Apache 2.0.

## 1. Real person, with consent

### The flow

1. Your server makes a nonce for the visitor's session and remembers it.
2. Your page shows a link made by `humanLink({ origin, returnTo, nonce })`. Open it in the same tab (not a new window): POL Net checks that the request came from a page on your origin.
3. In the POL Net browser the member sees "your-site.example asks if you are a real person", what you will get and what you will not, and chooses.
4. If they agree, the browser returns to `returnTo` with `#pol_human=<pass>`. The pass is in the fragment, so it is not sent to your server or logged by proxies on its own.
5. Your page reads it with `readHumanPass(location.href)` and posts it to your server.
6. Your server checks it with `verifyHumanPass(pass, { origin, nonce })`. If it returns claims, a verified person is here; `claims.sub` is their id on your site (stable for your origin, different on every other site).

```js
import { newNonce, humanLink, readHumanPass, verifyHumanPass } from "./polnet-trust.mjs";

// Server, when rendering the page:
const nonce = newNonce();              // store in the visitor's session
const link = humanLink({ origin: "https://your-site.example", returnTo: "https://your-site.example/verified", nonce });

// Browser, on /verified:
const pass = readHumanPass(location.href);
await fetch("/api/human", { method: "POST", body: JSON.stringify({ pass }) });

// Server, in /api/human:
const claims = await verifyHumanPass(pass, { origin: "https://your-site.example", nonce: session.nonce });
if (claims) markSessionHuman(session, claims.sub);
```

### What the pass is

An ES256 JWT signed by the POL Net server, checkable offline with the keys at `https://polnet.heliusnetwork.app/.well-known/jwks.json`:

| Claim | Meaning |
|---|---|
| `iss` | The POL Net server |
| `typ` | `"human"` |
| `aud` | Your origin, exactly |
| `sub` | This person's id on your origin only |
| `nonce` | The nonce you sent |
| `iat`, `exp` | Valid for five minutes |

It carries no handle, name, email, location or anything that links the person to other sites. It cannot be used against the POL Net API.

### Protections built in

- The pass goes back only to the origin that asked; the browser refuses a `returnTo` on another origin.
- The browser refuses a request that did not come from a page on that origin, so one site cannot collect verifications for another.
- The nonce binds the pass to your visitor's session; a pass taken from another session will not match.
- Five-minute lifetime, one audience, its own type.

### Honest limits

- Only people using the POL Net browser can answer. Offer it alongside your other options, never as the only way in.
- "Verified human" means a person passed Proof-of-Life once when joining POL Net. It does not prove age, identity or location, and it does not stop a real person from misbehaving. Combine it with your own moderation.
- Proof-of-Life and the POL Net server are not yet deployed (docs/POLNET.md, "Not built yet").

## 2. Visitors of a pol:// site

If your site is registered as a `pol://` name, every request from the POL Net browser carries `x-polnet-visit`. Check it with `verifyVisitPass(header, { name: "your-name" })`; `claims.sub` is the visitor's id on your site.

## 3. What the sources say

```js
import { checkClaim } from "./polnet-trust.mjs";
const r = await checkClaim("Project Gutenberg was founded in 1971", { endpoint: OLO_ANSWER_URL, key: OLO_PARTNER_KEY });
// { covered, supported, contradicted, not_covered, sentences: [{ text, label, evidence }], sources: [{ title, url, licence }] }
```

Call it from your server with a partner key (ask Helius Network); the public endpoint is rate limited and only accepts browsers on Helius Network's own sites. Olo does not store the question.

Read the result carefully: it reports what the open Olo Commons says, sentence by sentence, with the evidence quoted. "Not covered" means the Commons has nothing on it, not that the statement is false. Show your readers the sources, not just a verdict.

In the POL Net browser, members can do the same from any page: select text, right-click, "Check this claim with Olo and Zeus".

## Testing

`apps/polnet/server/tests/trust_test.ts` checks the library against passes the server signs (wrong origin, nonce, issuer, key, type, tampering and expiry are all refused). The browser's end-to-end test (`apps/polnet/browser/test/e2e.mjs`) runs the whole consent flow in the real browser and verifies the pass with this library.

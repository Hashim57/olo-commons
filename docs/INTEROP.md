# Working with the rest of the open web

POL Net and the Olo Commons should be one part of a movement, not a walled garden. This page says which open efforts we can join, what would connect them, and what is built today. Nothing listed as planned exists yet.

## Principles

- Use existing standards before inventing new ones.
- Anything a member makes or earns should be portable: they can take it elsewhere.
- Connecting to another network must never weaken POL Net's privacy promises (pairwise ids, no tracking).

## Today

| Connection | Status |
|---|---|
| Plain https | Built. pol:// sites are ordinary https origins in stage 1; any web server can host one. |
| JSON Web Keys and JWTs (RFC 7517, RFC 7519) | Built. Member, visit and human passes are ES256 JWTs; keys at `/.well-known/jwks.json`. Any language can verify them. |
| Open licences | Built. The Commons carries CC0, CC BY, CC BY-SA, public domain and Open Government Licence content with attribution on every atom. |
| OpenStreetMap | Used by pilot-town tasks (docs/PILOT_TOWN.md): mapping work goes into the open map, not a private database. |

## Planned, in order of usefulness

1. **W3C Verifiable Credentials.** Issue the "verified human" result as a Verifiable Credential (VC Data Model 2.0) with a pairwise subject, so wallets and sites that already speak VCs can accept it without our library. The JWT form stays for simple sites.
2. **ActivityPub (the Fediverse).** Let a Mastodon-compatible server mark accounts that have shown a POL Net human pass, using the trust tools; a server admin could then offer "verified people only" timelines or polls without collecting identity.
3. **AT Protocol (Bluesky).** A labeler service that labels accounts whose owners proved, with consent, that they are a POL Net verified person, using the same pairwise ids.
4. **Solid pods.** Let members keep their task history and earnings records in a pod they control, exportable to other platforms.
5. **The Public AI movement and open data stewards.** Offer the Commons and Zeus's scorecard as public infrastructure; contribute verified corrections back to the original open sources where their licences and processes allow.

## What will not change

Whatever networks POL Net connects to, a member's POL Net id is never shared; every connected service gets its own pairwise id, and nothing is shared without the member's choice each time.

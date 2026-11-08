# POL Net: the browser and members' network of WEBOCTA

POL Net is Helius Network's open-source browser and the members' network it opens. POL stands for Proof of Life: one real person, one account. This document is the design: what POL Net is for, how its protocol works in each stage, what it protects people from, how members earn, what is built today and what is not.

Code: `apps/polnet/browser` (the desktop browser, Electron), `apps/polnet/server` (the POL Net API, a Supabase Edge Function). Licence: Apache 2.0, like the rest of this repository.

## What it is for

The web people use today was built for reach, and paid for by watching people. Its flaws are well known: anyone can be anyone, so bots, fake reviews and scam pages are cheap; tracking follows people from site to site; attention is the product, so the business model rewards outrage and time wasted; and the people who create the value see almost none of it.

POL Net changes the defaults rather than adding features on top:

1. **Privacy is the default, not a setting.** No telemetry. Trackers, surveillance ads and third-party cookies are blocked on every page, tracking parameters are stripped from links, plain http is upgraded to https, and every site receives Global Privacy Control. History, settings and permissions never leave the computer. Private windows keep nothing.
2. **Safety comes before harm.** The browser warns before a lookalike page loads (fake banks, parcel and tax scams, fake crypto wallets), before a site that verified members have reported loads, and before a file that can run programs downloads. It warns; it does not silently censor.
3. **A members' network of real people.** `pol://` sites can only be opened by members, and becoming a member takes one Proof-of-Life check. There are no bots and no second accounts on it, which makes reviews, votes, marketplaces and communities worth trusting again. Each pol:// site sees each member under a different id, so sites cannot follow members between them.
4. **Paid for work, not for attention.** Organisations fund tasks that make things better (local data, accessibility audits, translation, environmental reports, fact checks for Zeus), members do them, and members are paid real money. POL Net earns a disclosed fee from the organisation, never from the member, and sells no data and no attention.
5. **Knowledge you can check.** Olo is built in: answers come with sources, every sentence is checked by Zeus, and questions asked from POL Net are private by default.

## The protocol

POL Net grows in stages, so that it is useful from the first day and never depends on a promise.

### Stage 1 (built): verified people over the existing internet

- **Identity.** A member is a Proof-of-Life subject: a pairwise identifier the Proof-of-Life service issues for POL Net alone, which links to nothing else. Joining runs one Proof-of-Life check (`/join` on the POL Net server, the gate.js widget, then `POST /v1/join`, which calls Proof-of-Life `siteverify` with POL Net's secret and requires a human with at least device-level uniqueness). The same person joining again gets the same account, whatever handle they type, and a suspended person cannot rejoin under a new handle. No email, name, phone number or IP address is stored.
- **Member pass.** The server signs an ES256 token (`typ: "member"`, 30 days) with its private key; anyone can verify it with the public keys at `/.well-known/jwks.json`. The browser keeps it encrypted with the operating system's keychain.
- **Names.** `pol://name` addresses live in the members' registry. A member registers up to five names, each pointing at a public `https://` origin (no IP literals, no private networks, no credentials in the address). Only a member pass can resolve a name; a non-member sees "Members only".
- **Visits.** When the browser opens `pol://name/path`, it asks the server for a visit pass for that name (`POST /v1/names/:name/visit`): ES256, ten minutes, `aud: "pol://name"`, `typ: "visit"`, and `sub` derived from the member and the name together, so the same member has a different id on every site and two sites cannot link their visitors. The browser fetches the page from the registered origin with the visit pass in the `x-polnet-visit` header, follows redirects only within that origin, and shows the result under the pol:// address. A site owner verifies the header with the published keys; a visit pass cannot be used against the POL Net API.
- **Takedowns by members.** Any member can report a name, a task or a site. Three reports from three different verified people suspend a name, close a task or put a site on the community safety list, pending review. Because each reporter is a verified person, the threshold cannot be reached with bots.
- **The community safety list, privately.** The browser asks whether a site is flagged by sending only the first eight hexadecimal characters of the SHA-256 of its host name; the server returns the full hashes of flagged sites with that prefix and the browser compares locally. The server never learns which site was opened.

### Stage 2 (designed, not built): peer-to-peer

The registry and the visit passes are the parts a peer-to-peer network can take over without changing what members see:

- Every member device holds a key pair; the member's Proof-of-Life subject signs a binding to it, so peers can tell a verified person's device from a bot without asking a server.
- pol:// sites become content-addressed bundles (signed by the owner's key) served by member devices and by volunteer relays, with the https origin of stage 1 kept as one more source.
- Name records move into a signed, append-only log that members' browsers replicate and check, so no single server can quietly change where a name points.
- Transport over WebRTC data channels with relays for devices behind NAT, encrypted end to end.

Stage 2 will not start until stage 1 has real members, an external security audit and a funded maintainer; the design will be published for comment first.

### Stage 3 (direction): member-to-member services

End-to-end encrypted messaging and payments between verified members, community moderation with appeals, and cooperative governance of the registry. These are listed so the design leaves room for them, not as commitments.

## Earning: how members are paid

- **Who pays.** Approved organisations (the `poster` role, granted by Helius Network after checking the organisation) post tasks with a reward per person and a number of places. A task opens to members only once it is fully funded: through Stripe Checkout, or by Helius Network marking a bank transfer or grant received. The organisation pays the rewards plus a platform fee (10% by default, `POLNET_FEE_BPS`), shown before it pays.
- **What members do.** Claim a place (72 hours to send evidence before the place is released), do the work, send evidence (text and an https link). The organisation approves or declines with a note. Approval writes the reward to the member's ledger in the same database transaction; a claim can be rewarded once only (a unique index enforces it).
- **The ledger.** Integer pence, per currency (GBP, EUR). Rows are append-only: the database refuses updates and deletes. A balance is the sum of the rows.
- **Payouts.** Stripe Connect Express: Stripe checks the member's identity and bank account on Stripe's side; POL Net stores only the connected account id. A payout debits the ledger first (serialised per member, so a balance cannot be spent twice) and reverses the debit if the Stripe transfer fails. Minimum payout £10 by default.
- **What organisations see.** The work and an anonymous claim reference, never the member's handle or identity.
- **Categories.** environment, health, education, community, accessibility, fact-checking, translation, local-data, research: work with a public benefit.

### Rules that keep it honest

- No crypto token, no points that might one day be worth something, no investment. Members are paid money for work that was done, from money that was already paid in. This keeps POL Net outside the UK cryptoasset financial promotion regime and the EU's MiCA, and avoids anything that looks like a payment for attention.
- No paying for ad views, clicks or installs. Tasks that ask for engagement fraud are taken down by reports and refused at review.
- Earnings can be taxable. The wallet says so; in the UK the £1,000 trading allowance usually covers small amounts. POL Net does not give tax advice.
- Before payouts go live: take advice on whether members doing tasks could be workers for employment law purposes (the platform is designed as a marketplace between independent organisations and independent members), on Stripe Connect's platform terms, and on the age limit (Proof-of-Life does not check age; set the Stripe Connect minimum and the join terms to 18).

## Threat model, in short

| Threat | What POL Net does |
|---|---|
| Cross-site tracking | Tracker list, third-party cookies refused, tracking parameters stripped, generic user agent, WebRTC limited to the public interface, pairwise ids on pol:// sites |
| Phishing | Lookalike detection on every navigation, community safety list by hash prefix, warnings on executable downloads |
| Bots and second accounts | Proof-of-Life at join; one subject, one member; suspended subjects cannot rejoin |
| A leaked pass | Visit passes are ten minutes, one site, and refused by the API; member passes are 30 days and refreshed on use |
| A malicious page reaching the browser | Pages run sandboxed with context isolation; only the browser's own polnet:// pages get a bridge, every call is checked against the sender's address and an allowlist of API routes; no webviews, no file:// navigation |
| A pol:// site redirecting elsewhere | Redirects followed only within the registered origin; anything else is shown as a link the member chooses to follow |
| Registry abuse | Reserved names (banks, platforms, government, Helius), five names per member, https only, no private network targets, takedown after three verified reports |
| Payout fraud | Approval and credit in one transaction, one reward per claim, serialised payouts, reversal on failure, Stripe identity checks |
| The server itself | Stores no personal data; the ledger is append-only; RLS on with no policies, so only the Edge Function's owner connection can read or write |

## Built today (November 2026)

- The desktop browser: tabs, private windows, Shields, safety warnings, permissions asked per site, the members' layer, Olo, Tasks, Wallet, Names, History, Settings. 16 unit tests and an 11-step end-to-end test that drives the real browser against the API.
- The server: join, passes, names, visits, the safety list, tasks, claims, review, the ledger, Stripe Checkout funding with a signed webhook, Stripe Connect payouts with reversal, reports and takedowns, admin routes. 18 tests, run against both the in-memory store and Postgres 16 with the migration applied twice, including a race of ten members for two places.
- CI builds the Mac app (unsigned) on every change.

## Not built yet, honestly

- POL Net is built on Chromium through Electron. That gives it the web compatibility and security updates of Chrome, and it also means it is not an independent engine.
- Stage 2 and stage 3 above. Until stage 2, pol:// sites run on ordinary https servers and the registry is one server.
- The Mac app is not signed or notarised yet (an Apple Developer ID certificate is needed); Windows and Linux packages are not published.
- No external security audit yet. Do one before payouts go live.
- Proof-of-Life itself is not yet deployed (see its DEPLOY.md), so joining does not work until it is.
- No mobile browser. iOS allows other browser engines only in the EU, and only for approved apps.

## How to say it

Short: "POL Net is a private browser for real people. It blocks tracking, warns you before scams, opens a members' network with no bots, and pays you for real work that helps."

What not to say: that POL Net replaces the internet, that it is anonymous (it is pseudonymous: one person, one id per site), that it is unhackable, that members will earn a living from it, or that it is a cryptocurrency. It is none of those.

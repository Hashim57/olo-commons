# WEBOCTA services: what is free, what is paid, what is built

WEBOCTA is the Helius system as a whole (docs/WEBOCTA.md): POL Net to get in, Olo and Zeus to know what is true, the Commons underneath, and from November 2026 a community (the Square, with HeliusTV inside it) and a set of connection services. This document is the plan for the parts that are new, the one list of what is free and what is paid, and the order of work. It is written to be checked: every price here is either the real price or says where the price comes from, and anything not built says so.

The rule for money: most of it is free, a few services are paid, and the paid ones pay for the free ones. Nothing is paid for with adverts, tracking or the sale of data.

## The list (served by the API at `GET /v1/services`, shown in the browser at `polnet://services/`)

The catalogue lives in one file, `apps/polnet/server/supabase/functions/_shared/services.ts`, so the browser and any website show the same thing. Three states: live (usable today), soon (built, waiting on a review or a deploy), planned (not built, no price shown, cannot be bought).

| Service | Free or paid | State | Price |
|---|---|---|---|
| POL Net browser, the members' network, protected mode and Family help | Free | Live | Free, open source |
| Olo | Free | Live | Free messages every day without an account |
| Olo plans | Paid | Live | Monthly plans, shown at helius-olo.io before payment |
| Olo Commons and Zeus | Free | Live | Free, open data and open source |
| The Square (community) | Free | Soon | Free for members |
| HeliusTV | Free | Soon | Free to watch and to share |
| Tasks that pay | Free | Live | Free for members; nothing taken from earnings |
| Posting tasks (organisations) | Paid | Live | Rewards plus the platform fee (10% by default) |
| Travel and data eSIMs | Paid | Planned | None until a supplier account exists |
| Private connection (VPN) | Paid | Planned | None yet |
| Cloud desktop | Paid | Planned | None yet |
| Virtual phone numbers | Paid | Planned | None yet |
| Proof-of-Life Pass | Free | Soon (in App Store review) | Free |
| "A real person" for any website | Free | Live | Free for websites |
| Proof-of-Life for businesses | Paid | Live | Plans at heliusnetwork.app/proof-of-life |
| AI-Built App Security Check | Paid | Live | US$595 fixed |
| Secure Code and API Review | Paid | Live | From £1,200 |

## Built in this change

**The Square** (`polnet://square/`, API under `/v1/square`, migration `003_polnet_square.sql`). The members' community for innovation and impact. Six topics: ideas, projects, questions, research, impact and tv. Members post (a title, up to 6,000 characters, an optional https link), comment and vote. What makes it different from an ordinary forum is the membership: one Proof-of-Life check, one account, so one vote is one person, and three reports from three different people take a post down pending review. Handles are shown; member ids never leave the server. Ten posts and sixty comments an hour per member. To check a claim in a post, a member selects the words and chooses "Check this claim with Olo and Zeus" from the menu that already exists.

**HeliusTV** is the Square's `tv` topic (`polnet://square/?topic=tv`). A HeliusTV post is a title, a few words and the https address of a video hosted elsewhere; the Watch button opens it in a POL Net tab, behind the browser's Shields. No video is stored, so there is no hosting bill and no upload to moderate, and ranking is by members' votes: there is no advertising and no feed that plays by itself. Hosting creators' videos directly comes later (below).

**The services page** (`polnet://services/`) with free shown before paid in every group, and the new-tab page cards that point to it and to the Square.

Tests: 35 API tests pass against the in-memory store and Postgres 16 with all three migrations applied twice (three new: the catalogue, the closed Square, and the Square's whole life from post to takedown and restore); 26 browser unit tests; and the 16-step end-to-end test drives the real browser through posting, the HeliusTV view, voting on and off, and the services page.

## Why the Square is shipped closed

`POLNET_SQUARE` is unset by default, and while it is, every `/v1/square` route answers "not open yet", the browser says "Opening soon" and the catalogue says "soon". This is deliberate. A place where people post to each other is a user-to-user service under the UK Online Safety Act 2023, whatever its size, and Ofcom expects two written records before it opens:

1. An illegal content risk assessment (Ofcom's four-step process, kept on file, reviewed yearly and before any significant change). https://ofcom.org.uk/online-safety/information-for-industry/guide-for-services/risk-assessments
2. A children's access assessment, due within three months of opening and repeated within twelve months if the answer is that children are not likely to use it. Proof-of-Life shows a person is real, not how old they are, so this needs a real answer. https://www.ofcom.org.uk/cy/online-safety/illegal-and-harmful-content/childrens-access-assessment-duties-under-the-online-safety-act

What the Square already has that those assessments will lean on: every author is one verified person who cannot return under a new name after suspension; reports that cannot be gamed by bots; takedown at three reports; an admin restore and remove (`POST /v1/admin/posts/ID/remove` or `/restore`); rate limits; links restricted to public https addresses. What it still needs before opening: the two assessments, a short set of community rules and a complaints address in the page, a named person who reviews takedowns, and an 18+ line in the join terms unless the children's assessment says otherwise. This is not legal advice; have someone qualified read the assessments.

To open it: `supabase secrets set POLNET_SQUARE=on` and redeploy the function.

## The connection services: what each really takes

Researched on 12 November 2026 from the suppliers' own pages. Where a supplier does not publish a price, none is given here.

**eSIMs (first to sell).** Resale through a wholesale supplier's API or hosted shop; no telecoms licence is needed to resell, and the supplier carries the network side. eSIM Access publishes no minimum order and no setup or monthly fee, starts from a US$50 prepaid balance, and offers an API, an embeddable web store and a Stripe-based white-label shop; wholesale rates are only visible inside its console after sign-up. MobiMatter asks for a US$250 wallet top-up and approval. Airalo's partner programme and eSIM Go do not publish prices. Most countries need no identity check for travel eSIMs; the supplier says where one is needed. Sources: https://esimaccess.com/docs/do-i-need-to-sign-a-contract-and-a-moq-to-kickoff/ , https://mobimatter.com/reseller-partner , https://developers.partners.airalo.com/faq-752238m0 . What Hashim does: open the supplier account, read the wholesale prices, set retail prices, and give the store's address; the catalogue then shows eSIMs as live with `POLNET_ESIM_STORE_URL`. Unknown until the account exists: the margin. Obligations to check: Ofcom's General Conditions for anyone providing an electronic communications service, consumer cancellation and refund rules for digital goods, VAT on telecoms.

**VPN (second, with care).** The cheapest credible route is WireGuard on rented servers: Hetzner lists cloud servers from 5.49 EUR a month, so three for redundancy is about 16.50 EUR a month whatever the number of users up to a few hundred. Windscribe offers a white-label API billed per active user with no published price. Mullvad has no white-label programme. Sources: https://www.hetzner.com/cloud/ , https://windscribe.com/white-label-vpn , https://mullvad.net/en/help/partnerships-and-resellers . What it costs beyond servers: every abuse complaint about those IP addresses arrives at Helius, a no-logs promise must be true in the configuration and worth an outside audit before it is advertised, and UK policy on VPNs and children was still moving in 2026. Build only after the eSIM store has paid for it.

**Cloud desktop (later).** Linux desktops in containers on one server behind Kasm Workspaces or Apache Guacamole. Kasm's free edition allows five concurrent sessions and is described as for individuals, nonprofits and testing, so its terms for commercial use must be confirmed. Windows desktops for other people need Microsoft's service-provider licensing. Open desktops attract abuse (spam, scraping, mining), so this needs Proof-of-Life membership, time limits and outbound limits from the first day. Sources: https://kasm.com/resources/features-matrix , https://rustdesk.com/pricing .

**Virtual phone numbers (last, or through a partner).** The numbers are cheap (Twilio lists UK numbers from about US$1.15 a month, Plivo from US$0.85), and the regulation is the heaviest of the four: reselling numbers makes Helius a communications provider under Ofcom's General Conditions, with customer due diligence for every number, identity and address evidence per country, questions about emergency calls, and penalties of up to 10 percent of turnover (Ofcom fined one reseller £437,500). Do not sell these until a telecoms lawyer has said how. Sources: https://www.twilio.com/en-us/sms/pricing/gb , https://www.plivo.com/virtual-phone-numbers/pricing/gb/ , https://www.ofcom.org.uk/phones-and-broadband/phone-numbers/good-practice-guide-on-sub-allocated-assigned-numbers .

**HeliusTV hosting (after the link version has an audience).** Storing and serving video costs money per minute: Cloudflare Stream lists US$5 per 1,000 minutes stored and US$1 per 1,000 minutes watched; Mux lists about US$3 and US$1 at 1080p with the first 100,000 delivery minutes a month free; Bunny Stream prices by the gigabyte and is cheaper. Sources: https://www.cloudflare.com/developer-platform/products/cloudflare-stream/ , https://www.mux.com/pricing , https://bunny.net/pricing/stream/ . Uploads also widen the Online Safety Act duties. The paid side, when it comes, is the creator's: hosting and tools for people who want their work on HeliusTV directly, never adverts on the viewer's side.

## Order of work

1. Now: the Square and HeliusTV (built, closed), the services page (built, open). Hashim: merge, run migration 003, deploy the function; write the two assessments and the community rules; then switch the Square on.
2. Next: the eSIM store. Hashim opens one supplier account (an afternoon); the store's address goes in `POLNET_ESIM_STORE_URL`. A native store page inside POL Net, with Stripe checkout and the eSIM delivered as a QR code, follows once the supplier's API and prices are in hand.
3. Then: VPN, paid for by eSIM revenue, after an abuse process and a configuration review.
4. Later: cloud desktop; HeliusTV hosting for creators; virtual numbers only with legal advice or through a licensed partner.

## What the names must not claim

The same rules as docs/WEBOCTA.md. The Square is a members' community, not "the Reddit of" anything in public copy (that is another company's mark). HeliusTV shares and ranks videos; it is not a broadcaster. "A neural network built by the people" means what docs/WEBOCTA.md says: Zeus is the neural network, and people build it through flags, reviewed feedback and hand-written examples; say that, in those words. A planned service is never described as available, and a VPN is never described as anonymous or unhackable.

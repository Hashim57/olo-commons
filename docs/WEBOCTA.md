# WEBOCTA (Web8): Helius Network's own web for impact and tech for good

WEBOCTA is the name Helius Network gives to the system that Olo, Zeus and Olo Commons form together: an Innovative Neural Network (INN) in the plain sense of the words, a network of people, sources, models and checks that gets better every day from being used, built for impact work and technology for good. "Web8" is the short form. It is a private web in the sense that it is Helius Network's own, with its own rules of evidence, not the open internet repackaged; it is public in the sense that its knowledge base and its verifier are open source and anyone may improve the code.

This document says what WEBOCTA is, what it is not, how its parts fit, and what the name must not claim.

## The one-sentence definition

A knowledge system in which every statement carries its source, its licence, its date and a verdict, and in which the people who use it teach it where it is wrong.

## What it is made of

| Part | Role | Where |
|---|---|---|
| Olo | The assistant people talk to: web, iPhone, Mac. Writes answers with cloud models and shows only what Zeus could verify by default. | helius-olo.io, the App Store apps |
| Zeus | The verifier: an open 7B model (Apache 2.0 base, open adapter) that labels every sentence supported, contradicted or not covered, with the exact words from the source. Trained in the cloud every day from reviewed feedback. | zeus/, Cloudflare Workers AI |
| Olo Commons | The open knowledge base: atoms with provenance, licence, validity dates, credibility and status, grown daily from open and authoritative sources and re-checked at those sources. | heliusnetwork.app/olo, Supabase |
| The loop | Flags from the apps, reviewed by a person, become Zeus training data; questions the Commons cannot answer become the ingester's reading list; retractions and source edits flow back in. | docs/FEEDBACK.md, docs/TRUST.md |

## Principles (the rules of evidence)

1. Nothing is asserted without a source that can be opened. A sentence Zeus cannot verify is hidden by default and labelled when shown.
2. Every fact has a time. Facts are never overwritten: a changed source supersedes the old atom, which stays as history under a permanent link.
3. Credibility is computed, published and recomputable: source prior, independent agreement, freshness, integrity. The number published is the verified count, not the raw count.
4. Models never feed themselves. Nothing written by Olo, Zeus or any model is ingested as a fact or used as a training label; only a person's reviewed judgement is.
5. The verifier is measured in public against published checkers (docs/ZEUS_SCORECARD.md), whatever the result.
6. Licences are obeyed by the system, not by goodwill: CC0, CC BY, CC BY-SA, public domain and Open Government Licence sources only; attribution and share-alike are carried on every atom.
7. People stay in charge: approval before memory is saved, explicit consent before conversations train anything, flags reviewed by a person, actions that leave the system confirmed first.

## What the name must not claim

- WEBOCTA is not a protocol, a standard or a new layer of the internet. It is Helius Network's system and the way it is run. Say "Helius Network's WEBOCTA" or "the WEBOCTA system", never "the next web".
- It is not a neural network in the technical sense. "Innovative Neural Network" is a description of a network of people, sources and models; Zeus is the only neural network in it. Technical readers will check, so the long form should appear once with that gloss and the product names should carry the weight.
- It is not "Web5". That name belongs in the public mind to a wound-down identity project and a third party's US trademark application; WEBOCTA makes no reference to it.
- It is not "Web 4.0", which is the European Commission's term for virtual worlds. If asked, say so plainly.

## Naming checklist (do before the name goes on anything public)

- [ ] Clearance searches for WEBOCTA and WEB OCTA on UKIPO, EUIPO (TMview) and USPTO (TSDR) in classes 9, 35, 38, 41 and 42, by a trademark attorney. "Octa" is a common prefix (hosting, crypto, software); the word mark may still be free as one word.
- [ ] The same searches for Olo, Olo Commons and Zeus (Zeus is crowded in software; a composite such as "Zeus by Olo" or "Olo Zeus" may be needed).
- [ ] Domain and handle checks: webocta.com / .io / .org, the social handles.
- [ ] A one-line disclaimer on the site: "WEBOCTA is a Helius Network system name. It is not affiliated with Block, TBD or the European Commission's Web 4.0 strategy."
- [ ] Decide the written form once: WEBOCTA (all capitals) in logos and headings, Webocta in running text, Web8 only as a tag line.

## How to say it

Short: "Olo answers from sources you can open, and Zeus checks every sentence. The Commons behind them grows every day and remembers when a fact was true. We call the whole thing WEBOCTA."

To funders and partners: an open, verifiable knowledge commons with a measured open verifier, aligned with the Public AI movement and W3C Verifiable Credentials, built for impact organisations that need answers they can defend.

To developers: open data (CC BY-SA compilation, each atom with its own licence), an open verifier with a public scorecard, a documented API, a feedback endpoint, and a daily training pipeline anyone can read.

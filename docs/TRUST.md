# Trust, time and provenance in Olo Commons

Since sql/002 every atom says how far to trust it, when it was true, which revision of its source it came from, and what replaced it. The number the Commons publishes is its count of **verified** atoms, not its raw count: NELL, which learned from the web for years, ended with about 3 percent of its beliefs at high confidence because growth came before precision. The Commons does it the other way round.

## Status

| Status | Meaning | Set by |
|---|---|---|
| candidate | Stored with provenance, not yet corroborated | the ingester, on insert |
| verified | Two independent sources agree (a neighbour from another source at cosine similarity 0.85 or more), or the source itself is authoritative (registry trust 90 or more: peer-reviewed papers, public-domain editions, statistics, law) | `olo_rescore_atom` |
| disputed | Two current atoms disagree on a fact that can only have one value, for overlapping validity periods | the ingester (planned) and reviewers |
| superseded | The source page changed; this row keeps the old text under a permanent link to its revision, with `valid_to` set and `superseded_by` pointing at the new atom | the re-check step of the ingester |
| retracted | The paper behind it is in the Crossref Retraction Watch data | the weekly retraction check |

Superseded and retracted atoms are kept (nothing is deleted) but never served as current: `olo_search_text`, `olo_match` and the offline snapshot leave them out; the full export carries them with their status so a builder can show history.

## Credibility (0 to 100)

`olo_credibility(trust, corroboration, published_at, observed_at, source_kind, status)`, recomputable at any time:

- starts at the source's registry trust (Wikipedia 85, arXiv and PubMed 90, Wikinews 70, OpenAlex 85, data.gov 75);
- plus 6 per independent agreeing source, at most 15;
- minus up to 20 for age, only for kinds whose facts move (encyclopedia, government, data, other): about one point per 55 days from `published_at`; papers and books keep their score;
- minus 10 when the source has not been re-read for a year;
- minus 60 if retracted, 30 if superseded, 20 if disputed.

## Time

- `valid_from`: when the fact began to hold. Filled from `published_at` for now; a Wikinews dateline or a Wikidata qualifier is better when present.
- `valid_to`: set when the atom is superseded or retracted. A current fact has none.
- `observed_at`: the last time the source still said this. Re-checks move it forward.
- Two atoms that disagree are first compared on their validity periods: different periods mean something changed, not a contradiction.

## Provenance

- `source_revision`: the Wikipedia revision id (from the REST summary), the Wikidata `lastrevid`, the arXiv version, or nothing for sources without revisions.
- `doi` and `pmid`: for the retraction check (arXiv, PubMed, OpenAlex).
- `content_hash` and `retrieved_at` as before.
- A superseded Wikipedia atom's url becomes `https://en.wikipedia.org/w/index.php?title=...&oldid=<revision>`, the permanent link to the text it quotes.

## Re-checks (the daily learning loop)

Every ingest run (every 15 minutes) re-reads up to 3 of the oldest-observed Wikipedia and Wikidata atoms at their source. Same revision or same text: `observed_at` advances. New text: the old atom is superseded and the new text stored as a new atom that links back. Over a week that is several hundred re-reads, so an edit on Wikipedia reaches the Commons within weeks without a live event stream (Edge Functions cannot hold one open).

## Safeguards

- Atoms come only from external, dated sources in the registry. Anything written by Olo, Zeus or any model is `generated = true` and never served or re-ingested (model collapse guard).
- At most 400 new atoms per source per day. A flood from one source is treated as a fault, not as knowledge.
- Curiosity gaps count at most 20 topics per address per day, and a topic drives ingestion only once a second address has asked for it or two days have passed.
- Feedback (sentence flags from the apps) is reviewed by a person before it teaches Zeus; see docs/FEEDBACK.md.

## Sources

| Source | Licence | Kind | Notes |
|---|---|---|---|
| Wikipedia (en, es) | CC BY-SA 4.0 | encyclopedia | revision ids kept; re-checked |
| Wikidata | CC0 1.0 | knowledge graph | lastrevid kept; re-checked |
| Wikinews | CC BY 2.5 | dated news | the dateline is the fact's date |
| arXiv | metadata CC0; abstract under arXiv's licence | papers | version kept; DOI when given |
| PubMed | NLM citation data public domain; abstract as published | papers | PMID and DOI kept |
| OpenAlex | CC0 1.0 metadata | papers | open-access, not retracted, with abstract; DOI kept; `OPENALEX_KEY` optional |
| Project Gutenberg, Internet Archive | public domain / per item | books, archive | unchanged |
| Data.gov | per dataset: open licence URL, or a federal dataset with no licence (U.S. Government Work, 17 U.S.C. 105) | government data | catalogue API v4 (CKAN was switched off in 2026); only public datasets; `DATAGOV_API_KEY` optional (api.data.gov, otherwise DEMO_KEY) |
| Open Library | CC0 1.0 / public domain catalogue data | books | catalogue facts only (title, authors, subjects, first year, editions), written as a plain sentence; descriptions and first sentences are never read because they are often publisher blurbs or quotes from the book; trust 70 (crowd-edited catalogue); starts disabled |
| Europe PMC | per article: CC0, CC BY or CC BY-SA only | papers | open-access subset; the licence is checked per article and NC/ND dropped; preprints and retractions left out; PMCID, PMID and DOI kept; trust 90, like PubMed; starts disabled |
| Crossref Retraction Watch | CC0 1.0 | integrity | never a source of facts; hides retracted atoms |

New sources start disabled in `olo_sources` and are enabled by a person after a run or two.

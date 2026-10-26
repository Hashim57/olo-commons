# Trust, time and provenance in Olo Commons

Since sql/002 every atom says how far to trust it, when it was true, which revision of its source it came from, and what replaced it. The number the Commons publishes is its count of **verified** atoms, not its raw count: NELL, which learned from the web for years, ended with about 3 percent of its beliefs at high confidence because growth came before precision. The Commons does it the other way round.

## Status

| Status | Meaning | Set by |
|---|---|---|
| candidate | Stored with provenance, not yet corroborated | the ingester, on insert |
| verified | Two independent sources agree (a neighbour from another source at cosine similarity 0.85 or more), or the source itself is authoritative (registry trust 90 or more: peer-reviewed papers, public-domain editions, statistics, law) | `olo_rescore_atom` |
| disputed | Two current atoms disagree on a fact that can only have one value, for overlapping validity periods | the ingester (planned) and reviewers |
| superseded | The source page changed; this row keeps the old text under a permanent link to its revision, with `valid_to` set and `superseded_by` pointing at the new atom. Also used for an old duplicate merged into its earliest copy (`duplicate_of` set; see Duplicates) | the re-check step of the ingester; `olo_merge_duplicates` |
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
- `content_hash` and `retrieved_at` as before; `norm_hash` (sql/009) for the duplicate check.
- `olo_atom_sightings`: every other source and url where the same atom was found (see Duplicates).
- A superseded Wikipedia atom's url becomes `https://en.wikipedia.org/w/index.php?title=...&oldid=<revision>`, the permanent link to the text it quotes.

## Duplicates (sql/009)

The same paper often reaches the Commons more than once: from arXiv, then PubMed, then OpenAlex. Since sql/009 the ingester stores it once and records every other place it was found. The rules are in `functions/olo-ingest/dedup.ts` and its tests.

A candidate is the same atom as one already stored when, strongest evidence first:

| Reason | Test |
|---|---|
| same_doi | the same DOI, whatever its case or written form (doi.org link, `doi:` prefix, URL encoding), and no conflicting PMID |
| same_pmid | the same PubMed id, and no conflicting DOI |
| same_text | the same title and body once case, accents, punctuation, HTML entities and whitespace are normalised (`norm_hash`) |
| near_text | the bodies share at least 90 percent of their word 3-grams (Jaccard) and the titles at least 80 percent of their words, both texts at least 25 words long |

Text matches are looked up two ways: the normalised-text hash (indexed), and the closest neighbours by embedding at cosine 0.95 or more. The embedding only decides what to compare; the decision is always made on the text, so two Wikipedia articles with similar leads but different titles stay two atoms.

What is never treated as a duplicate:

- two atoms from the same source. The url and content hash already refuse exact copies, and two pages of one source that read alike (Wikidata homonyms, arXiv versions) are different records;
- an atom whose DOI or PMID differs from the candidate's, however alike the text: a preprint and its journal version stay apart;
- a superseded atom. Re-checks are not affected at all: a changed page is always stored as the new atom its old one points to.

A duplicate is not inserted. It becomes a **sighting** of the earliest copy in `olo_atom_sightings`: its source, url, licence, identifiers, the reason and the score. Sightings are public provenance (`olo_atom_sightings(p_id)`, and the table is readable), written only by the service role.

Corroboration is kept. `olo_rescore_atom` counts distinct other sources among the strongly similar neighbours, as before, **and** among the atom's sightings. Before deduplication the second copy was stored as its own atom and counted as an agreeing neighbour; now the same source counts through its sighting, so a paper indexed by two registries is verified exactly as it was, and is served once. Note what this signal is: two registries carrying the same paper confirm the record (that the paper exists and says this), not two independent authors reaching the same finding.

If sql/009 has not been run, the ingester stores the candidate as a new atom, as it did before, rather than lose the second source.

Duplicates stored before sql/009 are reported by `select * from olo_merge_duplicates();` (service role). `olo_merge_duplicates(true)`, run by a person, merges only same DOI or same PMID pairs from different sources: the later copy keeps its row and url, becomes a sighting of the earliest one, and is marked superseded with `duplicate_of` and `superseded_by` set, so it is no longer served twice but stays in the export with its status. Nothing is deleted, and a second run finds nothing left to merge.

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
| Crossref Retraction Watch | CC0 1.0 | integrity | never a source of facts; hides retracted atoms |

New sources start disabled in `olo_sources` and are enabled by a person after a run or two.

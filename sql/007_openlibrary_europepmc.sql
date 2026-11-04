-- Open Library and Europe PMC as sources (functions/olo-ingest/openlibrary.ts and
-- europepmc.ts). Both start disabled: a person enables each one after the deployed
-- connector has been watched for a run or two
-- (update public.olo_sources set enabled = true where slug = '...').
-- Safe to run again: an existing row is left as it is.
--
-- Open Library: only catalogue facts (title, authors, subjects, first year, edition
-- count), which Open Library publishes as public domain / CC0. Work descriptions and
-- first sentences are never read: they are often publisher blurbs or quotes from
-- the book, which no editor can dedicate to the public domain.
-- Europe PMC: only open-access papers whose own licence is CC0, CC BY or CC BY-SA,
-- checked per article; NC and ND papers, preprints and retractions are dropped.

insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust, enabled) values
 ('openlibrary', 'Open Library', 'books', 'https://openlibrary.org', 'https://openlibrary.org',
  'CC0 1.0 / public domain (catalogue data only; descriptions and first sentences are not taken)',
  'https://openlibrary.org/help/faq/using',
  'Catalogue facts about books from the Internet Archive''s Open Library: title, authors, subjects, first year of publication, editions.', 70, false),
 ('europepmc', 'Europe PMC', 'papers', 'https://europepmc.org', 'https://www.ebi.ac.uk/europepmc/webservices/rest',
  'Per article; kept only when the open-access licence is CC0, CC BY or CC BY-SA',
  'https://europepmc.org/downloads/openaccess',
  'Titles and abstracts of open-access life-science papers from Europe PMC (EMBL-EBI), preprints excluded; DOI and PMID kept for the retraction check.', 90, false)
on conflict (slug) do nothing;

-- Two new sources: Europeana (cultural heritage records) and DOAJ (abstracts from
-- peer-reviewed open-access journals). Connectors: functions/olo-ingest/europeana.ts
-- and doaj.ts. Both start disabled: a person enables each after the deployed
-- connector has been watched for a run or two
-- (update public.olo_sources set enabled = true where slug = '...').
-- Europeana needs the EUROPEANA_KEY secret for a personal key (the public demo key
-- is used otherwise); DOAJ needs no key. Safe to run again.

insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust, enabled) values
 ('europeana', 'Europeana', 'archive', 'https://www.europeana.eu', 'https://api.europeana.eu/record/v2', 'Per record; only PDM, CC0, CC BY and CC BY-SA records are kept', 'https://www.europeana.eu/en/rights', 'Cultural heritage records from European museums, libraries and archives.', 80, false),
 ('doaj', 'DOAJ', 'papers', 'https://doaj.org', 'https://doaj.org/api', 'DOAJ metadata CC BY-SA 4.0; abstracts under each article''s open-access licence', 'https://doaj.org/terms/', 'Abstracts of articles in peer-reviewed, fully open-access journals listed in the Directory of Open Access Journals.', 80, false)
on conflict (slug) do nothing;

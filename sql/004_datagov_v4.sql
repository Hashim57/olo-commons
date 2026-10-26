-- Data.gov moved off CKAN in 2026: catalog.data.gov/api/3 now answers 404, so the
-- data_gov source never added an atom. olo-ingest now calls the catalogue API v4
-- (functions/olo-ingest/datagov.ts). This points the registry row at the new API
-- and records the licence rule. Safe to run again. Run in the Supabase SQL editor
-- (project bfldflbkebyapfagsxnr) after deploying olo-ingest.

update public.olo_sources
set api_base = 'https://api.gsa.gov/technology/datagov/v4',
    licence = 'Per dataset; kept only when public and under an open licence URL (CC0, CC BY, CC BY-SA, ODC, U.S. public domain, OGL), or when a federal agency publishes it without a licence (U.S. Government Work, 17 U.S.C. 105)',
    enabled = true
where slug = 'data_gov';

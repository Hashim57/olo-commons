-- Olo Commons: remove the Wikinews pages that are not news articles: the daily
-- crossword, the digests of 2004 and a writer's notes kept as a subpage.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/024.
-- Safe to run again: a delete that finds nothing the second time and a count
-- that is recomputed. Nothing here weakens SECURITY.md: no table or function
-- changes, RLS stays on, nothing becomes writable.
--
-- Why: the Wikinews connector asks the MediaWiki API for random pages of the
-- article namespace, and that namespace also holds "Crosswords/2005/February/22"
-- (whose whole text is "Feel free to use the Wikimedia sites to solve our
-- Wikinews crossword. Please do not fill it out online ... print it out and
-- fill it in at your own leisure!"), "Digest/22November2004" ("This a
-- collection of articles whose datelines read between 22 and 29 November ...
-- This is essentially an index right now") and "... gives speech on Hurricane
-- Wilma/Notes" ("Notes taken by Messedrocker for the article"). On 24 November
-- 2026 the live Commons held nine crosswords (one stored every few days since
-- 27 October), one digest and one notes page, each served as a verified
-- Wikinews atom. The ingester refuses such titles from the same date
-- (WIKINEWS_NOT_AN_ARTICLE_RE in functions/olo-ingest/sources.ts); this file
-- applies the same rule to what is already stored. A brief ("... crashes in
-- Venezuela/Brief") is a real short article and stays.

-- ---------------------------------------------------------------------------
-- 1. Look before deleting: expect 9 crosswords, 1 digest, 1 notes page.
-- ---------------------------------------------------------------------------
select case when a.title like 'Crosswords/%' then 'crossword' when a.title like 'Digest/%' then 'digest' else 'notes' end as kind, count(*)
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where s.slug = 'wikinews' and (a.title like 'Crosswords/%' or a.title like 'Digest/%' or a.title like '%/Notes')
group by 1
order by 1;

-- ---------------------------------------------------------------------------
-- 2. Delete them, from Wikinews only. Links and sightings go with the atom
--    (foreign keys with on delete cascade, sql/001 and sql/002).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'wikinews'
  and (a.title like 'Crosswords/%' or a.title like 'Digest/%' or a.title like '%/Notes');

-- ---------------------------------------------------------------------------
-- 3. Keep the per-source counts the page shows in step with the table.
-- ---------------------------------------------------------------------------
update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id);

-- Check after running: the count in step 1 is zero the second time.

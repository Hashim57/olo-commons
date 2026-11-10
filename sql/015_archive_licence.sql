-- Olo Commons: the Internet Archive connector now keeps only items under an
-- open licence, read from the Archive's licenseurl field (functions/olo-ingest/
-- licence.ts, sources.ts; issue #50). This file brings what is already stored
-- and the source registry into line with that.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/014.
-- Safe to run again: updates and deletes that find nothing the second time.
-- Nothing here weakens SECURITY.md: no table or policy changes, RLS stays on,
-- no new function.
--
-- Why: until 2026-11-10 the connector stored "See <url>" for an item with a
-- licence URL and "Public domain / as stated by the Archive" for one without,
-- which was a guess (the Archive also lends in-copyright library scans). On the
-- 2026-11-10 snapshot the 1,027 archive_org atoms carried: no licence URL 906;
-- the retired CC public domain dedication 77; CC BY 4.0 19; Public Domain Mark
-- 12; CC0 8; CC BY-SA 3.0 1; and 4 under CC BY-NC-ND 3.0 or 4.0, which the
-- Commons may not pass on under its own CC BY-SA 4.0 compilation licence.

-- ---------------------------------------------------------------------------
-- 1. How many archive_org atoms each licence line covers, before any change.
-- ---------------------------------------------------------------------------
select a.licence, count(*) as atoms
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where s.slug = 'archive_org'
group by a.licence order by atoms desc;

-- ---------------------------------------------------------------------------
-- 2. Delete the atoms under a licence that is not open (NC or ND in any CC
--    licence URL). Their links go with them (olo_links cascades on atom id);
--    the stored row is gone, nothing is marked.
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and a.licence ~* 'creativecommons\.org/licenses/by-(nc|nd|nc-nd|nc-sa)/';

-- ---------------------------------------------------------------------------
-- 3. Give the atoms kept under an open licence URL the canonical short name
--    the connector now stores, so one licence has one spelling in the Commons.
-- ---------------------------------------------------------------------------
update public.olo_atoms a set licence = 'Public Domain Mark 1.0'
from public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org' and a.licence ~* '^See https?://(www\.)?creativecommons\.org/publicdomain/mark/1\.0/?$';

update public.olo_atoms a set licence = 'CC0 1.0'
from public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org' and a.licence ~* '^See https?://(www\.)?creativecommons\.org/publicdomain/zero/1\.0/?$';

update public.olo_atoms a set licence = 'Public domain (CC Public Domain Dedication)'
from public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org' and a.licence ~* '^See https?://(www\.)?creativecommons\.org/licenses/publicdomain(/1\.0)?/?$';

update public.olo_atoms a set licence = 'CC BY ' || (regexp_match(a.licence, 'licenses/by/(\d\.\d)', 'i'))[1]
from public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org' and a.licence ~* '^See https?://(www\.)?creativecommons\.org/licenses/by/\d\.\d(/[a-z]{2}(-[a-z]+)?)?/?$';

update public.olo_atoms a set licence = 'CC BY-SA ' || (regexp_match(a.licence, 'licenses/by-sa/(\d\.\d)', 'i'))[1]
from public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org' and a.licence ~* '^See https?://(www\.)?creativecommons\.org/licenses/by-sa/\d\.\d(/[a-z]{2}(-[a-z]+)?)?/?$';

-- ---------------------------------------------------------------------------
-- 4. The registry row says what the connector now keeps.
-- ---------------------------------------------------------------------------
update public.olo_sources
set licence = 'Per item: Public Domain Mark, CC0, CC public domain dedication, CC BY or CC BY-SA only (from the item licence URL)',
    description = 'Descriptions of texts in the Archive that carry an open licence URL. Items with no licence URL, or under a non-commercial or no-derivatives licence, are never fetched.'
where slug = 'archive_org'
  and licence is distinct from 'Per item: Public Domain Mark, CC0, CC public domain dedication, CC BY or CC BY-SA only (from the item licence URL)';

-- ---------------------------------------------------------------------------
-- 5. Not done here, a decision for the maintainer (issue #50): the 906
--    archive_org atoms stored under "Public domain / as stated by the Archive"
--    have no licence URL at the Archive, so that line is a guess. Delete them
--    with the statement below, or leave them and relabel. The connector no
--    longer adds any.
--
--    delete from public.olo_atoms a using public.olo_sources s
--    where s.id = a.source_id and s.slug = 'archive_org'
--      and a.licence = 'Public domain / as stated by the Archive';
-- ---------------------------------------------------------------------------

-- 6. After: the same count as in 1.
select a.licence, count(*) as atoms
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where s.slug = 'archive_org'
group by a.licence order by atoms desc;

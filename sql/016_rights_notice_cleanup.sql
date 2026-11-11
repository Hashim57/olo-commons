-- Olo Commons: remove the archive_org atoms whose description is a rights
-- notice and nothing else.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/015.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the new function is server-only with explicit grants and revokes.
--
-- Why: since the connector asks the Internet Archive for licensed items only
-- (sql/015, functions/olo-ingest/sources.ts), a new kind of description comes
-- through that passes every rule so far: the journal scans uploaded from
-- CrossRef records all carry the one fixed line
--   "This paper is in the public domain in USA. Metadata comes from the
--    CrossRef API, see full record in the source URL below."
-- It has 19 distinct words, no link and no "Label: value" field, and it says
-- nothing about the paper. 2 archive_org atoms on the 2026-11-11 snapshot (one
-- from each of the two days since the deploy), no atom of any other source
-- matched. The ingester now refuses it (isRightsNotice inside isStub,
-- functions/olo-ingest/text.ts); this file applies the same rule to what is
-- already stored. The body is read as sql/014 reads it (olo_atom_body: the
-- longer of summary and content, a text written twice read once).

-- ---------------------------------------------------------------------------
-- 1. Rights notice, the same as isRightsNotice(): at most 60 words of two or
--    more letters, and every sentence (the body split at ". ", "! " or "? ")
--    mentions the public domain, copyright, "all rights reserved", "no known
--    restrictions", metadata, CrossRef, "source URL" or "full record".
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_rights_notice(p_summary text, p_content text)
returns boolean language sql immutable as $$
  with b as (
    select public.olo_atom_body(p_summary, p_content) as body
  ),
  sentences as (
    select btrim(s) as sentence
    from b, regexp_split_to_table(b.body, '[.!?]\s+') as s
  )
  select (select body <> '' and (select count(*) from regexp_matches(body, '[[:alpha:]]{2,}', 'g')) <= 60 from b)
     and bool_and(sentence ~* '\m(?:public domain|copyright(?:ed)?|all rights reserved|no known (?:copyright )?restrictions|metadata|crossref|source url|full record)\M')
  from sentences where sentence <> ''
$$;

revoke execute on function public.olo_is_rights_notice(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_rights_notice(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many atoms the rule finds per source. Expect
--    2, both archive_org, on the 2026-11-11 snapshot, or 3 while the sql/013
--    catalogue records are still stored (one Haryana gazette record mentions
--    copyright in its only sentence). Checked on a local Postgres 16 against
--    all 9,080 snapshot texts: no atom of any other source matched.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as rights_notices
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_rights_notice(a.summary, a.content)
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 3. Delete the archive_org atoms. Only that source, as in sql/010 to 014:
--    the rule was calibrated on the snapshot so that every atom of every other
--    source passes. Links to a deleted atom go with it (on delete cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_rights_notice(a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id) where s.slug = 'archive_org';

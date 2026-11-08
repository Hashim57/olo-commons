-- Olo Commons: remove the archive_org atoms whose description is a shelf mark
-- or only a library physical description.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/013.
-- Safe to run again: "create or replace" and deletes that find nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the two new functions are server-only with explicit grants and revokes.
--
-- Why: two more kinds of Internet Archive description pass every rule so far
-- and carry nothing a reader could check.
--   * Shelf marks: the Karnataka State Archives scans are described by their
--     place on a shelf, "Karnataka State Archives - Mysore - Gazettes -
--     Gazette-6 - HRS-Historical Record Section - R - 369 (ID 102517)" (with
--     spaced dashes), a path of short names. 76 on the 2026-11-08 snapshot,
--     about one more a day.
--   * Physical descriptions: scanned library books whose description is the
--     MARC physical description and its notes, "ix, 203 pages : 24 cm Includes
--     bibliographical references and index". 50 on the snapshot; 32 others
--     have a real summary after the measurements and are kept.
-- No atom of any other source matched either rule on the snapshot. The
-- ingester now refuses both (isShelfMark and withoutPhysicalDescription inside
-- isStub, functions/olo-ingest/text.ts); this file applies the same rules to
-- what is already stored.

-- ---------------------------------------------------------------------------
-- 1. The body the rules read: the longer of summary and content, whitespace
--    collapsed, a text written twice read once (as oncely() does).
-- ---------------------------------------------------------------------------
create or replace function public.olo_atom_body(p_summary text, p_content text)
returns text language sql immutable as $$
  with b as (
    select btrim(regexp_replace(
      case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end,
      '\s+', ' ', 'g')) as body
  ),
  h as (
    select body, (length(body) - 1) / 2 as half from b
  )
  select case when length(body) > 40 and substr(body, half + 1, 1) = ' ' and substr(body, 1, half) = substr(body, half + 2)
              then substr(body, 1, half) else body end
  from h
$$;

revoke execute on function public.olo_atom_body(text, text) from public, anon, authenticated;
grant execute on function public.olo_atom_body(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Shelf mark, the same as isShelfMark(): the body split at a spaced dash
--    (hyphen, en or em dash), a bar, a slash, a chevron or a double colon
--    gives at least 5 parts, each of at most 4 words of two or more letters.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_shelf_mark(p_summary text, p_content text)
returns boolean language sql immutable as $$
  with parts as (
    select btrim(p) as part
    from regexp_split_to_table(public.olo_atom_body(p_summary, p_content), '\s(?:[-\u2013\u2014]|\||/|>|\u00bb|::)\s') as p
  ),
  counted as (
    select part, (select count(*) from regexp_matches(part, '[[:alpha:]]{2,}', 'g')) as words
    from parts where part <> ''
  )
  select count(*) >= 5 and coalesce(max(words), 0) <= 4 from counted
$$;

revoke execute on function public.olo_is_shelf_mark(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_shelf_mark(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Physical description only, the same as withoutPhysicalDescription()
--    followed by isStub's rest check: the body starts with a pagination
--    ("ix, 203 pages", "88 p.", "1 volume (unpaged)", "1 guide (191 p.)"),
--    optional illustration notes and a height in centimetres, and once that
--    and the standard notes ("Includes bibliographical references (p. 12-15)
--    and index", "Bibliography: p. 347-375") are taken out, fewer than 40
--    characters are left. The ingester also takes the title and the authors
--    out before measuring; this function does not, so it deletes no more
--    than the ingester would refuse.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_physical_description_only(p_summary text, p_content text)
returns boolean language sql immutable as $$
  with b as (
    select public.olo_atom_body(p_summary, p_content) as body
  ),
  m as (
    select body,
      '^(?:[xivlc]+, )?(?:\d+ (?:p\.|pages?|v\.|volumes?|leaves)|volumes?|\d+ (?:volume|guide|portfolio) \((?:unpaged|\d+ p\.?)\))(?: of plates)?[^A-Za-z0-9]*(?:(?:ill\.?|illustrations|col\.|colou?r|maps?|ports?\.?|facsims?\.?|music|charts?|plates)[^A-Za-z0-9]*)*(?:\d+(?: x \d+)? cm\.?)?' as phys,
      '\mIncludes? (?:bibliographical references?|bibliography|bibliographies|index(?:es)?|discography|filmography)(?: \((?:p\.|pages?)? ?[\d, -]+\))?(?: and index(?:es)?)?\.?|\mBibliography: (?:p\.|pages?) [\d, -]+\.?' as notes
    from b
  )
  select body ~* phys
     and length(btrim(regexp_replace(regexp_replace(regexp_replace(body, phys, '', 'i'), notes, ' ', 'gi'), '\s+', ' ', 'g'))) < 40
  from m
$$;

revoke execute on function public.olo_is_physical_description_only(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_physical_description_only(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Look before deleting: how many atoms each rule finds per source. Expect
--    about 76 shelf marks and 50 physical descriptions, all archive_org
--    (checked on a local Postgres 16 against the 7,650 snapshot texts).
-- ---------------------------------------------------------------------------
select s.slug,
       count(*) filter (where public.olo_is_shelf_mark(a.summary, a.content)) as shelf_marks,
       count(*) filter (where public.olo_is_physical_description_only(a.summary, a.content)) as physical_descriptions
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
group by s.slug
having count(*) filter (where public.olo_is_shelf_mark(a.summary, a.content) or public.olo_is_physical_description_only(a.summary, a.content)) > 0
order by s.slug;

-- ---------------------------------------------------------------------------
-- 5. Delete the archive_org atoms. Only that source, as in sql/010, 012 and
--    013: the rules were calibrated on the snapshot so that every atom of
--    every other source passes. Links to a deleted atom go with it (on delete
--    cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and (public.olo_is_shelf_mark(a.summary, a.content) or public.olo_is_physical_description_only(a.summary, a.content));

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id) where s.slug = 'archive_org';

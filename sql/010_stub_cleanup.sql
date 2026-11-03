-- Olo Commons: remove the atoms that carry no knowledge (stubs).
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/009.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the one new function is server-only with explicit grants and revokes.
--
-- Why: the Internet Archive search returns many uploads whose description is
-- the identifier, a file name or one word typed twice ("new book new book",
-- "fhfh fhfh", "P P"). Before 2026-11-02 the connector took any description,
-- so a third of the archive_org atoms (330 of 892 in the 2026-11-03 snapshot)
-- are such stubs: they match nothing useful in search, they pull real atoms
-- into links with nothing, and they go into the Zeus training set as passages.
-- The ingester now refuses them (isStub in functions/olo-ingest/text.ts); this
-- file applies the same rule to what is already stored. A stub is not a fact
-- that was later found wrong (that would be status retracted or superseded,
-- kept as history), it never was one, so it is deleted; its links go with it
-- (on delete cascade) and the same item is refused if a run meets it again.

-- ---------------------------------------------------------------------------
-- 1. The rule, the same as isStub(): measured on the longer of summary and
--    content. A stub has fewer than 6 different words, or fewer than 12 with
--    under 40 percent of its words distinct (one line repeated), or says
--    nothing beyond its title (under 40 characters left once the title is
--    taken out). Words are runs of two or more letters in any script.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_stub(p_title text, p_summary text, p_content text)
returns boolean language sql immutable as $$
  with b as (
    select case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end as body
  ),
  w as (
    select lower(m[1]) as word from b, regexp_matches(b.body, '[[:alpha:]]{2,}', 'g') as m
  ),
  n as (
    select count(*) as total, count(distinct word) as distinct_words from w
  )
  select (select body from b) = ''
      or (select distinct_words < 6 or (distinct_words < 12 and distinct_words::numeric / greatest(total, 1) < 0.4) from n)
      or length(btrim(regexp_replace(
           case when length(coalesce(p_title, '')) >= 3 then replace(lower((select body from b)), lower(p_title), ' ') else lower((select body from b)) end,
           '\s+', ' ', 'g'))) < 40
$$;

revoke execute on function public.olo_is_stub(text, text, text) from public, anon, authenticated;
grant execute on function public.olo_is_stub(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many stubs each source holds right now.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as stubs
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_stub(a.title, a.summary, a.content)
group by s.slug order by stubs desc;

-- ---------------------------------------------------------------------------
-- 3. Delete the archive_org stubs. Only that source: the rule was calibrated
--    on the snapshot so that every atom of every other source passes, and the
--    count above shows whether that still holds before anything else is
--    touched. Links to a deleted atom go with it (sql/001, on delete cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_stub(a.title, a.summary, a.content);

-- Recount the source's atoms so the registry and the page agree with the table.
update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id) where s.slug = 'archive_org';

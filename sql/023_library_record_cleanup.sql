-- Olo Commons: remove the mirrored library records, Library of Congress item
-- pages copied into the Internet Archive's description field with their
-- headers in capitals.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/022.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the new function is server-only with explicit grants and revokes.
--
-- Why: on 22 November 2026 a mirror began uploading the Library of Congress
-- collection "Music for the Nation: American Sheet Music, ca. 1820-1860"
-- (some 60,000 pieces) to the Internet Archive under a public domain mark,
-- each item described by the fields of its loc.gov page: "L'Elegante valse
-- brillante MEDIUM 1 score CREATED / PUBLISHED 1843 SOURCE
-- http://www.loc.gov/item/2023798348/ Digital id: ['M1.A12 I'] CREDIT (Library
-- of Congress) Credit Line: Music Division, Library of Congress. RIGHTS The
-- Library of Congress ... collection is in the public domain and is free to
-- use and reuse. No known copyright restrictions. ... PROVENANCE (this copy)
-- Mirrored from loc.gov with no processing." The headers carry no colon, so
-- the catalogue rule (sql/013) does not see them; the rights paragraph runs
-- past 60 words, so the rights rule (sql/016) does not either; and the loc.gov
-- link leaves more than enough text behind for the pointer rule (sql/010). The
-- random walk stored 4 in two days. What such a record says beyond its title
-- (one score, a year) is in the title and the date already; the rest is the
-- collection's licence and the mirror's own provenance, which no claim is
-- checked against. The ingester refuses such a candidate from the same date
-- (isLibraryRecord in functions/olo-ingest/text.ts, counted in the run note
-- among the stubs); this file applies the same rule to what is already stored.
-- ---------------------------------------------------------------------------
-- 1. The same test as isLibraryRecord(), on the longer of summary and content
--    read once when it is written twice: at least 3 distinct headers from the
--    list, the first of them starting within the first 120 characters, and a
--    sentence about the item's legal standing (the RIGHTS_RE of sql/016).
--    Checked against all 14,517 texts of the live Commons on 23 November 2026
--    (exported through olo_export) on a local Postgres 16: the 4 archive_org
--    records match and no atom of any other source; none has even two of the
--    headers.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_library_record(p_summary text, p_content text)
returns boolean language plpgsql immutable as $$
declare
  header_re constant text := '(^|\s)(MEDIUM|CREATED / PUBLISHED|CONTRIBUTOR NAMES|SUBJECTS|NOTES|FORMAT|SOURCE|REPOSITORY|REPRODUCTION NUMBER|CALL NUMBER|DIGITAL ID|LCCN|CREDIT|RIGHTS|PROVENANCE|PART OF)(?=\s)';
  rights_re constant text := '\m(public domain|copyright(ed)?|all rights reserved|no known (copyright )?restrictions|metadata|crossref|source url|full record)\M';
  body text;
  h int;
  n_headers int;
  first_at int;
  s text;
begin
  body := case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end;
  body := btrim(regexp_replace(body, '\s+', ' ', 'g'));
  if body = '' then return false; end if;
  -- a text written twice in a row, read once
  h := (length(body) - 1) / 2;
  if length(body) > 40 and substr(body, h + 1, 1) = ' ' and left(body, h) = substr(body, h + 2) then body := left(body, h); end if;
  -- distinct headers (the regex is case sensitive: the capitals are the point)
  select count(distinct m[2]) into n_headers from regexp_matches(body, header_re, 'g') as m;
  if coalesce(n_headers, 0) < 3 then return false; end if;
  -- where the first header itself starts (subexpression 2; the match may begin with the space before it), 0-based as in text.ts
  first_at := regexp_instr(body, header_re, 1, 1, 0, '', 2) - 1;
  if first_at > 120 then return false; end if;
  -- a rights sentence somewhere
  foreach s in array regexp_split_to_array(body, '[.!?]\s+') loop
    if s ~* rights_re then return true; end if;
  end loop;
  return false;
end
$$;

revoke execute on function public.olo_is_library_record(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_library_record(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. What would go, by source. Run this first and read it: anything other than
--    archive_org means the rule is wider than it was measured to be, and the
--    delete below is limited to archive_org for that reason.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as library_records
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_library_record(a.summary, a.content)
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 3. Delete the archive_org library records (links go with them through the
--    foreign keys) and recount the source. Finds nothing the second time.
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_library_record(a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id);

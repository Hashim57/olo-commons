-- Olo Commons: remove the file records, descriptions that are the item's file
-- name in quotation marks and the names of the collections it sits in.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/018.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the new function is server-only with explicit grants and revokes.
--
-- Why: the scanning projects of Indian libraries upload to the Internet
-- Archive under CC0 with descriptions such as "SPS, SPS-Srinagar,
-- Funded-By-IKS-MoE,IKS-SPS Filename: 'Bharatiya Sangeet Ka Itihas Dr.Thakur
-- Jayadeva Singh Kolkata - Sangeet Research Academy'" or "'Shola E Khamosh By
-- Kalidas Gupta Raza Urdu Poetry Bombay 1965 - Subh E Ummid Publications',
-- Nazki Collection". The licence gate of 2026-11-10 lets them through and
-- every stub rule passes them (enough distinct words, no label, no link, no
-- shelf-mark separators, and the quoted name is longer than the title). On
-- the 2026-11-15 snapshot 8 archive_org atoms were of that kind, 6 of them
-- stored since 11 November, about a third of what the source added in those
-- days. Such a body repeats the title and names a shelf, which the URL already
-- does; there is nothing in it a claim could be checked against. The ingester
-- refuses such a candidate from the same date (isFileRecord in
-- functions/olo-ingest/text.ts, counted in the run note among the stubs);
-- this file applies the same rule to what is already stored.

-- ---------------------------------------------------------------------------
-- 1. The same test as isFileRecord(), on the longer of summary and content
--    read once when it is written twice: at least one quoted run of three or
--    more characters standing on its own, with no sentence end inside it;
--    outside the quotes no sentence end and at most six words between commas;
--    and either the quotes hold half the body or a "Filename:" field names
--    them. Checked against all 11,003 texts of the 2026-11-15 snapshot on a
--    local Postgres 16: 8 archive_org atoms match and no atom of any other
--    source.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_file_record(p_summary text, p_content text)
returns boolean language plpgsql immutable as $$
declare
  quote_re constant text := '(^|[[:space:],;:(])(''[^'']{3,}?''|"[^"]{3,}?"|‘[^’]{3,}?’|“[^”]{3,}?”)(?=$|[[:space:],;:.)])';
  body text;
  h int;
  m text[];
  quoted_length int := 0;
  quoted_runs int := 0;
  rest text;
  tag text;
begin
  body := case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end;
  body := btrim(regexp_replace(body, '\s+', ' ', 'g'));
  if body = '' then return false; end if;
  -- a text written twice in a row, read once
  h := (length(body) - 1) / 2;
  if length(body) > 40 and substr(body, h + 1, 1) = ' ' and left(body, h) = substr(body, h + 2) then body := left(body, h); end if;
  for m in select regexp_matches(body, quote_re, 'g') loop
    quoted_runs := quoted_runs + 1;
    quoted_length := quoted_length + length(m[2]);
    -- a sentence inside the quotation marks is a quotation, not a file name
    if substr(m[2], 2, length(m[2]) - 2) ~ '[.!?](\s|$)' then return false; end if;
  end loop;
  if quoted_runs = 0 then return false; end if;
  rest := regexp_replace(regexp_replace(body, quote_re, '\1 ', 'g'), '\mfile ?name\s*:', ' ', 'gi');
  if rest ~ '[.!?](\s|$)' then return false; end if;
  foreach tag in array regexp_split_to_array(rest, '[,;]') loop
    if (select count(*) from regexp_matches(tag, '[[:alpha:]]{2,}', 'g')) > 6 then return false; end if;
  end loop;
  return quoted_length * 2 >= length(body) or body ~* '\mfile ?name\s*:';
end
$$;

revoke execute on function public.olo_is_file_record(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_file_record(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many atoms the rule finds per source. Expect
--    8 archive_org and nothing else on the 2026-11-15 snapshot.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as file_records
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_file_record(a.summary, a.content)
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 3. Delete them, from the source the rule was calibrated on. Links and
--    sightings of a deleted atom go with it (on delete cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_file_record(a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id);

-- Olo Commons: remove the archive_org atoms whose description is an uploader notice.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/010.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the one new function is server-only with explicit grants and revokes.
--
-- Why: some Internet Archive uploaders put a notice in the description field
-- instead of describing the item: "for details please visit ketabpedia.com"
-- (stored 21 times under different items), the same line with a contact email
-- address, "Raw Scan images of a Canister of the Sim Collection: https://...".
-- On the 2026-11-05 snapshot 55 archive_org atoms were of that kind and no atom
-- of any other source matched. They carry no knowledge, some carry third-party
-- email addresses, and they reach the Zeus training set as passages. The
-- ingester now refuses them (isLinkNotice inside isStub, functions/olo-ingest/
-- text.ts); this file applies the same rule to what is already stored.

-- ---------------------------------------------------------------------------
-- 1. The rule, the same as isLinkNotice(): measured on the longer of summary
--    and content. The body holds a link, an email address or a bare domain,
--    and once those are taken out (and a text written twice is read once)
--    fewer than 160 characters are left.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_link_notice(p_summary text, p_content text)
returns boolean language sql immutable as $$
  with b as (
    select btrim(regexp_replace(
      case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end,
      '\s+', ' ', 'g')) as body
  ),
  l as (
    select '(https?://\S+|www\.\S+|[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+|\y[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.(com|org|net|info|ir|io|co|edu|gov|me|tk|ru|de|uk)\y(/\S*)?)' as re
  ),
  r as (
    select b.body, btrim(regexp_replace(regexp_replace(b.body, l.re, ' ', 'g'), '\s+', ' ', 'g')) as rest, l.re
    from b, l
  ),
  h as (
    select body, rest, re, (length(rest) - 1) / 2 as half from r
  )
  select body ~ re
     and length(case when length(rest) > 20 and substr(rest, half + 1, 1) = ' ' and substr(rest, 1, half) = substr(rest, half + 2)
                     then substr(rest, 1, half) else rest end) < 160
  from h
$$;

revoke execute on function public.olo_is_link_notice(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_link_notice(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many notices each source holds right now.
--    Expect about 55, all archive_org.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as notices
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_link_notice(a.summary, a.content)
group by s.slug order by notices desc;

-- ---------------------------------------------------------------------------
-- 3. Delete the archive_org notices. Only that source, as in sql/010: the
--    rule was calibrated on the snapshot so that every atom of every other
--    source passes. Links to a deleted atom go with it (on delete cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_link_notice(a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id) where s.slug = 'archive_org';

-- Olo Commons: remove the archive_org atoms whose description is a catalogue record.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/012.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the one new function is server-only with explicit grants and revokes.
--
-- Why: the Internet Archive holds library and government metadata records whose
-- description field is the record itself, a list of "Label: value" fields with
-- almost no words between the labels: Delpher newspaper issues ("Title:
-- Algemeen Handelsblad Datum: 22-05-1861 Editie: Dag Plaats van uitgave:
-- Amsterdam Uitgever: P. den Hengst en Zoon Verspreidingsgebied: Landelijk
-- Nummer: 120", stored once per issue, 330 of them) and Indian gazettes
-- ("Gazette Type: Extraordinary Date: 2022-05-26 Department: Home Election
-- Department Subject: ..."). On the 2026-11-07 snapshot 365 of the 999
-- archive_org atoms were of that kind, about 14 more arriving a day, and no
-- atom of any other source matched. They carry nothing a reader could check
-- beyond the title and the date, and they reach the Zeus training set as
-- passages. The ingester now refuses them (isCatalogueRecord inside isStub,
-- functions/olo-ingest/text.ts); this file applies the same rule to what is
-- already stored.

-- ---------------------------------------------------------------------------
-- 1. The rule, the same as isCatalogueRecord(): measured on the longer of
--    summary and content, a text written twice read once. At least 3 labels
--    (a capitalised word, up to three more words, a colon and a space) and at
--    most 5 words of two or more letters per label. Postgres counts letters
--    with [[:alpha:]], which splits Devanagari at its combining marks where
--    the ingester's \p{L}\p{M} count does not, so a record whose values are
--    in an Indic script can stay here (one of 365 on the snapshot did); the
--    ingester refuses it going forward.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_catalogue_record(p_summary text, p_content text)
returns boolean language sql immutable as $$
  with b as (
    select btrim(regexp_replace(
      case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end,
      '\s+', ' ', 'g')) as body
  ),
  h as (
    select body, (length(body) - 1) / 2 as half from b
  ),
  o as (
    select case when length(body) > 40 and substr(body, half + 1, 1) = ' ' and substr(body, 1, half) = substr(body, half + 2)
                then substr(body, 1, half) else body end as body
    from h
  ),
  c as (
    select
      (select count(*) from regexp_matches(o.body, '(^|\s)([A-Z][\w''’.-]*( ([a-z]+|[A-Z][\w''’.-]*)){0,3}): (?=\S)', 'g')) as labels,
      (select count(*) from regexp_matches(o.body, '[[:alpha:]]{2,}', 'g')) as words
    from o
  )
  select labels >= 3 and words <= 5 * labels from c
$$;

revoke execute on function public.olo_is_catalogue_record(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_catalogue_record(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many records each source holds right now.
--    Expect about 364, all archive_org (checked on a local Postgres 16 against
--    the 7,149 snapshot texts: 364 archive_org, no other source).
-- ---------------------------------------------------------------------------
select s.slug, count(*) as records
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_catalogue_record(a.summary, a.content)
group by s.slug order by records desc;

-- ---------------------------------------------------------------------------
-- 3. Delete the archive_org records. Only that source, as in sql/010 and
--    sql/012: the rule was calibrated on the snapshot so that every atom of
--    every other source passes. Links to a deleted atom go with it (on delete
--    cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_catalogue_record(a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id) where s.slug = 'archive_org';

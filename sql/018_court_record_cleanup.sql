-- Olo Commons: remove the court records, scanned court orders that name private
-- people as parties and accused.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/017.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the new function is server-only with explicit grants and revokes.
--
-- Why: the Commons stores no personal data (README, "Adding a source"). The
-- Internet Archive mirrors the Indian High Court judgments corpus (identifiers
-- india.highcourt.judgement.*) as scanned orders whose description is the OCR
-- of the first page: "HIGH COURT OF JUDICATURE AT PATNA Cr.Misc. No.25012 of
-- 2008 <name> Versus THE STATE OF BIHAR ... This petitioner <name> is a named
-- accused person in a case which has been registered under Section". They are
-- uploaded under CC BY 4.0, so the licence gate of 2026-11-10 lets them
-- through: 78 were stored by the 2026-11-14 snapshot, 20 of them on 13
-- November alone, two thirds of what the source added that day. A court order
-- names private people with their parentage and village, and what it states
-- is a ruling about them, not a fact about the world a claim could be checked
-- against. The ingester refuses such a candidate from the same date
-- (isCourtRecord in functions/olo-ingest/text.ts, three signs required: a
-- court, a case and the parties; and the mirror's identifiers outright in
-- sources.ts, counted in the run note as "court records skipped"); this file
-- applies the same rule to what is already stored, plus the mirror's URL
-- prefix for the three orders whose OCR is too broken for the rule to read.

-- ---------------------------------------------------------------------------
-- 1. The same test as isCourtRecord(): a court named in the title or the body,
--    a case and the parties, all three in the body (the longer of summary and
--    content). Checked against all 10,549 texts of the 2026-11-14 snapshot on
--    a local Postgres 16: 75 archive_org atoms match, all of them orders of
--    the mirror, and no atom of any other source.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_court_record(p_title text, p_summary text, p_content text)
returns boolean language sql immutable as $$
  with b as (
    select case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end as body
  )
  select body <> ''
     and (coalesce(p_title, '') || ' ' || body) ~* '\y(high court|supreme court|court of judicature|district court|sessions? court|court of appeals?|tribunal|chief judicial magistrate|court of [a-z]+( and [a-z]+)? at [a-z]+|(mr\.?|mrs\.?|smt\.?|sri|dr\.?|the hon[’'']?ble( mr\.?| mrs\.?| sri| dr\.?)?) justice)\y'
     and body ~* '\y(writ petition|criminal (appeal|revision|misc)|civil (appeal|writ|revision|misc)|special appeal|revision petition|misc\.? petition|cr\.? ?misc\.?|crl\.? ?m(isc)?\.?|w\.? ?p\.? ?(no|nos)|(no|nos)\.?\s*:?\s*\d+([-/]\w+)?\s*(/|of)\s*(19|20)?\d{2}(\d{2})?)\y'
     and body ~* '\y(versus|vs?\.)\s|\y(petitioner|respondent|appellant|applicant|accused|coram|between)s?\y|\yhon[’'']?ble\y|\ylearned counsel\y|\y[swdr]/o\y'
  from b
$$;

revoke execute on function public.olo_is_court_record(text, text, text) from public, anon, authenticated;
grant execute on function public.olo_is_court_record(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many atoms the rule and the mirror's URL prefix
--    find per source. Expect 78 archive_org (75 by the rule, 3 more by the
--    prefix) and nothing else on the 2026-11-14 snapshot.
-- ---------------------------------------------------------------------------
select s.slug,
       count(*) filter (where public.olo_is_court_record(a.title, a.summary, a.content)) as by_rule,
       count(*) as court_records
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_court_record(a.title, a.summary, a.content)
   or a.url like 'https://archive.org/details/india.highcourt.judgement.%'
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 3. Delete them, from every source: like the email rule (sql/017) this is the
--    no-personal-data rule, not a quality judgement calibrated per source.
--    Links and sightings of a deleted atom go with it (on delete cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
where public.olo_is_court_record(a.title, a.summary, a.content)
   or a.url like 'https://archive.org/details/india.highcourt.judgement.%';

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id);

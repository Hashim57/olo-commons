-- Olo Commons: remove the atoms whose title, summary or content carries an
-- email address.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/016.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the new function is server-only with explicit grants and revokes.
--
-- Why: the Commons stores no personal data (README, "Adding a source"), and
-- an email address in a description is almost always a person's. On the
-- 2026-11-12 snapshot 35 atoms carried one: 34 archive_org (an uploader's
-- "Anyone who can identify the subject in this photograph is encouraged to
-- contact me at ...@example.com", a book scanner's contact line repeated under
-- many items, one item whose title is the address itself) and 1 openalex (a
-- repository's take-down notice stored in place of the abstract, "please
-- contact repository@lists.example.ac.uk"). None of them is a fact about the item.
-- The ingester refuses such a candidate from the same date (hasEmailAddress,
-- functions/olo-ingest/text.ts, counted in the run note as "with an email
-- address skipped"); this file applies the same rule to what is already
-- stored. The "@" used as an alias mark in Indian court records ("RAM KUMAR
-- @ RAMU") and in "pass@1" does not match, so those atoms stay.

-- ---------------------------------------------------------------------------
-- 1. The same test as hasEmailAddress(): an address anywhere in the title,
--    the summary or the content.
-- ---------------------------------------------------------------------------
create or replace function public.olo_has_email_address(p_title text, p_summary text, p_content text)
returns boolean language sql immutable as $$
  select coalesce(p_title, '') || ' ' || coalesce(p_summary, '') || ' ' || coalesce(p_content, '')
         ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
$$;

revoke execute on function public.olo_has_email_address(text, text, text) from public, anon, authenticated;
grant execute on function public.olo_has_email_address(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many atoms the rule finds per source. Expect
--    34 archive_org and 1 openalex on the 2026-11-12 snapshot, checked
--    against all 9,455 snapshot texts with the same expression.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as with_email_address
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_has_email_address(a.title, a.summary, a.content)
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 3. Delete them, from every source: unlike the stub rules, this one is not
--    a judgement about quality that was calibrated per source, it is the
--    no-personal-data rule, and an address is an address wherever it sits.
--    Links to a deleted atom go with it (on delete cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
where public.olo_has_email_address(a.title, a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id);

-- Olo Commons: remove the item records, descriptions of a scanned object as
-- an object: its dimensions and weight, its copyright status, the uploader's
-- dedication of his own work to the public domain or the digitiser's credit.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/019.
-- Safe to run again: "create or replace" and a delete that finds nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the new function is server-only with explicit grants and revokes.
--
-- Why: one uploader to the Internet Archive puts his own papers and
-- belongings online under CC0 or a public domain mark, each described by what
-- it is, its size and weight, its copyright status and his dedication: "This
-- is a Baptismal Certificate issued in the Immaculate Conception Church,
-- Astoria, New York, Form No. 314, dated 5 October, 1952, for ... No copyright
-- notice evident, Public Domain under Rule 5 of the United States Copyright
-- Statutes", "Gaylord Library Card number 55; 13 August 1982. Dimensions:
-- 2 7/8" width by 4 7/8" height; weight 1.9 grams. E text created by ...",
-- "This is a Poem written by ...; 19 February 2000. This work was created by
-- ... and is in the Public Domain under the Creative Commons License". The
-- licence gate of 2026-11-10 lets them through and every stub rule passes
-- them (a real sentence, enough distinct words, no label, no link, no quotes).
-- On the 2026-11-16 snapshot 57 archive_org atoms were of that kind, 54 of
-- them stored since 10 November, about seven a day, a quarter to a third of
-- what the source added. Among them are a baptismal certificate, a home
-- inspection report with a street address, class rosters and teaching
-- records, which name private people (the Commons stores no personal data,
-- README "Adding a source"), and the rest give the size and weight of a
-- hubcap, an ashtray or a warranty card, which no claim is checked against.
-- The ingester refuses such a candidate from the same date (isItemRecord in
-- functions/olo-ingest/text.ts, counted in the run note among the stubs);
-- this file applies the same rule to what is already stored.

-- ---------------------------------------------------------------------------
-- 1. The same test as isItemRecord(), on the longer of summary and content
--    read once when it is written twice: the copyright-status boilerplate, or
--    the dedication, or the digitiser's credit, or a dimensions clause
--    together with a weight. A dimensions clause alone is kept (a paper
--    measures proteins, a news story gives a display's size in inches).
--    Checked against all 11,417 texts of the 2026-11-16 snapshot on a local
--    Postgres 16: 57 archive_org atoms match and no atom of any other source.
-- ---------------------------------------------------------------------------
create or replace function public.olo_is_item_record(p_summary text, p_content text)
returns boolean language plpgsql immutable as $$
declare
  dimensions_re constant text := '\mdimensions?\M([^.;]|\.\d){0,80}\m(width|height|length|diameter|thickness)\M|\d\s*("|''''|”|inch(es)?|in\.|millimet(er|re)s?|mm|cm)\s*(in\s+)?(width|height|length|diameter|thickness)\M';
  weight_re constant text := '\m(weight|weighs|weighing)\M([^.;]|\.\d){0,40}\m(grams?|g|ounces?|oz|kilograms?|kg|pounds?|lbs?)\M';
  copyright_re constant text := '\mno copyright (notice|registration)( or (notice|registration))?\M[^.;,]{0,20}\m(evident|found|filed|on file|appears|appeared|located)\M|\mrule 5 of the (united states|u\.?s\.?) copyright\M';
  dedication_re constant text := '\m(created|digiti[sz]ed|scanned|written|photographed|uploaded|e[- ]?text created) by [A-Z][\w.''’-]+( [A-Z][\w.''’-]+){1,3}\M[^.]{0,40}\m(and (is|are|was|released|placed|dedicated)|released)\M[^.]{0,60}\mpublic domain\M|\mreleased (into|to|in) the public domain by [A-Z][\w.''’-]+( [A-Z][\w.''’-]+){1,3}\M';
  etext_re constant text := '\me[- ]?text created by [A-Z]';
  body text;
  h int;
begin
  body := case when length(coalesce(p_content, '')) >= length(coalesce(p_summary, '')) then coalesce(p_content, '') else coalesce(p_summary, '') end;
  body := btrim(regexp_replace(body, '\s+', ' ', 'g'));
  if body = '' then return false; end if;
  -- a text written twice in a row, read once
  h := (length(body) - 1) / 2;
  if length(body) > 40 and substr(body, h + 1, 1) = ' ' and left(body, h) = substr(body, h + 2) then body := left(body, h); end if;
  return body ~* copyright_re
      or body ~* dedication_re
      or body ~* etext_re
      or (body ~* dimensions_re and body ~* weight_re);
end
$$;

revoke execute on function public.olo_is_item_record(text, text) from public, anon, authenticated;
grant execute on function public.olo_is_item_record(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before deleting: how many atoms the rule finds per source. Expect
--    57 archive_org and nothing else on the 2026-11-16 snapshot.
-- ---------------------------------------------------------------------------
select s.slug, count(*) as item_records
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where public.olo_is_item_record(a.summary, a.content)
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 3. Delete them, from the source the rule was calibrated on. Links and
--    sightings of a deleted atom go with it (on delete cascade).
-- ---------------------------------------------------------------------------
delete from public.olo_atoms a
using public.olo_sources s
where s.id = a.source_id and s.slug = 'archive_org'
  and public.olo_is_item_record(a.summary, a.content);

update public.olo_sources s set atoms = (select count(*) from public.olo_atoms a where a.source_id = s.id);

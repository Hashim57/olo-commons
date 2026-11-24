-- Olo Commons: sentences the verifier doubted become review candidates (issue #76, part 4, last box).
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/022.
-- Safe to run again: "add column if not exists", a guarded constraint, "create
-- or replace", and an insert that finds its duplicate the second time. Nothing
-- here weakens SECURITY.md: olo_feedback keeps RLS on with no policy, anon and
-- authenticated still read nothing but the counts in olo_feedback_stats, only
-- service_role writes, through olo_review_candidate, which olo-answer calls with
-- the service key; every function has explicit revokes and grants.
--
-- Why: every sentence olo-answer writes goes through Zeus (docs/RELIABILITY.md).
-- A sentence Zeus called contradicted or not covered is either a wrong answer
-- the Commons should not have given or a wrong verdict Zeus should learn from;
-- either way a person should look at it. People can already flag sentences
-- (olo-feedback, sql/002, docs/FEEDBACK.md) and accepted flags become Zeus gold
-- through zeus/feedback_to_gold.py. This file lets the verifier put its own
-- doubts into the same queue, marked as its own, so Olo's real traffic teaches
-- Zeus without anyone having to be in the app at the right moment. Nothing
-- becomes a label until a person sets status = accepted and verdict_user; a
-- candidate on its own trains nothing (feedback_to_gold.py skips 'unclear').
--
-- What is stored per candidate: the sentence, the verdict given, which verifier
-- gave it, and the passages it was checked against (atom ids, urls, the quoted
-- evidence). Never the question, never an address. At most three a response
-- (the function in olo-answer), at most 40 a day (this file), one row per
-- sentence in seven days; a burst of traffic cannot fill the table.

-- ---------------------------------------------------------------------------
-- 1. Where a flag came from: a person (every row so far) or the verifier.
-- ---------------------------------------------------------------------------
alter table public.olo_feedback add column if not exists origin text not null default 'person';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'olo_feedback_origin_check') then
    alter table public.olo_feedback add constraint olo_feedback_origin_check check (origin in ('person', 'verifier'));
  end if;
end $$;

create index if not exists olo_feedback_origin_at on public.olo_feedback (origin, at desc);

-- ---------------------------------------------------------------------------
-- 2. Record one candidate. Called by olo-answer (service role) for a sentence
--    a served Zeus adapter called contradicted or not covered. Returns the new
--    row's id, or null when nothing was stored: a claim outside the table's own
--    length rule, a verdict that is not a doubt, the same sentence seen in the
--    last seven days (any origin), or the day's cap of 40 already reached.
-- ---------------------------------------------------------------------------
create or replace function public.olo_review_candidate(
  p_claim text, p_verdict text, p_passages jsonb default '[]'::jsonb, p_checked_by text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_claim text := regexp_replace(coalesce(p_claim, ''), '\s+', ' ', 'g');
  new_id uuid;
begin
  v_claim := btrim(v_claim);
  if length(v_claim) < 3 or length(v_claim) > 600 then return null; end if;
  if p_verdict not in ('contradicted', 'not_covered') then return null; end if;
  if jsonb_typeof(coalesce(p_passages, '[]'::jsonb)) <> 'array' then return null; end if;
  if exists (select 1 from public.olo_feedback f where f.claim = v_claim and f.at > now() - interval '7 days') then return null; end if;
  if (select count(*) from public.olo_feedback f where f.origin = 'verifier' and f.at > date_trunc('day', now())) >= 40 then return null; end if;
  insert into public.olo_feedback (client, answer_source, claim, verdict_given, verdict_user, passages, note, origin)
  values ('commons', 'olo', v_claim, p_verdict, 'unclear',
          (select coalesce(jsonb_agg(p), '[]'::jsonb) from (select value as p from jsonb_array_elements(coalesce(p_passages, '[]'::jsonb)) limit 12) s),
          left('Review candidate: ' || coalesce(nullif(p_checked_by, ''), 'the verifier') || ' called this sentence ' || replace(p_verdict, '_', ' ') || '. Set verdict_user and status when reviewed.', 500),
          'verifier')
  returning id into new_id;
  return new_id;
end $$;

revoke execute on function public.olo_review_candidate(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.olo_review_candidate(text, text, jsonb, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. The public counts gain the queue of the verifier's own doubts, so the page
--    and the weekly report can say how many wait for a person. Same signature
--    as sql/002, so the grants stay.
-- ---------------------------------------------------------------------------
create or replace function public.olo_feedback_stats() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'total', (select count(*) from public.olo_feedback),
    'new', (select count(*) from public.olo_feedback where status = 'new'),
    'accepted', (select count(*) from public.olo_feedback where status = 'accepted'),
    'rejected', (select count(*) from public.olo_feedback where status = 'rejected'),
    'taught', (select count(*) from public.olo_feedback where used_in is not null),
    'last_7d', (select count(*) from public.olo_feedback where at > now() - interval '7 days'),
    'disagreement_rate_30d', (select round(100.0 * count(*) filter (where verdict_user <> verdict_given and verdict_user in ('supported','contradicted','not_covered')) / greatest(count(*), 1), 1) from public.olo_feedback where at > now() - interval '30 days' and origin = 'person'),
    'from_people', (select count(*) from public.olo_feedback where origin = 'person'),
    'from_verifier', (select count(*) from public.olo_feedback where origin = 'verifier'),
    'candidates_waiting', (select count(*) from public.olo_feedback where origin = 'verifier' and status = 'new'),
    'candidates_7d', (select count(*) from public.olo_feedback where origin = 'verifier' and at > now() - interval '7 days')
  );
$$;
revoke execute on function public.olo_feedback_stats() from public;
grant execute on function public.olo_feedback_stats() to anon, authenticated, service_role;

-- Check after running:
--   select origin, status, count(*) from public.olo_feedback group by 1, 2;
--   select public.olo_feedback_stats();

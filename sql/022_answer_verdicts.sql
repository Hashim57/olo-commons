-- Olo Commons: a daily tally of what the verifier said about Olo's answers (issue #76, part 4).
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/021.
-- Safe to run again: "create table if not exists", "create or replace", and
-- the record function only adds to counters. Nothing here weakens SECURITY.md:
-- RLS is on for the new table and no policy is created, so clients read it
-- only through the bounded olo_answer_stats function; only service_role
-- writes, through olo_answer_record, which olo-answer calls with the service
-- key after each answer; every function has explicit revokes and grants.
--
-- Why: every sentence olo-answer writes goes through Zeus (docs/RELIABILITY.md),
-- and the response says what Zeus found, but nothing kept the verdicts, so the
-- share of sentences Zeus supported in real use could only be asserted. This
-- table keeps counts per day and nothing else: no question text, no address
-- hash, no answer text. One row a day, so a year is 365 rows.
--
-- Columns, per UTC day:
--   answers           answers returned (written, written by the fallback, or extractive)
--   uncovered         of which "The Commons does not cover this yet" (no passages, or the writer said so)
--   abstained         of which nothing was shown (no sentence supported, or uncovered)
--   extractive        of which no writer could be reached and the passages' own sentences were returned
--   sentences         sentences in the drafts (extractive answers count their quoted sentences)
--   supported, contradicted, not_covered    the verdict of each sentence after the figure check
--   zeus_checked      sentences a served Zeus adapter checked
--   zeus_supported    of which Zeus called supported and the figure check let stand
--   fallback_checked  sentences the writer checked with the Zeus prompt (verifier "llm-fallback")
--   unchecked         sentences no verifier answered for, plus the quoted sentences of extractive answers

create table if not exists public.olo_answer_daily (
  day date primary key,
  answers int not null default 0,
  uncovered int not null default 0,
  abstained int not null default 0,
  extractive int not null default 0,
  sentences int not null default 0,
  supported int not null default 0,
  contradicted int not null default 0,
  not_covered int not null default 0,
  zeus_checked int not null default 0,
  zeus_supported int not null default 0,
  fallback_checked int not null default 0,
  unchecked int not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.olo_answer_daily enable row level security;
revoke all on public.olo_answer_daily from public, anon, authenticated;
grant select, insert, update, delete on public.olo_answer_daily to service_role;

-- ---------------------------------------------------------------------------
-- 1. Record one answer. Called by olo-answer (service role) once per response.
--    Every count is clamped to what one answer can hold (at most 12 sentences,
--    MAX_SENTENCES in the function is 4) so a bug cannot inflate a day.
-- ---------------------------------------------------------------------------
create or replace function public.olo_answer_record(
  p_covered boolean, p_abstained boolean, p_extractive boolean,
  p_supported int, p_contradicted int, p_not_covered int,
  p_zeus int, p_fallback int, p_unchecked int, p_zeus_supported int default 0
) returns void language plpgsql security definer set search_path = public as $$
declare
  s int := least(greatest(coalesce(p_supported, 0), 0), 12);
  c int := least(greatest(coalesce(p_contradicted, 0), 0), 12);
  n int := least(greatest(coalesce(p_not_covered, 0), 0), 12);
  z int := least(greatest(coalesce(p_zeus, 0), 0), 12);
  zs int := least(greatest(coalesce(p_zeus_supported, 0), 0), 12);
  f int := least(greatest(coalesce(p_fallback, 0), 0), 12);
  u int := least(greatest(coalesce(p_unchecked, 0), 0), 12);
begin
  insert into public.olo_answer_daily (day, answers, uncovered, abstained, extractive, sentences, supported, contradicted, not_covered, zeus_checked, zeus_supported, fallback_checked, unchecked)
  values (current_date, 1,
    case when coalesce(p_covered, true) then 0 else 1 end,
    case when coalesce(p_abstained, false) then 1 else 0 end,
    case when coalesce(p_extractive, false) then 1 else 0 end,
    s + c + n, s, c, n, z, zs, f, u)
  on conflict (day) do update set
    answers = public.olo_answer_daily.answers + 1,
    uncovered = public.olo_answer_daily.uncovered + excluded.uncovered,
    abstained = public.olo_answer_daily.abstained + excluded.abstained,
    extractive = public.olo_answer_daily.extractive + excluded.extractive,
    sentences = public.olo_answer_daily.sentences + excluded.sentences,
    supported = public.olo_answer_daily.supported + excluded.supported,
    contradicted = public.olo_answer_daily.contradicted + excluded.contradicted,
    not_covered = public.olo_answer_daily.not_covered + excluded.not_covered,
    zeus_checked = public.olo_answer_daily.zeus_checked + excluded.zeus_checked,
    zeus_supported = public.olo_answer_daily.zeus_supported + excluded.zeus_supported,
    fallback_checked = public.olo_answer_daily.fallback_checked + excluded.fallback_checked,
    unchecked = public.olo_answer_daily.unchecked + excluded.unchecked,
    updated_at = now();
end $$;

revoke execute on function public.olo_answer_record(boolean, boolean, boolean, int, int, int, int, int, int, int) from public, anon, authenticated;
grant execute on function public.olo_answer_record(boolean, boolean, boolean, int, int, int, int, int, int, int) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Read the tally: the last p_days days (1 to 365, default 28), newest first,
--    with totals over the same window and the shares that matter: of the
--    sentences Zeus itself checked, how many it supported; of the answers, how
--    many were shown at all. Shares are null until there is something to divide.
--    share_zeus_supported is the number issue #76 asks for: of the sentences
--    Zeus checked, the share it supported.
-- ---------------------------------------------------------------------------
create or replace function public.olo_answer_stats(p_days int default 28) returns json language sql stable security definer set search_path = public as $$
  with w as (
    select * from public.olo_answer_daily
    where day > current_date - least(greatest(coalesce(p_days, 28), 1), 365)
  ), t as (
    select coalesce(sum(answers), 0)::int as answers, coalesce(sum(uncovered), 0)::int as uncovered, coalesce(sum(abstained), 0)::int as abstained,
           coalesce(sum(extractive), 0)::int as extractive, coalesce(sum(sentences), 0)::int as sentences, coalesce(sum(supported), 0)::int as supported,
           coalesce(sum(contradicted), 0)::int as contradicted, coalesce(sum(not_covered), 0)::int as not_covered,
           coalesce(sum(zeus_checked), 0)::int as zeus_checked, coalesce(sum(zeus_supported), 0)::int as zeus_supported, coalesce(sum(fallback_checked), 0)::int as fallback_checked, coalesce(sum(unchecked), 0)::int as unchecked
    from w
  )
  select json_build_object(
    'days', least(greatest(coalesce(p_days, 28), 1), 365),
    'daily', (select coalesce(json_agg(json_build_object(
                'day', day, 'answers', answers, 'uncovered', uncovered, 'abstained', abstained, 'extractive', extractive,
                'sentences', sentences, 'supported', supported, 'contradicted', contradicted, 'not_covered', not_covered,
                'zeus_checked', zeus_checked, 'zeus_supported', zeus_supported, 'fallback_checked', fallback_checked, 'unchecked', unchecked) order by day desc), '[]'::json) from w),
    'totals', (select to_json(t) from t),
    'share_supported', (select case when sentences > 0 then round(supported::numeric / sentences, 3) end from t),
    'share_zeus_checked', (select case when sentences > 0 then round(zeus_checked::numeric / sentences, 3) end from t),
    'share_zeus_supported', (select case when zeus_checked > 0 then round(zeus_supported::numeric / zeus_checked, 3) end from t),
    'share_shown', (select case when answers > 0 then round((answers - abstained)::numeric / answers, 3) end from t),
    'note', 'Counts per UTC day of what the verifier said about the sentences olo-answer wrote. No question or answer text is kept.'
  );
$$;

revoke execute on function public.olo_answer_stats(int) from public;
grant execute on function public.olo_answer_stats(int) to anon, authenticated, service_role;

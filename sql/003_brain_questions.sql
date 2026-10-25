-- Olo Commons: the Olo brain (questions people choose to share).
--
-- Run after sql/001_olo_commons.sql and sql/002_trust_time_provenance.sql in the Supabase SQL
-- editor (project bfldflbkebyapfagsxnr). Safe to run again: every statement is "if not exists",
-- "create or replace" or guarded. Nothing here weakens SECURITY.md: only the service role (the
-- olo-brain-ask Edge Function) writes, clients read published questions only through two bounded
-- security definer functions, and every new function has explicit revokes and grants.
--
-- What it adds (see docs/BRAIN.md):
--   * olo_brain_questions  the scrubbed text of a question someone chose to add to the Olo brain,
--                          the client it came from, the atom ids that answered it and how many times
--                          it was asked. Never a user id, an address, the conversation or the answer.
--                          status: published (shown as an orb), held (waiting for a person), rejected.
--   * olo_brain_rate       per daily-salted address hash and hour: the rate limit (30 an hour).
--   * olo_brain_seen       per daily-salted address hash and question: one address asking the same
--                          question twice in a day counts once.
--   * olo_brain_daily      asks per day, for "N questions asked today".
--   * olo_brain_record     the one write path (service role only); feeds olo_record_gap when a
--                          published question was not answered, so unanswered questions drive ingestion.
--   * olo_brain_recent, olo_brain_stats   public, read-only, published rows only.
--   * olo_brain_retention  daily pg_cron job: held rows older than 30 days are deleted, rejected rows
--                          lose their text after 30 days (the hash stays so the same text stays out),
--                          rate-limit rows older than two days are deleted.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.olo_brain_questions (
  id bigserial primary key,
  text text not null check (length(text) between 1 and 500),
  norm_hash text not null check (norm_hash ~ '^[0-9a-f]{64}$'),       -- sha256 of the normalised scrubbed text
  client text not null check (client in ('web','ios','macos')),
  atoms text[] not null default '{}'::text[]
    check (cardinality(atoms) <= 12 and array_to_string(atoms, ',') ~ '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(,|$))*$'),
  answered boolean not null default false,
  asks int not null default 1 check (asks >= 1),
  status text not null default 'held' check (status in ('published','held','rejected')),
  reason text check (reason is null or length(reason) <= 200),         -- why it was held, or a reviewer's note
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_asked_at timestamptz not null default now()
);
create unique index if not exists olo_brain_questions_norm on public.olo_brain_questions (norm_hash);
create index if not exists olo_brain_questions_published on public.olo_brain_questions (created_at desc, id desc) where status = 'published';
create index if not exists olo_brain_questions_status on public.olo_brain_questions (status, created_at);
alter table public.olo_brain_questions enable row level security;
revoke all on public.olo_brain_questions from public, anon, authenticated;
grant select, insert, update, delete on public.olo_brain_questions to service_role;
revoke all on sequence public.olo_brain_questions_id_seq from public, anon, authenticated;
grant usage, select on sequence public.olo_brain_questions_id_seq to service_role;

create table if not exists public.olo_brain_rate (
  ip_hash text not null,
  hour timestamptz not null,
  hits int not null default 0,
  primary key (ip_hash, hour)
);
alter table public.olo_brain_rate enable row level security;
revoke all on public.olo_brain_rate from public, anon, authenticated;
grant select, insert, update, delete on public.olo_brain_rate to service_role;

create table if not exists public.olo_brain_seen (
  ip_hash text not null,
  norm_hash text not null,
  seen_at timestamptz not null default now(),
  primary key (ip_hash, norm_hash)
);
alter table public.olo_brain_seen enable row level security;
revoke all on public.olo_brain_seen from public, anon, authenticated;
grant select, insert, update, delete on public.olo_brain_seen to service_role;

create table if not exists public.olo_brain_daily (
  day date primary key,
  asks int not null default 0
);
alter table public.olo_brain_daily enable row level security;
revoke all on public.olo_brain_daily from public, anon, authenticated;
grant select, insert, update, delete on public.olo_brain_daily to service_role;

-- updated_at follows every change, including a reviewer's status edit in the dashboard.
create or replace function public.olo_brain_touch() returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
revoke execute on function public.olo_brain_touch() from public, anon, authenticated;
grant execute on function public.olo_brain_touch() to service_role;
drop trigger if exists olo_brain_touch_trg on public.olo_brain_questions;
create trigger olo_brain_touch_trg before update on public.olo_brain_questions for each row execute function public.olo_brain_touch();

-- ---------------------------------------------------------------------------
-- 2. The write path (service role only). The function has already scrubbed the text and decided
--    published or held; this rate-limits, dedupes, counts and feeds the gap list.
--    Returns { limited } or { id, status, inserted, counted }.
-- ---------------------------------------------------------------------------
create or replace function public.olo_brain_record(
  p_text text, p_norm_hash text, p_client text, p_atoms text[], p_answered boolean,
  p_status text, p_reason text, p_ip_hash text,
  p_per_hour int default 30, p_gap_ip_hash text default null, p_once_per_address boolean default true
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_hits int; v_counted boolean := true; v_id bigint; v_status text; v_inserted boolean;
begin
  if p_ip_hash is null or length(p_ip_hash) < 16 then raise exception 'olo_brain_record: address hash required'; end if;
  if p_status not in ('published','held') then raise exception 'olo_brain_record: status must be published or held'; end if;

  insert into public.olo_brain_rate (ip_hash, hour, hits) values (p_ip_hash, date_trunc('hour', now()), 1)
  on conflict (ip_hash, hour) do update set hits = public.olo_brain_rate.hits + 1
  returning hits into v_hits;
  if v_hits > greatest(coalesce(p_per_hour, 30), 1) then return json_build_object('limited', true); end if;

  if coalesce(p_once_per_address, true) then
    insert into public.olo_brain_seen (ip_hash, norm_hash) values (p_ip_hash, p_norm_hash) on conflict do nothing;
    v_counted := found;
  end if;

  insert into public.olo_brain_questions (text, norm_hash, client, atoms, answered, status, reason)
  values (left(p_text, 500), p_norm_hash, p_client, coalesce(p_atoms, '{}'::text[]), coalesce(p_answered, false), p_status, left(p_reason, 200))
  on conflict (norm_hash) do update set
    asks = public.olo_brain_questions.asks + case when v_counted then 1 else 0 end,
    last_asked_at = case when v_counted then now() else public.olo_brain_questions.last_asked_at end,
    answered = public.olo_brain_questions.answered or excluded.answered,
    atoms = case when cardinality(public.olo_brain_questions.atoms) = 0 then excluded.atoms else public.olo_brain_questions.atoms end
  returning id, status, (xmax = 0) into v_id, v_status, v_inserted;

  if v_counted then
    insert into public.olo_brain_daily (day, asks) values (current_date, 1)
    on conflict (day) do update set asks = public.olo_brain_daily.asks + 1;
    -- Unanswered and public: its topic words become a gap the ingester reads sources on (sql/002 caps each address).
    if not coalesce(p_answered, false) and v_status = 'published' then
      begin
        perform public.olo_record_gap(p_text, p_gap_ip_hash);
      exception when others then null;   -- a gap is a hint; never fail the question over it
      end;
    end if;
  end if;

  return json_build_object('id', v_id, 'status', v_status, 'inserted', v_inserted, 'counted', v_counted);
end $$;
revoke execute on function public.olo_brain_record(text, text, text, text[], boolean, text, text, text, int, text, boolean) from public, anon, authenticated;
grant execute on function public.olo_brain_record(text, text, text, text[], boolean, text, text, text, int, text, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Public reads: published questions only, bounded.
-- ---------------------------------------------------------------------------
create or replace function public.olo_brain_recent(p_limit int default 200) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', q.id, 'text', q.text, 'client', q.client, 'asks', q.asks, 'created_at', q.created_at, 'atoms', q.atoms) order by q.created_at desc, q.id desc), '[]'::json)
  from (select id, text, client, asks, created_at, atoms from public.olo_brain_questions
         where status = 'published'
         order by created_at desc, id desc
         limit least(greatest(coalesce(p_limit, 200), 1), 500)) q;
$$;
revoke execute on function public.olo_brain_recent(int) from public;
grant execute on function public.olo_brain_recent(int) to anon, authenticated, service_role;

create or replace function public.olo_brain_stats() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'published', (select count(*) from public.olo_brain_questions where status = 'published'),
    'held', (select count(*) from public.olo_brain_questions where status = 'held'),
    'today', coalesce((select asks from public.olo_brain_daily where day = current_date), 0)
  );
$$;
revoke execute on function public.olo_brain_stats() from public;
grant execute on function public.olo_brain_stats() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Retention, daily at 03:17 UTC.
-- ---------------------------------------------------------------------------
create or replace function public.olo_brain_retention() returns json language plpgsql security definer set search_path = public as $$
declare n_held int; n_rejected int; n_rate int;
begin
  delete from public.olo_brain_questions where status = 'held' and created_at < now() - interval '30 days';
  get diagnostics n_held = row_count;
  update public.olo_brain_questions set text = '[removed]', atoms = '{}'::text[]
   where status = 'rejected' and updated_at < now() - interval '30 days' and text <> '[removed]';
  get diagnostics n_rejected = row_count;
  delete from public.olo_brain_rate where hour < now() - interval '2 days';
  get diagnostics n_rate = row_count;
  delete from public.olo_brain_seen where seen_at < now() - interval '2 days';
  return json_build_object('held_deleted', n_held, 'rejected_cleared', n_rejected, 'rate_rows_deleted', n_rate);
end $$;
revoke execute on function public.olo_brain_retention() from public, anon, authenticated;
grant execute on function public.olo_brain_retention() to service_role;

do $$ begin perform cron.unschedule('olo_brain_retention_daily'); exception when others then null; end $$;
do $$ begin
  perform cron.schedule('olo_brain_retention_daily', '17 3 * * *', 'select public.olo_brain_retention();');
exception when others then
  raise notice 'pg_cron is not available: run "select public.olo_brain_retention();" daily by hand (docs/BRAIN.md)';
end $$;

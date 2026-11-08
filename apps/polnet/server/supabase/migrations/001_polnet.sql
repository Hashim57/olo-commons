-- POL Net: members, pol:// names, paid tasks, claims, the ledger, reports and rate limits.
--
-- Run in the SQL editor of the POL Net Supabase project (the Proof-of-Life project works too: this lives
-- in its own schema). Safe to run again: everything is "if not exists" or "create or replace".
--
-- Security: the schema is private. RLS is on for every table with no policies, so the anon and
-- authenticated roles can read and write nothing; only the Edge Function, connecting as the database
-- owner through SUPABASE_DB_URL, touches it. Nothing personal is stored: a member is a pairwise
-- Proof-of-Life subject and a chosen handle. Money is integer pence, and ledger rows are never updated
-- or deleted (a trigger refuses it).

create schema if not exists polnet;
revoke all on schema polnet from public, anon, authenticated;

create table if not exists polnet.members (
  id uuid primary key,
  subject text not null unique,
  handle text not null,
  role text not null default 'member' check (role in ('member', 'poster')),
  suspended boolean not null default false,
  stripe_account text,
  payouts_enabled boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists members_handle_lower on polnet.members (lower(handle));

create table if not exists polnet.names (
  name text primary key check (name ~ '^[a-z0-9]([a-z0-9-]{1,30}[a-z0-9])$'),
  owner uuid not null references polnet.members (id) on delete cascade,
  target text not null check (target like 'https://%'),
  description text not null default '',
  suspended boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists names_owner on polnet.names (owner);

create table if not exists polnet.tasks (
  id uuid primary key,
  poster uuid not null references polnet.members (id),
  title text not null,
  description text not null,
  instructions text not null default '',
  category text not null,
  reward_pence integer not null check (reward_pence between 50 and 100000),
  currency text not null default 'GBP' check (currency in ('GBP', 'EUR')),
  slots integer not null check (slots between 1 and 1000),
  status text not null default 'draft' check (status in ('draft', 'open', 'closed')),
  deadline timestamptz,
  fee_pence integer not null default 0,
  funded_pence integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists tasks_status on polnet.tasks (status, created_at desc);
create index if not exists tasks_poster on polnet.tasks (poster);

create table if not exists polnet.claims (
  id uuid primary key,
  task_id uuid not null references polnet.tasks (id) on delete cascade,
  member_id uuid not null references polnet.members (id),
  status text not null default 'claimed' check (status in ('claimed', 'submitted', 'approved', 'rejected')),
  evidence_text text,
  evidence_url text,
  note text,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_at timestamptz
);
create index if not exists claims_task on polnet.claims (task_id);
create index if not exists claims_member on polnet.claims (member_id, created_at desc);

create table if not exists polnet.ledger (
  id uuid primary key,
  member_id uuid not null references polnet.members (id),
  amount_pence integer not null,
  currency text not null check (currency in ('GBP', 'EUR')),
  kind text not null check (kind in ('task_reward', 'payout', 'payout_reversal')),
  ref text not null,
  created_at timestamptz not null default now()
);
create index if not exists ledger_member on polnet.ledger (member_id, created_at desc);
-- One reward per approved claim, whatever happens.
create unique index if not exists ledger_one_reward on polnet.ledger (ref) where kind = 'task_reward';

create or replace function polnet.ledger_is_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'polnet.ledger is append-only';
end $$;
drop trigger if exists ledger_append_only on polnet.ledger;
create trigger ledger_append_only before update or delete on polnet.ledger
  for each row execute function polnet.ledger_is_append_only();

create table if not exists polnet.reports (
  id uuid primary key,
  reporter uuid not null references polnet.members (id),
  kind text not null check (kind in ('name', 'task', 'member', 'site')),
  target text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  unique (reporter, kind, target)
);

create table if not exists polnet.hits (
  key text not null,
  at timestamptz not null default now()
);
create index if not exists hits_key_at on polnet.hits (key, at);

-- Rate-limit rows older than a day are dropped hourly (needs pg_cron; harmless to leave unscheduled).
create or replace function polnet.purge_hits() returns void language sql as $$
  delete from polnet.hits where at < now() - interval '1 day';
$$;

alter table polnet.members enable row level security;
alter table polnet.names enable row level security;
alter table polnet.tasks enable row level security;
alter table polnet.claims enable row level security;
alter table polnet.ledger enable row level security;
alter table polnet.reports enable row level security;
alter table polnet.hits enable row level security;

revoke all on all tables in schema polnet from public, anon, authenticated;
revoke all on all functions in schema polnet from public, anon, authenticated;

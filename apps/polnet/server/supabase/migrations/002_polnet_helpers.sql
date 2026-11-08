-- POL Net 002: family help for scam protection.
--
-- A member in protected mode can link up to three helpers (other verified members, usually family).
-- When the browser shows them a scam warning, each helper is told the site's host name and the kind of
-- warning, nothing else: never browsing history, never page content, never what was typed. Either side
-- can end the link at any time. Alerts are kept for 30 days.
--
-- Safe to run again. Same security model as 001: RLS on with no policies, nothing granted to anon or
-- authenticated; only the Edge Function's owner connection reads or writes.

create table if not exists polnet.helper_invites (
  code_hash text primary key,
  member_id uuid not null references polnet.members (id) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists helper_invites_member on polnet.helper_invites (member_id);

create table if not exists polnet.helpers (
  id uuid primary key,
  protected_id uuid not null references polnet.members (id) on delete cascade,
  helper_id uuid not null references polnet.members (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (protected_id, helper_id),
  check (protected_id <> helper_id)
);
create index if not exists helpers_helper on polnet.helpers (helper_id);

create table if not exists polnet.helper_alerts (
  id uuid primary key,
  protected_id uuid not null references polnet.members (id) on delete cascade,
  host text not null check (length(host) <= 253),
  kind text not null check (kind in ('lookalike', 'reported', 'scam-page', 'remote-access', 'pause', 'download')),
  created_at timestamptz not null default now()
);
create index if not exists helper_alerts_protected_at on polnet.helper_alerts (protected_id, created_at);

alter table polnet.helper_invites enable row level security;
alter table polnet.helpers enable row level security;
alter table polnet.helper_alerts enable row level security;

revoke all on all tables in schema polnet from public, anon, authenticated;
revoke all on all functions in schema polnet from public, anon, authenticated;

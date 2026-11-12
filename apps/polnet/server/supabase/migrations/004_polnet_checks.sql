-- POL Net 004: Teach Zeus. Members check claims against passages from the Commons.
--
-- An item is one claim with two to four passages (each with its source and address). A member gives one
-- label per item: supported, contradicted or not covered, and for the first two the exact words in one
-- passage that decide it. When three members give the same label the item is agreed; at five labels
-- without that it is disputed and set aside. Agreed items are exported for Zeus (zeus/
-- member_checks_to_gold.py) and read by a person before they are committed. `known` marks a control
-- item whose answer is already known: it measures how careful labelling is and is never exported.
-- Members never see each other's labels, so this is not a place where people post to each other.
--
-- Safe to run again. Same security model as 001: RLS on with no policies, nothing granted to anon or
-- authenticated; only the Edge Function's owner connection reads or writes.

create table if not exists polnet.check_items (
  id uuid primary key,
  claim text not null check (length(claim) between 10 and 600),
  passages jsonb not null,
  known text check (known is null or known in ('supported', 'contradicted', 'not_covered')),
  status text not null default 'open' check (status in ('open', 'agreed', 'disputed')),
  label text check (label is null or label in ('supported', 'contradicted', 'not_covered')),
  created_at timestamptz not null default now()
);
create index if not exists check_items_status on polnet.check_items (status, created_at);

create table if not exists polnet.check_labels (
  item_id uuid not null references polnet.check_items (id) on delete cascade,
  member_id uuid not null references polnet.members (id) on delete cascade,
  label text not null check (label in ('supported', 'contradicted', 'not_covered')),
  passage text,
  quote text check (quote is null or length(quote) <= 600),
  created_at timestamptz not null default now(),
  primary key (item_id, member_id),
  check ((label = 'not_covered') = (quote is null))
);
create index if not exists check_labels_member on polnet.check_labels (member_id);

alter table polnet.check_items enable row level security;
alter table polnet.check_labels enable row level security;

revoke all on all tables in schema polnet from public, anon, authenticated;
revoke all on all functions in schema polnet from public, anon, authenticated;

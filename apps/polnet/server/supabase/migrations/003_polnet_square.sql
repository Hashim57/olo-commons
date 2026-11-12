-- POL Net 003: the Square, the members' community.
--
-- Posts, comments and votes by verified members. One real person holds one account, so one vote is one
-- person and a post cannot be pushed up or taken down by bots. Topics are fixed in the API (ideas,
-- projects, questions, research, impact, tv); a "tv" post is a HeliusTV listing and carries the https
-- address of a video hosted elsewhere, so no video is stored here. Three reports from three different
-- members remove a post pending review (reports of kind 'post').
--
-- Safe to run again. Same security model as 001: RLS on with no policies, nothing granted to anon or
-- authenticated; only the Edge Function's owner connection reads or writes.

create table if not exists polnet.posts (
  id uuid primary key,
  author uuid not null references polnet.members (id) on delete cascade,
  topic text not null check (topic in ('ideas', 'projects', 'questions', 'research', 'impact', 'tv')),
  title text not null check (length(title) between 5 and 140),
  body text not null check (length(body) <= 6000),
  link text check (link is null or (length(link) <= 2000 and link like 'https://%')),
  removed boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists posts_topic_created on polnet.posts (topic, created_at desc);
create index if not exists posts_created on polnet.posts (created_at desc);
create index if not exists posts_author on polnet.posts (author);

create table if not exists polnet.post_comments (
  id uuid primary key,
  post_id uuid not null references polnet.posts (id) on delete cascade,
  author uuid not null references polnet.members (id) on delete cascade,
  body text not null check (length(body) between 1 and 3000),
  created_at timestamptz not null default now()
);
create index if not exists post_comments_post on polnet.post_comments (post_id, created_at);

create table if not exists polnet.post_votes (
  post_id uuid not null references polnet.posts (id) on delete cascade,
  member_id uuid not null references polnet.members (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, member_id)
);

-- Reports may now name a post. The check constraint from 001 is replaced by one that allows it.
alter table polnet.reports drop constraint if exists reports_kind_check;
alter table polnet.reports add constraint reports_kind_check check (kind in ('name', 'task', 'member', 'site', 'post'));

alter table polnet.posts enable row level security;
alter table polnet.post_comments enable row level security;
alter table polnet.post_votes enable row level security;

revoke all on all tables in schema polnet from public, anon, authenticated;
revoke all on all functions in schema polnet from public, anon, authenticated;

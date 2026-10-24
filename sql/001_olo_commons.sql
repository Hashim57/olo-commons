-- Olo Commons: an open, verifiable knowledge base that Olo grows from.
-- Run AFTER migration-4. Safe to re-run.
--
-- Design in one paragraph: knowledge enters only from a registry of trusted,
-- openly licensed sources, only through the server (olo-ingest Edge Function).
-- Every atom keeps provenance (source, URL, licence, content hash, retrieval
-- time), gets an embedding (gte-small, 384 dims, computed inside Supabase) and
-- is linked to its nearest neighbours. The web, helius-olo.io and the app read
-- through views and functions; nothing a client sends can write knowledge.

create extension if not exists vector with schema extensions;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Source registry. Only enabled sources are ever fetched.
-- ---------------------------------------------------------------------------
create table if not exists public.olo_sources (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  kind text not null check (kind in ('encyclopedia','knowledge_graph','archive','papers','books','government','data','other')),
  homepage text,
  api_base text,
  licence text not null,
  licence_url text,
  description text,
  trust int not null default 80 check (trust between 0 and 100),
  enabled boolean not null default true,
  atoms int not null default 0,
  last_run_at timestamptz,
  created_at timestamptz not null default now()
);
insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust) values
 ('wikipedia', 'Wikipedia', 'encyclopedia', 'https://en.wikipedia.org', 'https://en.wikipedia.org/api/rest_v1', 'CC BY-SA 4.0', 'https://creativecommons.org/licenses/by-sa/4.0/', 'The free encyclopedia. Article summaries and lead sections.', 85),
 ('wikidata', 'Wikidata', 'knowledge_graph', 'https://www.wikidata.org', 'https://www.wikidata.org/w/api.php', 'CC0 1.0', 'https://creativecommons.org/publicdomain/zero/1.0/', 'Structured facts about entities: people, places, things, dates.', 85),
 ('archive_org', 'Internet Archive', 'archive', 'https://archive.org', 'https://archive.org/advancedsearch.php', 'Varies by item (public domain and CC)', 'https://archive.org/about/terms.php', 'Metadata and descriptions of public-domain texts, audio and film in the Archive.', 80),
 ('arxiv', 'arXiv', 'papers', 'https://arxiv.org', 'https://export.arxiv.org/api/query', 'arXiv.org perpetual non-exclusive licence (abstracts)', 'https://arxiv.org/help/license', 'Abstracts of research papers in physics, maths, computer science and more.', 90),
 ('gutenberg', 'Project Gutenberg', 'books', 'https://www.gutenberg.org', 'https://gutendex.com/books', 'Public domain', 'https://www.gutenberg.org/policy/license.html', 'Catalogue of over 70,000 public-domain books.', 90),
 ('pubmed', 'PubMed', 'papers', 'https://pubmed.ncbi.nlm.nih.gov', 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils', 'Public domain (NLM metadata); abstracts as published', 'https://www.ncbi.nlm.nih.gov/home/about/policies/', 'Biomedical literature citations and abstracts from the US National Library of Medicine.', 90)
on conflict (slug) do nothing;
-- Connectors added after launch. They start disabled: a human enables each one
-- after the deployed connector has been watched for a run or two
-- (update public.olo_sources set enabled = true where slug = '...').
insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust, enabled) values
 ('data_gov', 'Data.gov', 'government', 'https://catalog.data.gov', 'https://catalog.data.gov/api/3', 'Per dataset; only open licence ids are kept (U.S. public domain, CC0, CC BY, CC BY-SA, ODC, OGL)', 'https://resources.data.gov/open-licenses/', 'Descriptions of U.S. government open datasets from the data.gov CKAN catalogue.', 75, false),
 ('wikipedia_es', 'Wikipedia (español)', 'encyclopedia', 'https://es.wikipedia.org', 'https://es.wikipedia.org/api/rest_v1', 'CC BY-SA 4.0', 'https://creativecommons.org/licenses/by-sa/4.0/', 'La enciclopedia libre: article summaries from the Spanish Wikipedia, stored with lang = es.', 85, false)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Atoms: one unit of knowledge with provenance and an embedding.
-- ---------------------------------------------------------------------------
create table if not exists public.olo_atoms (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.olo_sources(id) on delete restrict,
  external_id text,
  url text not null unique,
  title text not null,
  summary text,
  content text,                                  -- plain text only, capped by the ingester
  lang text not null default 'en',
  licence text not null,
  authors text[],
  published_at date,
  content_hash text not null unique,             -- sha256 of title + summary + content
  quality int not null default 70 check (quality between 0 and 100),
  tokens int,
  embedding extensions.vector(384),
  tsv tsvector generated always as (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(summary, ''))) stored,
  retrieved_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists olo_atoms_tsv on public.olo_atoms using gin (tsv);
create index if not exists olo_atoms_source on public.olo_atoms (source_id, created_at desc);
create index if not exists olo_atoms_created on public.olo_atoms (created_at desc);
do $$ begin
  if not exists (select 1 from pg_indexes where indexname = 'olo_atoms_embedding') then
    create index olo_atoms_embedding on public.olo_atoms using hnsw (embedding extensions.vector_cosine_ops);
  end if;
end $$;

-- Links between atoms: the "brain". similar = nearest neighbours by meaning.
create table if not exists public.olo_links (
  from_atom uuid not null references public.olo_atoms(id) on delete cascade,
  to_atom uuid not null references public.olo_atoms(id) on delete cascade,
  relation text not null default 'similar' check (relation in ('similar','cites','same_entity','same_topic')),
  weight real not null default 0,
  created_at timestamptz not null default now(),
  primary key (from_atom, to_atom, relation)
);
create index if not exists olo_links_to on public.olo_links (to_atom);

-- Fetch queue and run log
create table if not exists public.olo_queue (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.olo_sources(id) on delete cascade,
  url text not null unique,
  external_id text,
  priority int not null default 5,
  status text not null default 'pending' check (status in ('pending','done','failed','skipped')),
  attempts int not null default 0,
  last_error text,
  created_at timestamptz not null default now()
);
create index if not exists olo_queue_pending on public.olo_queue (status, priority desc, created_at) where status = 'pending';

create table if not exists public.olo_ingest_runs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  fetched int not null default 0, added int not null default 0, skipped int not null default 0, failed int not null default 0, linked int not null default 0,
  note text
);

-- Daily snapshot for the growth chart (written by the ingester)
create table if not exists public.olo_daily (
  day date primary key,
  atoms bigint not null, links bigint not null, sources int not null, queries bigint not null default 0
);

-- Queries (counts only; never the text, never who)
create table if not exists public.olo_query_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  ip_hash text,
  q_len int,
  results int,
  client text
);
create index if not exists olo_query_log_ip on public.olo_query_log (ip_hash, at desc);

-- Member projects built on Olo, and source proposals
create table if not exists public.olo_projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  description text,
  url text,
  repo_url text,
  kind text not null default 'app' check (kind in ('app','research','dataset','tool','education','other')),
  status text not null default 'pending' check (status in ('pending','approved','hidden')),
  created_at timestamptz not null default now()
);
create table if not exists public.olo_source_proposals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  name text not null, url text not null, licence text, why text,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. Access: knowledge is public to read, server-only to write.
-- ---------------------------------------------------------------------------
alter table public.olo_sources enable row level security;
alter table public.olo_atoms enable row level security;
alter table public.olo_links enable row level security;
alter table public.olo_queue enable row level security;
alter table public.olo_ingest_runs enable row level security;
alter table public.olo_daily enable row level security;
alter table public.olo_query_log enable row level security;
alter table public.olo_projects enable row level security;
alter table public.olo_source_proposals enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='olo_sources' and policyname='olo_sources_read') then create policy olo_sources_read on public.olo_sources for select using (true); end if;
  if not exists (select 1 from pg_policies where tablename='olo_atoms' and policyname='olo_atoms_read') then create policy olo_atoms_read on public.olo_atoms for select using (true); end if;
  if not exists (select 1 from pg_policies where tablename='olo_links' and policyname='olo_links_read') then create policy olo_links_read on public.olo_links for select using (true); end if;
  if not exists (select 1 from pg_policies where tablename='olo_ingest_runs' and policyname='olo_runs_read') then create policy olo_runs_read on public.olo_ingest_runs for select using (true); end if;
  if not exists (select 1 from pg_policies where tablename='olo_daily' and policyname='olo_daily_read') then create policy olo_daily_read on public.olo_daily for select using (true); end if;
  if not exists (select 1 from pg_policies where tablename='olo_projects' and policyname='olo_projects_read') then create policy olo_projects_read on public.olo_projects for select using (status = 'approved' or auth.uid() = owner_id); end if;
  if not exists (select 1 from pg_policies where tablename='olo_projects' and policyname='olo_projects_own') then create policy olo_projects_own on public.olo_projects for all using (auth.uid() = owner_id) with check (auth.uid() = owner_id); end if;
  if not exists (select 1 from pg_policies where tablename='olo_source_proposals' and policyname='olo_props_insert') then create policy olo_props_insert on public.olo_source_proposals for insert with check (auth.uid() = user_id); end if;
  if not exists (select 1 from pg_policies where tablename='olo_source_proposals' and policyname='olo_props_own') then create policy olo_props_own on public.olo_source_proposals for select using (auth.uid() = user_id); end if;
end $$;
-- Clients never see the queue or the query log; projects can't approve themselves.
create or replace function public.guard_olo_project() returns trigger language plpgsql as $$
begin
  if public.is_client() then
    if tg_op = 'INSERT' then new.status := 'pending'; else new.status := old.status; end if;
    if new.url is not null and new.url !~ '^https?://' then new.url := null; end if;
    if new.repo_url is not null and new.repo_url !~ '^https?://' then new.repo_url := null; end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_olo_project_trg on public.olo_projects;
create trigger guard_olo_project_trg before insert or update on public.olo_projects for each row execute function public.guard_olo_project();

grant select on public.olo_sources, public.olo_atoms, public.olo_links, public.olo_ingest_runs, public.olo_daily to anon, authenticated;
grant select, insert, update, delete on public.olo_projects to authenticated;
grant select, insert on public.olo_source_proposals to authenticated;
grant select, insert, update, delete on public.olo_sources, public.olo_atoms, public.olo_links, public.olo_queue, public.olo_ingest_runs, public.olo_daily, public.olo_query_log, public.olo_projects, public.olo_source_proposals to service_role;
grant usage, select on sequence public.olo_query_log_id_seq to service_role;
-- The column that must not leak to clients: nothing sensitive is stored, but the
-- raw content is large; the page reads summaries through the functions below.

-- ---------------------------------------------------------------------------
-- 4. Read API (public). Every function is read-only and bounded.
-- ---------------------------------------------------------------------------
create or replace function public.olo_stats() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'atoms', (select count(*) from public.olo_atoms),
    'links', (select count(*) from public.olo_links),
    'sources', (select count(*) from public.olo_sources where enabled),
    'atoms_24h', (select count(*) from public.olo_atoms where created_at > now() - interval '24 hours'),
    'links_24h', (select count(*) from public.olo_links where created_at > now() - interval '24 hours'),
    'queries_24h', (select count(*) from public.olo_query_log where at > now() - interval '24 hours'),
    'queries_total', (select count(*) from public.olo_query_log),
    'projects', (select count(*) from public.olo_projects where status = 'approved'),
    'last_run', (select finished_at from public.olo_ingest_runs where finished_at is not null order by finished_at desc limit 1),
    'by_source', (select coalesce(json_agg(json_build_object('slug', s.slug, 'name', s.name, 'kind', s.kind, 'licence', s.licence, 'homepage', s.homepage, 'atoms', (select count(*) from public.olo_atoms a where a.source_id = s.id), 'trust', s.trust, 'last_run_at', s.last_run_at) order by s.name), '[]'::json) from public.olo_sources s where s.enabled)
  );
$$;
grant execute on function public.olo_stats() to anon, authenticated;

create or replace function public.olo_growth(p_days int default 30) returns json language sql stable security definer set search_path = public as $$
  with days as (select generate_series((current_date - (least(greatest(p_days, 7), 365) - 1))::date, current_date, interval '1 day')::date d)
  select coalesce(json_agg(json_build_object('day', d, 'atoms', (select count(*) from public.olo_atoms a where a.created_at::date <= d), 'links', (select count(*) from public.olo_links l where l.created_at::date <= d)) order by d), '[]'::json) from days;
$$;
grant execute on function public.olo_growth(int) to anon, authenticated;

create or replace function public.olo_recent(p_k int default 12) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', a.id, 'title', a.title, 'summary', left(coalesce(a.summary, ''), 220), 'url', a.url, 'source', s.name, 'source_slug', s.slug, 'licence', a.licence, 'created_at', a.created_at,
           'links', (select count(*) from public.olo_links l where l.from_atom = a.id)) order by a.created_at desc), '[]'::json)
  from (select * from public.olo_atoms order by created_at desc limit least(greatest(p_k, 1), 50)) a join public.olo_sources s on s.id = a.source_id;
$$;
grant execute on function public.olo_recent(int) to anon, authenticated;

-- Keyword search (instant, no embedding needed)
create or replace function public.olo_search_text(p_q text, p_k int default 10) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', a.id, 'title', a.title, 'summary', left(coalesce(a.summary, ''), 400), 'url', a.url, 'source', s.name, 'source_slug', s.slug, 'licence', a.licence, 'published_at', a.published_at, 'retrieved_at', a.retrieved_at, 'rank', r.rank) order by r.rank desc), '[]'::json)
  from (select id, ts_rank(tsv, websearch_to_tsquery('english', left(coalesce(p_q, ''), 200))) as rank from public.olo_atoms
         where tsv @@ websearch_to_tsquery('english', left(coalesce(p_q, ''), 200)) order by rank desc limit least(greatest(p_k, 1), 50)) r
  join public.olo_atoms a on a.id = r.id join public.olo_sources s on s.id = a.source_id;
$$;
grant execute on function public.olo_search_text(text, int) to anon, authenticated;

-- Meaning search (called by the olo-query function with an embedding)
create or replace function public.olo_match(p_embedding extensions.vector(384), p_k int default 8, p_min float default 0.55) returns json language sql stable security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object('id', a.id, 'title', a.title, 'summary', left(coalesce(a.summary, ''), 600), 'content', left(coalesce(a.content, ''), 2000), 'url', a.url, 'source', s.name, 'source_slug', s.slug, 'licence', a.licence, 'published_at', a.published_at, 'retrieved_at', a.retrieved_at, 'similarity', m.sim) order by m.sim desc), '[]'::json)
  from (select id, 1 - (embedding <=> p_embedding) as sim from public.olo_atoms where embedding is not null order by embedding <=> p_embedding limit least(greatest(p_k, 1), 30)) m
  join public.olo_atoms a on a.id = m.id join public.olo_sources s on s.id = a.source_id
  where m.sim >= p_min;
$$;
revoke execute on function public.olo_match(extensions.vector, int, float) from public, anon, authenticated;
grant execute on function public.olo_match(extensions.vector, int, float) to service_role;

-- Neighbours for linking (ingester only)
create or replace function public.olo_neighbours(p_embedding extensions.vector(384), p_exclude uuid, p_k int default 5) returns table (id uuid, sim float) language sql stable security definer set search_path = public, extensions as $$
  select id, 1 - (embedding <=> p_embedding) from public.olo_atoms where embedding is not null and id <> p_exclude order by embedding <=> p_embedding limit least(greatest(p_k, 1), 20);
$$;
revoke execute on function public.olo_neighbours(extensions.vector, uuid, int) from public, anon, authenticated;
grant execute on function public.olo_neighbours(extensions.vector, uuid, int) to service_role;

-- A sample of the graph for the page: the most linked recent atoms and their edges
create or replace function public.olo_graph_sample(p_n int default 120) returns json language sql stable security definer set search_path = public as $$
  with nodes as (
    select a.id, a.title, s.slug as source, (select count(*) from public.olo_links l where l.from_atom = a.id or l.to_atom = a.id) as degree
      from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
     order by a.created_at desc limit least(greatest(p_n, 20), 300))
  select json_build_object(
    'nodes', coalesce((select json_agg(json_build_object('id', id, 'title', left(title, 60), 'source', source, 'degree', degree)) from nodes), '[]'::json),
    'edges', coalesce((select json_agg(json_build_object('from', l.from_atom, 'to', l.to_atom, 'w', l.weight)) from public.olo_links l where l.from_atom in (select id from nodes) and l.to_atom in (select id from nodes)), '[]'::json)
  );
$$;
grant execute on function public.olo_graph_sample(int) to anon, authenticated;

-- One atom with its neighbours
create or replace function public.olo_atom(p_id uuid) returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'atom', (select json_build_object('id', a.id, 'title', a.title, 'summary', a.summary, 'content', left(coalesce(a.content, ''), 6000), 'url', a.url, 'source', s.name, 'source_slug', s.slug, 'licence', a.licence, 'licence_url', s.licence_url, 'authors', a.authors, 'published_at', a.published_at, 'retrieved_at', a.retrieved_at, 'content_hash', a.content_hash, 'quality', a.quality)
              from public.olo_atoms a join public.olo_sources s on s.id = a.source_id where a.id = p_id),
    'neighbours', coalesce((select json_agg(json_build_object('id', b.id, 'title', b.title, 'source', s2.slug, 'weight', l.weight, 'relation', l.relation) order by l.weight desc)
              from public.olo_links l join public.olo_atoms b on b.id = l.to_atom join public.olo_sources s2 on s2.id = b.source_id where l.from_atom = p_id limit 12), '[]'::json)
  );
$$;
grant execute on function public.olo_atom(uuid) to anon, authenticated;

-- Public project gallery with owner names
-- Owner card for the gallery: only display name, username and avatar, and only
-- for someone who owns at least one approved project. profiles stays readable by
-- signed-in users only; this exposes nothing about anyone without public work.
create or replace function public.olo_owner_card(p_owner uuid)
returns table (name text, username text, avatar_url text)
language sql stable security definer set search_path = public as $$
  select pr.name::text, pr.username::text, pr.avatar_url::text
    from public.profiles pr
   where pr.id = p_owner
     and exists (select 1 from public.olo_projects p where p.owner_id = p_owner and p.status = 'approved');
$$;
revoke execute on function public.olo_owner_card(uuid) from public;
grant execute on function public.olo_owner_card(uuid) to anon, authenticated, service_role;

-- The view runs with the reader's rights (security_invoker), so RLS on
-- olo_projects applies; olo_projects_read already lets anyone see approved rows.
-- Drop then create: the owner columns change type to text.
drop view if exists public.olo_projects_public;
create view public.olo_projects_public with (security_invoker = true) as
select p.id, p.name, p.description, p.url, p.repo_url, p.kind, p.created_at, o.name as owner_name, o.username as owner_username, o.avatar_url as owner_avatar
from public.olo_projects p left join lateral public.olo_owner_card(p.owner_id) o on true where p.status = 'approved';
grant select on public.olo_projects_public to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Schedule: ingest every hour, snapshot daily. Uses the Vault service key
--    like the digest. Deploy the olo-ingest function first.
-- ---------------------------------------------------------------------------
create or replace function public.run_olo_ingest() returns void language plpgsql security definer set search_path = public, vault, extensions as $$
declare svc_key text;
begin
  -- Close any run the Edge runtime cut off (its per-atom checkpoints keep the counts accurate).
  update public.olo_ingest_runs set finished_at = now(), note = coalesce(note, '') || ' (closed: cut off by runtime)'
   where finished_at is null and started_at < now() - interval '5 minutes';
  select decrypted_secret into svc_key from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  if svc_key is null then return; end if;
  perform net.http_post(
    url := 'https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-ingest',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || svc_key),
    body := jsonb_build_object('source', 'cron', 'budget', 8),
    timeout_milliseconds := 60000
  );
end $$;
revoke execute on function public.run_olo_ingest() from public, anon, authenticated;
grant execute on function public.run_olo_ingest() to service_role;
create or replace function public.olo_snapshot() returns void language sql security definer set search_path = public as $$
  insert into public.olo_daily (day, atoms, links, sources, queries)
  values (current_date, (select count(*) from public.olo_atoms), (select count(*) from public.olo_links), (select count(*) from public.olo_sources where enabled), (select count(*) from public.olo_query_log where at::date = current_date))
  on conflict (day) do update set atoms = excluded.atoms, links = excluded.links, sources = excluded.sources, queries = excluded.queries;
$$;
revoke execute on function public.olo_snapshot() from public, anon, authenticated;
grant execute on function public.olo_snapshot() to service_role;
do $$ begin perform cron.unschedule('olo_ingest_hourly'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('olo_snapshot_daily'); exception when others then null; end $$;
select cron.schedule('olo_ingest_hourly', '3,18,33,48 * * * *', $$ select public.run_olo_ingest(); $$);  -- every 15 minutes, small batches
select cron.schedule('olo_snapshot_daily', '55 23 * * *', $$ select public.olo_snapshot(); $$);

-- ---------------------------------------------------------------------------
-- 6. Bulk export for builders: pages of atoms in creation order (no embeddings).
--    Use with p_after = the last created_at you received. 500 per page.
-- ---------------------------------------------------------------------------
create or replace function public.olo_export(p_after timestamptz default '1970-01-01', p_limit int default 500) returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'atoms', coalesce((select json_agg(json_build_object('id', a.id, 'title', a.title, 'summary', a.summary, 'content', a.content, 'url', a.url, 'source', s.slug, 'licence', a.licence, 'authors', a.authors, 'published_at', a.published_at, 'content_hash', a.content_hash, 'quality', a.quality, 'retrieved_at', a.retrieved_at, 'created_at', a.created_at) order by a.created_at)
                 from (select * from public.olo_atoms where created_at > p_after order by created_at limit least(greatest(p_limit, 1), 500)) a join public.olo_sources s on s.id = a.source_id), '[]'::json),
    'next_after', (select max(created_at) from (select created_at from public.olo_atoms where created_at > p_after order by created_at limit least(greatest(p_limit, 1), 500)) x),
    'licence_note', 'Each atom carries its own licence; the compilation is CC BY-SA 4.0. Attribute Olo Commons by Helius Network.'
  );
$$;
grant execute on function public.olo_export(timestamptz, int) to anon, authenticated;

create or replace function public.olo_links_export(p_after timestamptz default '1970-01-01', p_limit int default 2000) returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'links', coalesce((select json_agg(json_build_object('from', from_atom, 'to', to_atom, 'relation', relation, 'weight', weight, 'created_at', created_at) order by created_at)
                 from (select * from public.olo_links where created_at > p_after order by created_at limit least(greatest(p_limit, 1), 2000)) l), '[]'::json),
    'next_after', (select max(created_at) from (select created_at from public.olo_links where created_at > p_after order by created_at limit least(greatest(p_limit, 1), 2000)) x)
  );
$$;
grant execute on function public.olo_links_export(timestamptz, int) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Gaps: what people asked that the Commons could not answer, kept as a bag
--    of content words (never the question itself), so the ingester can look
--    for sources on that topic and the page can show what Olo is learning.
-- ---------------------------------------------------------------------------
create table if not exists public.olo_gaps (
  id uuid primary key default gen_random_uuid(),
  topic text not null,                      -- up to six lower-case content words, sorted, space separated
  topic_hash text not null unique,          -- md5 of topic
  asks int not null default 1,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  filled_at timestamptz,
  atoms_added int not null default 0,
  tries int not null default 0,
  last_tried_at timestamptz
);
create index if not exists olo_gaps_open_idx on public.olo_gaps (filled_at, asks desc, last_seen desc);
alter table public.olo_gaps enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='olo_gaps' and policyname='olo_gaps_read') then create policy olo_gaps_read on public.olo_gaps for select using (true); end if;
end $$;
grant select on public.olo_gaps to anon, authenticated;
grant select, insert, update, delete on public.olo_gaps to service_role;

-- Turn a question into its topic words: letters only, lower case, four letters
-- or more, no stop words, distinct, sorted, at most six. Returns null when fewer
-- than two words survive, so single-word or empty questions record nothing.
create or replace function public.olo_gap_topic(p_q text) returns text language sql immutable as $$
  select nullif(string_agg(w, ' ' order by w), '') from (
    select distinct w from (
      select w from unnest(regexp_split_to_array(lower(coalesce(p_q, '')), '[^a-z]+')) as w
      where length(w) >= 4 and w not in ('what','when','where','which','whom','whose','this','that','these','those','there','their','them','they','then','than','with','from','into','about','does','have','been','were','will','would','could','should','shall','much','many','more','most','some','such','only','also','very','just','like','over','under','after','before','between','because','while','until','since','being','were','your','ours','mine','tell','know','give','show','find','explain','describe','please','question','answer','olo','commons')
    ) x
  ) y
  having count(*) >= 2 and count(*) <= 40
$$;

-- Called by olo-answer (service role) when a question came back uncovered.
create or replace function public.olo_record_gap(p_q text) returns void language plpgsql security definer set search_path = public as $$
declare t text; h text;
begin
  t := public.olo_gap_topic(p_q);
  if t is null then return; end if;
  -- keep the topic to six words so it stays a topic, not a sentence
  t := array_to_string((regexp_split_to_array(t, ' '))[1:6], ' ');
  h := md5(t);
  insert into public.olo_gaps (topic, topic_hash) values (t, h)
  on conflict (topic_hash) do update set asks = public.olo_gaps.asks + 1, last_seen = now(), filled_at = null;
end $$;
revoke execute on function public.olo_record_gap(text) from public, anon, authenticated;
grant execute on function public.olo_record_gap(text) to service_role;

-- The ingester takes the most-asked open gap it has not tried in the last day.
create or replace function public.olo_next_gap() returns json language sql stable security definer set search_path = public as $$
  select to_json(g) from (
    select id, topic, asks, tries from public.olo_gaps
    where filled_at is null and tries < 5 and (last_tried_at is null or last_tried_at < now() - interval '1 day')
    order by asks desc, last_seen desc limit 1
  ) g;
$$;
revoke execute on function public.olo_next_gap() from public, anon, authenticated;
grant execute on function public.olo_next_gap() to service_role;

-- Public: what Olo is reading to fill, and what it filled, for the page.
create or replace function public.olo_gaps_recent(p_k int default 12) returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'open', (select coalesce(json_agg(json_build_object('topic', topic, 'asks', asks, 'last_seen', last_seen, 'tries', tries) order by asks desc, last_seen desc), '[]'::json)
             from (select * from public.olo_gaps where filled_at is null order by asks desc, last_seen desc limit least(greatest(p_k, 1), 50)) o),
    'filled', (select coalesce(json_agg(json_build_object('topic', topic, 'asks', asks, 'filled_at', filled_at, 'atoms_added', atoms_added) order by filled_at desc), '[]'::json)
               from (select * from public.olo_gaps where filled_at is not null order by filled_at desc limit least(greatest(p_k, 1), 50)) f),
    'open_count', (select count(*) from public.olo_gaps where filled_at is null),
    'filled_24h', (select count(*) from public.olo_gaps where filled_at > now() - interval '24 hours'),
    'atoms_added_24h', (select coalesce(sum(atoms_added), 0) from public.olo_gaps where filled_at > now() - interval '24 hours')
  );
$$;
grant execute on function public.olo_gaps_recent(int) to anon, authenticated;

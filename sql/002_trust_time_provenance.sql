-- Olo Commons: trust, time, provenance, feedback and retractions.
--
-- Run after sql/001_olo_commons.sql in the Supabase SQL editor (project
-- bfldflbkebyapfagsxnr). Safe to run again: every statement is "if not exists"
-- or "create or replace". Nothing here weakens SECURITY.md: knowledge is still
-- written only by the service role, every new function has explicit grants and
-- revokes, and nothing a client sends is run as SQL.
--
-- What it adds, and why (see docs/TRUST.md):
--   * credibility  0..100  how far to trust an atom: its source's prior, how many
--                           independent sources agree with it, its freshness and
--                           whether its paper was retracted. Computed in SQL from
--                           stored signals so it can be recomputed any time.
--   * status       candidate | verified | disputed | superseded | retracted
--                   verified needs two independent sources or one authoritative
--                   source (trust 90 or more). An atom is never deleted: when its
--                   source page changes it is superseded and linked to the new one.
--   * valid_from, valid_to, observed_at, source_revision, superseded_by
--                   when the fact was true, when we last saw it, which revision of
--                   the source page it came from, and what replaced it.
--   * olo_feedback  sentence-level flags from Olo's apps (web, iPhone, Mac, the
--                   Commons page). A person reviews them; accepted rows become
--                   Zeus training examples. The question itself is never stored.
--   * olo_retractions  DOIs and PubMed ids from the Crossref Retraction Watch
--                   data; atoms whose paper was retracted are hidden from search.
--   * olo_gaps     a per-address daily cap, so nobody can flood what Olo reads next.

-- ---------------------------------------------------------------------------
-- 1. Atoms: time, provenance and trust columns
-- ---------------------------------------------------------------------------
alter table public.olo_atoms add column if not exists status text not null default 'candidate';
alter table public.olo_atoms add column if not exists credibility int not null default 50;
alter table public.olo_atoms add column if not exists corroboration int not null default 0;   -- independent sources agreeing (other than its own)
alter table public.olo_atoms add column if not exists valid_from date;                          -- when the fact began to hold (published_at when unknown)
alter table public.olo_atoms add column if not exists valid_to date;                            -- set when superseded or known to have ended
alter table public.olo_atoms add column if not exists observed_at timestamptz not null default now();  -- last time the source still said this
alter table public.olo_atoms add column if not exists source_revision text;                     -- Wikipedia revision id, Wikidata statement, DOI version
alter table public.olo_atoms add column if not exists superseded_by uuid references public.olo_atoms(id) on delete set null;
alter table public.olo_atoms add column if not exists doi text;                                 -- for the retraction check (arXiv, PubMed, OpenAlex)
alter table public.olo_atoms add column if not exists pmid text;
alter table public.olo_atoms add column if not exists generated boolean not null default false;  -- true = written by a model; never used as a source (model collapse guard)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'olo_atoms_status_chk') then
    alter table public.olo_atoms add constraint olo_atoms_status_chk check (status in ('candidate','verified','disputed','superseded','retracted'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'olo_atoms_credibility_chk') then
    alter table public.olo_atoms add constraint olo_atoms_credibility_chk check (credibility between 0 and 100);
  end if;
end $$;
create index if not exists olo_atoms_status on public.olo_atoms (status);
create index if not exists olo_atoms_observed on public.olo_atoms (observed_at);
create index if not exists olo_atoms_doi on public.olo_atoms (doi) where doi is not null;
create index if not exists olo_atoms_pmid on public.olo_atoms (pmid) where pmid is not null;
-- Backfill once: a fact is assumed to hold from its publication date.
update public.olo_atoms set valid_from = published_at where valid_from is null and published_at is not null;

-- Sources added with this migration. They start disabled: enable each after a run or two.
insert into public.olo_sources (slug, name, kind, homepage, api_base, licence, licence_url, description, trust, enabled) values
 ('wikinews', 'Wikinews', 'encyclopedia', 'https://en.wikinews.org', 'https://en.wikinews.org/w/api.php', 'CC BY 2.5', 'https://creativecommons.org/licenses/by/2.5/', 'Dated news articles written by volunteers since 2004; a historical record with the date on every fact.', 70, false),
 ('openalex', 'OpenAlex', 'papers', 'https://openalex.org', 'https://api.openalex.org', 'CC0 1.0 (metadata)', 'https://docs.openalex.org/additional-help/faq#how-is-openalex-licensed', 'Open index of scholarly works: titles, abstracts, authors, venues, citations and retraction flags.', 85, false),
 ('crossref_retractions', 'Crossref Retraction Watch', 'data', 'https://www.crossref.org/documentation/retrieve-metadata/retraction-watch/', 'https://api.labs.crossref.org/data/retractionwatch', 'CC0 1.0', 'https://creativecommons.org/publicdomain/zero/1.0/', 'The Retraction Watch database, open through Crossref: used to hide atoms whose paper was retracted, never as a source of facts.', 95, false)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Credibility: one function, recomputable, calibrated per source kind.
--    prior (source trust) x corroboration x freshness x integrity.
-- ---------------------------------------------------------------------------
create or replace function public.olo_credibility(p_trust int, p_corroboration int, p_published date, p_observed timestamptz, p_kind text, p_status text)
returns int language sql immutable as $$
  select greatest(0, least(100, round(
    -- source prior: the registry's trust, 0..100
    coalesce(p_trust, 50)
    -- agreement: each independent source adds, with diminishing returns (max +15)
    + least(15, 6 * coalesce(p_corroboration, 0))
    -- freshness: facts that change (news, data) lose up to 20 points over three years; papers and books keep theirs
    - case when p_kind in ('encyclopedia','government','data','other') and p_published is not null
           then least(20, greatest(0, (current_date - p_published) / 55))   -- about 1 point per 55 days
           else 0 end
    -- not seen at its source for a year: we no longer know it still says this
    - case when p_observed < now() - interval '365 days' then 10 else 0 end
    -- integrity: retracted or superseded facts are not to be trusted as current
    - case when p_status = 'retracted' then 60 when p_status = 'superseded' then 30 when p_status = 'disputed' then 20 else 0 end
  )::int));
$$;

-- Recompute credibility and status for one atom (ingester, after insert or re-check).
--   verified: two independent sources agree (corroboration >= 1 means one other source) or the
--             source itself is authoritative (trust >= 90: peer-reviewed papers, public-domain editions, statistics, law)
--   candidate: everything else. disputed/superseded/retracted are set by the ingester and the retraction check and kept.
create or replace function public.olo_rescore_atom(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare a record; n_corr int; st text;
begin
  select x.*, s.trust as src_trust, s.kind as src_kind, s.id as sid into a from public.olo_atoms x join public.olo_sources s on s.id = x.source_id where x.id = p_id;
  if a.id is null then return; end if;
  -- independent agreement: strongly similar atoms (cosine >= 0.85) from other sources
  select count(distinct b.source_id) into n_corr
    from public.olo_links l join public.olo_atoms b on b.id = l.to_atom
   where l.from_atom = p_id and l.relation = 'similar' and l.weight >= 0.85 and b.source_id <> a.sid and b.status <> 'retracted';
  st := a.status;
  if st in ('candidate', 'verified') then
    st := case when n_corr >= 1 or a.src_trust >= 90 then 'verified' else 'candidate' end;
  end if;
  update public.olo_atoms set corroboration = n_corr, status = st,
         credibility = public.olo_credibility(a.src_trust, n_corr, a.published_at, a.observed_at, a.src_kind, st)
   where id = p_id;
end $$;
revoke execute on function public.olo_rescore_atom(uuid) from public, anon, authenticated;
grant execute on function public.olo_rescore_atom(uuid) to service_role;

-- Backfill: score every atom once (cheap: a few thousand rows). Reruns are harmless.
do $$ declare r record; begin
  for r in select id from public.olo_atoms where credibility = 50 and corroboration = 0 loop perform public.olo_rescore_atom(r.id); end loop;
end $$;

-- The ingester calls this when a source page changed: the old atom keeps its text as history,
-- closes its validity, and points at the new one.
create or replace function public.olo_supersede(p_old uuid, p_new uuid) returns void language sql security definer set search_path = public as $$
  update public.olo_atoms set status = 'superseded', superseded_by = p_new, valid_to = current_date,
         credibility = public.olo_credibility((select trust from public.olo_sources where id = source_id), corroboration, published_at, observed_at, (select kind from public.olo_sources where id = source_id), 'superseded')
   where id = p_old and p_old <> p_new;
$$;
revoke execute on function public.olo_supersede(uuid, uuid) from public, anon, authenticated;
grant execute on function public.olo_supersede(uuid, uuid) to service_role;

-- Atoms the ingester should re-check at their source: oldest observed first, for sources that have revisions.
create or replace function public.olo_recheck_batch(p_slug text, p_n int default 5) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', a.id, 'external_id', a.external_id, 'url', a.url, 'title', a.title, 'source_revision', a.source_revision, 'content_hash', a.content_hash, 'lang', a.lang) order by a.observed_at), '[]'::json)
  from (select a.* from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
         where s.slug = p_slug and a.status in ('candidate','verified','disputed') and a.observed_at < now() - interval '7 days'
         order by a.observed_at limit least(greatest(p_n, 1), 25)) a;
$$;
revoke execute on function public.olo_recheck_batch(text, int) from public, anon, authenticated;
grant execute on function public.olo_recheck_batch(text, int) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Search and export carry trust and time, and hide what should not be served as current.
-- ---------------------------------------------------------------------------
create or replace function public.olo_search_text(p_q text, p_k int default 10) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', a.id, 'title', a.title, 'summary', left(coalesce(a.summary, ''), 400), 'url', a.url, 'source', s.name, 'source_slug', s.slug, 'source_kind', s.kind, 'licence', a.licence, 'published_at', a.published_at, 'retrieved_at', a.retrieved_at,
           'observed_at', a.observed_at, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'status', a.status, 'credibility', a.credibility, 'corroboration', a.corroboration, 'source_revision', a.source_revision, 'rank', r.rank) order by r.rank desc), '[]'::json)
  from (select id, ts_rank(tsv, websearch_to_tsquery('english', left(coalesce(p_q, ''), 200))) as rank from public.olo_atoms
         where tsv @@ websearch_to_tsquery('english', left(coalesce(p_q, ''), 200)) and status not in ('retracted','superseded') and not generated
         order by rank desc limit least(greatest(p_k, 1), 50)) r
  join public.olo_atoms a on a.id = r.id join public.olo_sources s on s.id = a.source_id;
$$;
grant execute on function public.olo_search_text(text, int) to anon, authenticated;

create or replace function public.olo_match(p_embedding extensions.vector(384), p_k int default 8, p_min float default 0.55) returns json language sql stable security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object('id', a.id, 'title', a.title, 'summary', left(coalesce(a.summary, ''), 600), 'content', left(coalesce(a.content, ''), 2000), 'url', a.url, 'source', s.name, 'source_slug', s.slug, 'source_kind', s.kind, 'licence', a.licence, 'published_at', a.published_at, 'retrieved_at', a.retrieved_at,
           'observed_at', a.observed_at, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'status', a.status, 'credibility', a.credibility, 'corroboration', a.corroboration, 'source_revision', a.source_revision, 'similarity', m.sim) order by m.sim desc), '[]'::json)
  from (select id, 1 - (embedding <=> p_embedding) as sim from public.olo_atoms where embedding is not null and status not in ('retracted','superseded') and not generated order by embedding <=> p_embedding limit least(greatest(p_k, 1), 30)) m
  join public.olo_atoms a on a.id = m.id join public.olo_sources s on s.id = a.source_id
  where m.sim >= p_min;
$$;
revoke execute on function public.olo_match(extensions.vector, int, float) from public, anon, authenticated;
grant execute on function public.olo_match(extensions.vector, int, float) to service_role;

create or replace function public.olo_atom(p_id uuid) returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'atom', (select json_build_object('id', a.id, 'title', a.title, 'summary', a.summary, 'content', left(coalesce(a.content, ''), 6000), 'url', a.url, 'source', s.name, 'source_slug', s.slug, 'source_kind', s.kind, 'licence', a.licence, 'licence_url', s.licence_url, 'authors', a.authors, 'published_at', a.published_at, 'retrieved_at', a.retrieved_at, 'content_hash', a.content_hash, 'quality', a.quality,
                               'status', a.status, 'credibility', a.credibility, 'corroboration', a.corroboration, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'observed_at', a.observed_at, 'source_revision', a.source_revision, 'superseded_by', a.superseded_by, 'doi', a.doi)
              from public.olo_atoms a join public.olo_sources s on s.id = a.source_id where a.id = p_id),
    'neighbours', coalesce((select json_agg(json_build_object('id', b.id, 'title', b.title, 'source', s2.slug, 'weight', l.weight, 'relation', l.relation, 'status', b.status) order by l.weight desc)
              from public.olo_links l join public.olo_atoms b on b.id = l.to_atom join public.olo_sources s2 on s2.id = b.source_id where l.from_atom = p_id limit 12), '[]'::json)
  );
$$;
grant execute on function public.olo_atom(uuid) to anon, authenticated;

-- Export (used by the snapshot and by builders): every atom including superseded and retracted ones, with status, so a
-- consumer can show history or hide it. The snapshot keeps only current atoms (scripts/build_snapshot.py).
create or replace function public.olo_export(p_after timestamptz default '1970-01-01', p_limit int default 500) returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'atoms', coalesce((select json_agg(json_build_object('id', a.id, 'title', a.title, 'summary', a.summary, 'content', a.content, 'url', a.url, 'source', s.slug, 'source_kind', s.kind, 'licence', a.licence, 'authors', a.authors, 'published_at', a.published_at, 'content_hash', a.content_hash, 'quality', a.quality, 'retrieved_at', a.retrieved_at, 'created_at', a.created_at,
                               'status', a.status, 'credibility', a.credibility, 'corroboration', a.corroboration, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'observed_at', a.observed_at, 'source_revision', a.source_revision, 'superseded_by', a.superseded_by, 'doi', a.doi) order by a.created_at)
                 from (select * from public.olo_atoms where created_at > p_after and not generated order by created_at limit least(greatest(p_limit, 1), 500)) a join public.olo_sources s on s.id = a.source_id), '[]'::json),
    'next_after', (select max(created_at) from (select created_at from public.olo_atoms where created_at > p_after and not generated order by created_at limit least(greatest(p_limit, 1), 500)) x),
    'licence_note', 'Each atom carries its own licence; the compilation is CC BY-SA 4.0. Attribute Olo Commons by Helius Network.'
  );
$$;
grant execute on function public.olo_export(timestamptz, int) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Feedback: what people flag, reviewed by a person, then taught to Zeus.
--    Only the olo-feedback function (service role) writes; clients cannot read it:
--    a flag may carry a few words of someone's answer. Accepted rows are exported
--    by zeus/feedback_to_gold.py with the service key during training.
-- ---------------------------------------------------------------------------
create table if not exists public.olo_feedback (
  id uuid primary key default gen_random_uuid(),
  at timestamptz not null default now(),
  client text not null check (client in ('web','ios','macos','commons','api')),
  answer_source text not null check (answer_source in ('olo','commons','offline')),
  claim text not null check (length(claim) between 3 and 600),          -- the sentence that was checked
  verdict_given text not null check (verdict_given in ('supported','contradicted','not_covered')),
  verdict_user text not null check (verdict_user in ('supported','contradicted','not_covered','wrong_source','unclear')),
  passages jsonb not null default '[]'::jsonb,                           -- [{atom uuid or url, quote}] the sentence was checked against
  evidence_quote text check (evidence_quote is null or length(evidence_quote) <= 600),
  note text check (note is null or length(note) <= 500),
  ip_hash text,                                                           -- daily-salted, for the rate limit only
  status text not null default 'new' check (status in ('new','accepted','rejected','duplicate')),
  reviewed_at timestamptz,
  reviewer_note text,
  used_in text                                                            -- the Zeus version that first trained on it
);
create index if not exists olo_feedback_status on public.olo_feedback (status, at desc);
create index if not exists olo_feedback_ip on public.olo_feedback (ip_hash, at desc);
alter table public.olo_feedback enable row level security;
revoke all on public.olo_feedback from public, anon, authenticated;
grant select, insert, update, delete on public.olo_feedback to service_role;

-- Public counts only, for the pages ("412 flags reviewed, 118 taught to Zeus").
create or replace function public.olo_feedback_stats() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'total', (select count(*) from public.olo_feedback),
    'new', (select count(*) from public.olo_feedback where status = 'new'),
    'accepted', (select count(*) from public.olo_feedback where status = 'accepted'),
    'rejected', (select count(*) from public.olo_feedback where status = 'rejected'),
    'taught', (select count(*) from public.olo_feedback where used_in is not null),
    'last_7d', (select count(*) from public.olo_feedback where at > now() - interval '7 days'),
    'disagreement_rate_30d', (select round(100.0 * count(*) filter (where verdict_user <> verdict_given and verdict_user in ('supported','contradicted','not_covered')) / greatest(count(*), 1), 1) from public.olo_feedback where at > now() - interval '30 days')
  );
$$;
grant execute on function public.olo_feedback_stats() to anon, authenticated;

-- Stats gain the verified share, which is the number to publish (not the raw count).
create or replace function public.olo_trust_stats() returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'atoms', (select count(*) from public.olo_atoms),
    'verified', (select count(*) from public.olo_atoms where status = 'verified'),
    'candidate', (select count(*) from public.olo_atoms where status = 'candidate'),
    'disputed', (select count(*) from public.olo_atoms where status = 'disputed'),
    'superseded', (select count(*) from public.olo_atoms where status = 'superseded'),
    'retracted', (select count(*) from public.olo_atoms where status = 'retracted'),
    'verified_share', (select round(100.0 * count(*) filter (where status = 'verified') / greatest(count(*), 1), 1) from public.olo_atoms),
    'median_credibility', (select percentile_cont(0.5) within group (order by credibility) from public.olo_atoms where status in ('candidate','verified')),
    'rechecked_7d', (select count(*) from public.olo_atoms where observed_at > now() - interval '7 days' and observed_at > created_at + interval '1 hour'),
    'feedback_open', (select count(*) from public.olo_feedback where status = 'new'),
    'feedback_accepted', (select count(*) from public.olo_feedback where status = 'accepted')
  );
$$;
grant execute on function public.olo_trust_stats() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Retractions: hide atoms whose paper was retracted (never delete; keep the record).
-- ---------------------------------------------------------------------------
create table if not exists public.olo_retractions (
  doi text primary key,
  pmid text,
  retraction_doi text,
  nature text,                 -- Retraction, Correction, Expression of concern (as given by the dataset)
  retracted_on date,
  reason text,
  loaded_at timestamptz not null default now()
);
create index if not exists olo_retractions_pmid on public.olo_retractions (pmid) where pmid is not null;
alter table public.olo_retractions enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='olo_retractions' and policyname='olo_retractions_read') then create policy olo_retractions_read on public.olo_retractions for select using (true); end if;
end $$;
grant select on public.olo_retractions to anon, authenticated;
grant select, insert, update, delete on public.olo_retractions to service_role;

-- Apply the retraction list to the atoms: called by the weekly check after loading rows. Returns how many atoms changed.
create or replace function public.olo_apply_retractions() returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with hit as (
    update public.olo_atoms a set status = 'retracted', valid_to = coalesce(r.retracted_on, current_date),
           credibility = public.olo_credibility((select trust from public.olo_sources where id = a.source_id), a.corroboration, a.published_at, a.observed_at, (select kind from public.olo_sources where id = a.source_id), 'retracted')
      from public.olo_retractions r
     where a.status <> 'retracted' and r.nature ilike 'retraction%'
       and ((a.doi is not null and lower(a.doi) = lower(r.doi)) or (a.pmid is not null and r.pmid is not null and a.pmid = r.pmid))
     returning a.id)
  select count(*) into n from hit;
  return n;
end $$;
revoke execute on function public.olo_apply_retractions() from public, anon, authenticated;
grant execute on function public.olo_apply_retractions() to service_role;

-- ---------------------------------------------------------------------------
-- 6. Gaps: a daily cap per hashed address, so nobody can steer what Olo reads next.
--    The old one-argument form stays (other callers), capped at nothing; the answer
--    function now passes its daily-salted address hash and is capped at 20 topics a day.
-- ---------------------------------------------------------------------------
create table if not exists public.olo_gap_asks (
  ip_hash text not null,
  day date not null default current_date,
  asks int not null default 0,
  primary key (ip_hash, day)
);
alter table public.olo_gap_asks enable row level security;
revoke all on public.olo_gap_asks from public, anon, authenticated;
grant select, insert, update, delete on public.olo_gap_asks to service_role;

create or replace function public.olo_record_gap(p_q text, p_ip_hash text) returns void language plpgsql security definer set search_path = public as $$
declare t text; h text; n int;
begin
  if p_ip_hash is not null then
    insert into public.olo_gap_asks (ip_hash, day, asks) values (p_ip_hash, current_date, 1)
    on conflict (ip_hash, day) do update set asks = public.olo_gap_asks.asks + 1 returning asks into n;
    if n > 20 then return; end if;
  end if;
  t := public.olo_gap_topic(p_q);
  if t is null then return; end if;
  t := array_to_string((regexp_split_to_array(t, ' '))[1:6], ' ');
  h := md5(t);
  insert into public.olo_gaps (topic, topic_hash) values (t, h)
  on conflict (topic_hash) do update set asks = public.olo_gaps.asks + 1, last_seen = now(), filled_at = null;
  -- keep the cap table small
  delete from public.olo_gap_asks where day < current_date - 2;
end $$;
revoke execute on function public.olo_record_gap(text, text) from public, anon, authenticated;
grant execute on function public.olo_record_gap(text, text) to service_role;

-- A gap needs to be asked by more than one address before it drives ingestion, unless it is old and unfilled.
create or replace function public.olo_next_gap() returns json language sql stable security definer set search_path = public as $$
  select to_json(g) from (
    select id, topic, asks, tries from public.olo_gaps
    where filled_at is null and tries < 5 and (last_tried_at is null or last_tried_at < now() - interval '1 day')
      and (asks >= 2 or first_seen < now() - interval '2 days')
    order by asks desc, last_seen desc limit 1
  ) g;
$$;
revoke execute on function public.olo_next_gap() from public, anon, authenticated;
grant execute on function public.olo_next_gap() to service_role;

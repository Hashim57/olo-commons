-- Olo Commons: cross-source deduplication with provenance kept.
--
-- Run after sql/002_trust_time_provenance.sql in the Supabase SQL editor (project
-- bfldflbkebyapfagsxnr). Safe to run again: every statement is "if not exists",
-- "create or replace" or guarded. If sql/002 is ever run again, run this file
-- again afterwards: 002 redefines olo_rescore_atom without sightings.
--
-- Why (see docs/TRUST.md "Duplicates"): the same paper reaches the Commons from
-- arXiv, PubMed and OpenAlex. The ingester (functions/olo-ingest/dedup.ts) now
-- recognises a candidate from one source that is the same atom as one already
-- stored from ANOTHER source (same DOI, same PMID, or the same or near-identical
-- normalised text under the same title). It does not insert a second atom; it
-- records the second source as a sighting of the first. Nothing is lost:
--   * the sighting keeps the second source, its url, licence, identifiers and
--     why it was judged a duplicate;
--   * olo_rescore_atom counts sightings from other sources as corroboration, the
--     same signal a strongly similar atom from another source gave before, so the
--     verified count does not drop because copies stopped being stored twice.
-- Nothing here weakens SECURITY.md: RLS is on for the new table, only the service
-- role writes, and every new function has explicit grants and revokes.

-- ---------------------------------------------------------------------------
-- 1. Atoms: a normalised-text hash for the exact-match lookup, and duplicate_of
--    for duplicates merged after the fact (section 4).
-- ---------------------------------------------------------------------------
alter table public.olo_atoms add column if not exists norm_hash text;      -- sha256 of normalised title + body (dedup.ts normKey); not unique: one source may hold homonyms
alter table public.olo_atoms add column if not exists duplicate_of uuid references public.olo_atoms(id) on delete set null;
create index if not exists olo_atoms_norm_hash on public.olo_atoms (norm_hash) where norm_hash is not null;
-- DOIs are case-insensitive; the retraction check compares lower(doi). The ingester stores them lower-cased already.
create index if not exists olo_atoms_doi_lower on public.olo_atoms (lower(doi)) where doi is not null;

-- ---------------------------------------------------------------------------
-- 2. Sightings: every other place an atom was found. Public provenance, like the atoms.
-- ---------------------------------------------------------------------------
create table if not exists public.olo_atom_sightings (
  id uuid primary key default gen_random_uuid(),
  atom_id uuid not null references public.olo_atoms(id) on delete cascade,
  source_id uuid not null references public.olo_sources(id) on delete restrict,
  url text not null check (url ~ '^https?://' and length(url) <= 2000),
  external_id text,
  doi text,
  pmid text,
  title text check (title is null or length(title) <= 300),
  licence text,
  reason text not null check (reason in ('same_doi','same_pmid','same_text','near_text','merged')),
  similarity real,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (atom_id, url)
);
create index if not exists olo_atom_sightings_source on public.olo_atom_sightings (source_id);
alter table public.olo_atom_sightings enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'olo_atom_sightings' and policyname = 'olo_atom_sightings_read') then
    create policy olo_atom_sightings_read on public.olo_atom_sightings for select using (true);
  end if;
end $$;
revoke all on public.olo_atom_sightings from public, anon, authenticated;
grant select on public.olo_atom_sightings to anon, authenticated;
grant select, insert, update, delete on public.olo_atom_sightings to service_role;

-- ---------------------------------------------------------------------------
-- 3. Corroboration counts sightings from other sources.
--    Same rule as sql/002 otherwise: distinct OTHER sources, strongly similar
--    links (cosine >= 0.85) to atoms that are not retracted, plus sightings.
-- ---------------------------------------------------------------------------
create or replace function public.olo_rescore_atom(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare a record; n_corr int; st text;
begin
  select x.*, s.trust as src_trust, s.kind as src_kind, s.id as sid into a from public.olo_atoms x join public.olo_sources s on s.id = x.source_id where x.id = p_id;
  if a.id is null then return; end if;
  select count(distinct o.source_id) into n_corr from (
    select b.source_id
      from public.olo_links l join public.olo_atoms b on b.id = l.to_atom
     where l.from_atom = p_id and l.relation = 'similar' and l.weight >= 0.85 and b.source_id <> a.sid and b.status <> 'retracted'
    union
    select g.source_id from public.olo_atom_sightings g where g.atom_id = p_id and g.source_id <> a.sid
  ) o;
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

-- The ingester calls this instead of inserting a duplicate: record (or refresh) the sighting, then rescore the atom.
create or replace function public.olo_record_sighting(p_atom uuid, p_source uuid, p_url text, p_external_id text, p_doi text, p_pmid text, p_title text, p_licence text, p_reason text, p_similarity real)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.olo_atom_sightings (atom_id, source_id, url, external_id, doi, pmid, title, licence, reason, similarity)
  values (p_atom, p_source, left(p_url, 2000), left(p_external_id, 200), lower(left(p_doi, 300)), left(p_pmid, 20), left(p_title, 300), left(p_licence, 300), p_reason, p_similarity)
  on conflict (atom_id, url) do update set last_seen_at = now();
  perform public.olo_rescore_atom(p_atom);
end $$;
revoke execute on function public.olo_record_sighting(uuid, uuid, text, text, text, text, text, text, text, real) from public, anon, authenticated;
grant execute on function public.olo_record_sighting(uuid, uuid, text, text, text, text, text, text, text, real) to service_role;

-- Public read: where else an atom was found (for the atom page and the API).
create or replace function public.olo_atom_sightings(p_id uuid) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('source', s.slug, 'source_name', s.name, 'url', g.url, 'licence', g.licence, 'doi', g.doi, 'pmid', g.pmid, 'reason', g.reason, 'similarity', g.similarity, 'first_seen_at', g.first_seen_at, 'last_seen_at', g.last_seen_at) order by g.first_seen_at), '[]'::json)
  from (select * from public.olo_atom_sightings where atom_id = p_id order by first_seen_at limit 50) g join public.olo_sources s on s.id = g.source_id;
$$;
revoke execute on function public.olo_atom_sightings(uuid) from public;
grant execute on function public.olo_atom_sightings(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Duplicates stored before this file: report, and merge only when asked.
--    Only identifier matches (same DOI or same PMID) across DIFFERENT sources are
--    merged; same-source pairs (arXiv versions) and text look-alikes are left alone.
--    A merge deletes nothing: the later copy becomes a sighting of the earliest
--    one, keeps its row and url, and is marked superseded with duplicate_of and
--    superseded_by pointing at the earliest copy, so search and the snapshot stop
--    serving it twice while the export keeps it with its status. Rerunnable: a
--    second run finds nothing left to merge.
--
--      select * from public.olo_merge_duplicates(false);   -- report only (the default)
--      select * from public.olo_merge_duplicates(true);    -- merge; a person runs this deliberately
-- ---------------------------------------------------------------------------
create or replace function public.olo_merge_duplicates(p_apply boolean default false)
returns table (canonical uuid, duplicate uuid, match_key text, applied boolean)
language plpgsql security definer set search_path = public as $$
declare r record; did boolean;
begin
  for r in
    with cur as (
      select id, source_id, created_at, lower(doi) as d, pmid as p
        from public.olo_atoms
       where status in ('candidate','verified','disputed') and (doi is not null or pmid is not null)),
    keyed as (
      select id, source_id, created_at, d, p, 'doi:' || d as k from cur where d is not null
      union all
      select id, source_id, created_at, d, p, 'pmid:' || p from cur where p is not null),
    ranked as (
      select k, id, source_id, d, p,
             first_value(id) over w as c_id, first_value(source_id) over w as c_src,
             first_value(d) over w as c_d, first_value(p) over w as c_p
        from keyed window w as (partition by k order by created_at, id))
    select distinct on (id) c_id, id, k
      from ranked
     where id <> c_id and source_id <> c_src
       and not (d is not null and c_d is not null and d <> c_d)     -- conflicting identifiers: one record is wrong, leave both
       and not (p is not null and c_p is not null and p <> c_p)
     order by id, k
  loop
    did := false;
    -- the canonical atom must still be current (an earlier pair in this run may have merged it)
    if p_apply and exists (select 1 from public.olo_atoms where id = r.c_id and status in ('candidate','verified','disputed')) then
      insert into public.olo_atom_sightings (atom_id, source_id, url, external_id, doi, pmid, title, licence, reason, similarity, first_seen_at)
      select r.c_id, a.source_id, a.url, a.external_id, lower(a.doi), a.pmid, left(a.title, 300), a.licence, 'merged', 1, a.created_at
        from public.olo_atoms a where a.id = r.id
      on conflict (atom_id, url) do nothing;
      update public.olo_atoms a set status = 'superseded', superseded_by = r.c_id, duplicate_of = r.c_id,
             credibility = public.olo_credibility((select trust from public.olo_sources where id = a.source_id), a.corroboration, a.published_at, a.observed_at, (select kind from public.olo_sources where id = a.source_id), 'superseded')
       where a.id = r.id and a.status in ('candidate','verified','disputed');
      perform public.olo_rescore_atom(r.c_id);
      did := true;
    end if;
    canonical := r.c_id; duplicate := r.id; match_key := r.k; applied := did;
    return next;
  end loop;
end $$;
revoke execute on function public.olo_merge_duplicates(boolean) from public, anon, authenticated;
grant execute on function public.olo_merge_duplicates(boolean) to service_role;

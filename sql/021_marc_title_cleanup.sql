-- Olo Commons: take the MARC subtitle marker out of Project Gutenberg titles.
--
-- Run in the Supabase SQL editor (project bfldflbkebyapfagsxnr) after sql/020.
-- Safe to run again: "create or replace" and updates that find nothing the
-- second time. Nothing here weakens SECURITY.md: no table changes, RLS stays
-- on, the new function is server-only with explicit grants and revokes, and
-- nothing is deleted.
--
-- Why: gutendex copies each book's title from the catalogue's MARC 245 field,
-- and for about one book in fourteen the subtitle marker comes with it:
-- "The unknown seven : $b A detective story", "Peter Pan : $b [Peter and
-- Wendy]", "Liebe ist ewig : $b Roman". On the 2026-11-17 snapshot 49 of the
-- 665 gutenberg titles carry it, and 1 summary (the fallback summary, when
-- gutendex has none, is built from the title). The reader sees it on the page and in every answer
-- that cites the book, and Zeus learns the title with it. The ingester writes
-- the title as a reader would from the same date (marcTitle in
-- functions/olo-ingest/sources.ts); this file does the same for what is
-- already stored.

-- ---------------------------------------------------------------------------
-- 1. The same rewrite as marcTitle(): the subtitle marker becomes a colon,
--    any other subfield code ($a, $c, $n, $p) goes with its spaces, runs of
--    spaces close up. Gutenberg only: an arXiv title's "$p$" is mathematics.
-- ---------------------------------------------------------------------------
create or replace function public.olo_marc_title(p_title text)
returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(p_title, ''), '\s*:\s*\$b\s+', ': ', 'g'), '\s*\$[a-z]\s+', ' ', 'g'), '\s+', ' ', 'g'))
$$;

revoke execute on function public.olo_marc_title(text) from public, anon, authenticated;
grant execute on function public.olo_marc_title(text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Look before changing: how many titles and summaries the rule would
--    rewrite, per source. Expect 49 titles and 1 summary, all gutenberg, on
--    the 2026-11-17 snapshot (run twice against a local Postgres 16 holding
--    all 11,861 of its texts: 49 rows changed, the second run changes none).
-- ---------------------------------------------------------------------------
select s.slug,
       count(*) filter (where a.title ~ '\s*:\s*\$b\s+') as titles,
       count(*) filter (where a.summary ~ '\s*:\s*\$b\s+') as summaries,
       count(*) filter (where a.content ~ '\s*:\s*\$b\s+') as contents
from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
where a.title ~ '\s*:\s*\$b\s+' or a.summary ~ '\s*:\s*\$b\s+' or a.content ~ '\s*:\s*\$b\s+'
group by s.slug
order by s.slug;

-- ---------------------------------------------------------------------------
-- 3. Rewrite them, from the source the rule was written for. content_hash is
--    sha256 of title, summary and content joined by newlines (the ingester's
--    store(), summary and content as '' when null), so it is computed again
--    the same way and the duplicate check keeps matching. norm_hash (sql/009)
--    is left as it is: its normalisation lives in dedup.ts and is not
--    repeated here, so for these 49 atoms the cross-source check falls back
--    to the identifier and embedding checks until they are next observed.
-- ---------------------------------------------------------------------------
with fixed as (
  select a.id,
         public.olo_marc_title(a.title) as title,
         case when a.summary is null then null else public.olo_marc_title(a.summary) end as summary,
         case when a.content is null then null else regexp_replace(a.content, '\s*:\s*\$b\s+', ': ', 'g') end as content
  from public.olo_atoms a join public.olo_sources s on s.id = a.source_id
  where s.slug = 'gutenberg'
    and (a.title ~ '\s*:\s*\$b\s+' or a.summary ~ '\s*:\s*\$b\s+' or a.content ~ '\s*:\s*\$b\s+')
)
update public.olo_atoms a
set title = f.title,
    summary = f.summary,
    content = f.content,
    content_hash = encode(sha256(convert_to(f.title || E'\n' || coalesce(f.summary, '') || E'\n' || coalesce(f.content, ''), 'UTF8')), 'hex')
from fixed f
where a.id = f.id
  and not exists (select 1 from public.olo_atoms o where o.id <> a.id and o.content_hash = encode(sha256(convert_to(f.title || E'\n' || coalesce(f.summary, '') || E'\n' || coalesce(f.content, ''), 'UTF8')), 'hex'));

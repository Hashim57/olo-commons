// supabase/functions/olo-ingest/index.ts
//
// Grows Olo Commons. Runs every 15 minutes from pg_cron (or by hand with the
// service key). For each enabled source it discovers a few new items from that
// source's own public API, turns each into an atom with provenance, embeds it
// with gte-small INSIDE Supabase (no external AI key, nothing leaves the
// project), inserts it if the content hash is new, and links it to its nearest
// neighbours.
//
// Gap filling: before the random walk, the run takes the most-asked open gap
// (a bag of topic words recorded by olo-answer when a question came back
// uncovered, see olo_gaps in sql/001) and searches the sources that have a
// search API for it, spending up to a third of the budget. So Olo learns from
// being used: what people ask and it cannot answer, it reads next.
//
// Deploy:  supabase functions deploy olo-ingest --no-verify-jwt
// Only the service role may call it. Sources are read from olo_sources; a
// source that is not enabled there is never fetched, whatever the code says.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { clean } from './text.ts';
import { dataGovApiBase, dataGovCandidates, dataGovSearchUrl, DATAGOV_TOPICS } from './datagov.ts';
import { errorNote, type RunError } from './runlog.ts';
import { archiveCandidates, arxivCandidates, gutenbergCandidates, openalexCandidates, pubmedCandidates, pubmedSearchIds, searchUrl, wikiCandidate, wikidataCandidates, wikidataSearchIds, wikinewsCandidates, wikiSearchTitles, type Candidate } from './sources.ts';
import { permalink, planRecheck } from './recheck.ts';

const UA = 'OloCommons/1.0 (+https://heliusnetwork.app/olo; hello@heliusnetwork.com)';
const MAX_CONTENT = 8000;      // characters of plain text kept per atom
const EMBED_CHARS = 1500;      // characters fed to the embedding model
const LINK_K = 5;              // neighbours linked per new atom
const MIN_LINK = 0.72;         // cosine similarity needed to make a link
const AGREE = 0.85;            // similarity at which a neighbour from another source counts as agreement (sql/002 olo_rescore_atom)
const DAILY_CAP = 400;         // new atoms per source per day: a flood from one source is a sign something is wrong, not of knowledge
const RECHECK_N = 3;           // atoms re-read at their source per run (oldest observed first)

// The registry row a connector is called with, so a connector can read its own api_base.
type Source = { id: string; slug: string; kind?: string | null; api_base?: string | null; trust: number; licence?: string | null; atoms?: number | null };

function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }); }
async function sha256(s: string) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)); return Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join(''); }
async function get(url: string, accept = 'application/json') { const r = await fetch(url, { headers: { 'User-Agent': UA, Accept: accept }, signal: AbortSignal.timeout(8000) }); if (!r.ok) throw new Error(`${r.status} ${url}`); return accept.includes('json') ? r.json() : r.text(); }
const pick = (arr: any[], n: number) => arr.sort(() => Math.random() - 0.5).slice(0, n);

/* ---------- discovery per source: each returns a few random candidates from the source's own API ---------- */
async function wikiRandom(lang: string, n: number): Promise<Candidate[]> {
  const out: Candidate[] = [];
  for (let i = 0; i < n; i++) {
    try { const c = wikiCandidate(await get(`https://${lang}.wikipedia.org/api/rest_v1/page/random/summary`), lang); if (c) out.push(c); } catch (_) {}
  }
  return out;
}
async function wikiByTitles(lang: string, titles: string[], n: number): Promise<Candidate[]> {
  const out: Candidate[] = [];
  for (const t of titles) {
    if (out.length >= n) break;
    try { const c = wikiCandidate(await get(`https://${lang}.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(t.replace(/ /g, '_'))}`), lang); if (c) out.push(c); } catch (_) {}
  }
  return out;
}
async function wikidataByIds(ids: string[], n: number): Promise<Candidate[]> {
  if (!ids.length) return [];
  const e: any = await get(`https://www.wikidata.org/w/api.php?action=wbgetentities&ids=${ids.slice(0, 20).join('|')}&props=info|labels|descriptions|sitelinks&languages=en&format=json`);
  return wikidataCandidates(e, ids, n);
}
async function pubmedByIds(ids: string[]): Promise<Candidate[]> {
  if (!ids.length) return [];
  const xml: string = await get(`https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=${ids.join(',')}&rettype=abstract&retmode=xml`, 'text/xml');
  return pubmedCandidates(xml);
}

const discover: Record<string, (n: number, src: Source) => Promise<Candidate[]>> = {
  wikipedia: (n) => wikiRandom('en', n),
  wikipedia_es: (n) => wikiRandom('es', n),
  // data.gov dataset descriptions through the catalogue API v4 (datagov.ts). The
  // CKAN API this used to call was switched off in 2026, which is why the source
  // never added an atom. A key from api.data.gov goes in the DATAGOV_API_KEY
  // secret; without one DEMO_KEY is used, which allows 30 calls an hour, more than
  // one call every 15 minutes needs. Only openly licensed, public datasets are kept.
  async data_gov(n, src) {
    const api = dataGovApiBase(src.api_base);
    const topic = DATAGOV_TOPICS[Math.floor(Math.random() * DATAGOV_TOPICS.length)];
    const key = Deno.env.get('DATAGOV_API_KEY') || 'DEMO_KEY';
    const r = await fetch(dataGovSearchUrl(api, topic, Math.min(n * 4, 40)), { headers: { 'User-Agent': UA, Accept: 'application/json', 'X-Api-Key': key }, signal: AbortSignal.timeout(8000) });
    if (!r.ok) throw new Error(`data.gov v4 ${r.status}${r.status === 403 ? ' (api.data.gov key missing or invalid: set DATAGOV_API_KEY)' : r.status === 429 ? ' (api.data.gov rate limit: set DATAGOV_API_KEY to a personal key)' : ''}`);
    return pick(dataGovCandidates(await r.json(), n * 3), n);
  },
  async wikidata(n) {
    const r: any = await get(`https://www.wikidata.org/w/api.php?action=query&list=random&rnnamespace=0&rnlimit=${Math.min(n * 2, 20)}&format=json`);
    const ids = (r.query?.random || []).map((x: any) => x.title).filter((t: string) => /^Q\d+$/.test(t));
    return wikidataByIds(ids, n);
  },
  async archive_org(n) {
    const page = 1 + Math.floor(Math.random() * 200);
    const r: any = await get(`https://archive.org/advancedsearch.php?q=mediatype%3Atexts+AND+description%3A*&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=description&fl%5B%5D=creator&fl%5B%5D=date&fl%5B%5D=licenseurl&rows=${n * 2}&page=${page}&output=json`);
    return pick(archiveCandidates(r.response?.docs || []), n);
  },
  async arxiv(n) {
    const cats = ['cs.AI', 'cs.LG', 'cs.CR', 'q-bio', 'physics.soc-ph', 'econ', 'stat.ML', 'cs.CY', 'eess.SP', 'math.OC'];
    const cat = cats[Math.floor(Math.random() * cats.length)];
    const xml: string = await get(`https://export.arxiv.org/api/query?search_query=cat:${cat}&sortBy=submittedDate&sortOrder=descending&start=${Math.floor(Math.random() * 50)}&max_results=${n}`, 'application/atom+xml');
    return arxivCandidates(xml);
  },
  async gutenberg(n) {
    const r: any = await get(`https://gutendex.com/books?page=${1 + Math.floor(Math.random() * 60)}`);
    return pick(gutenbergCandidates(r.results || []), n);
  },
  // Wikinews: random articles in the main namespace, with the intro and the page's latest revision id.
  async wikinews(n) {
    const r: any = await get(`https://en.wikinews.org/w/api.php?action=query&generator=random&grnnamespace=0&grnlimit=${Math.min(n * 2, 20)}&prop=extracts|info&exintro=1&explaintext=1&exlimit=${Math.min(n * 2, 20)}&inprop=url&format=json`);
    return wikinewsCandidates(r, n);
  },
  // OpenAlex: a random sample of open-access works with abstracts. The optional OPENALEX_KEY raises the daily budget; the mailto puts us in the polite pool.
  async openalex(n, src) {
    const api = (src.api_base || 'https://api.openalex.org').replace(/\/+$/, '');
    const key = Deno.env.get('OPENALEX_KEY') || '';
    const r: any = await get(`${api}/works?filter=has_abstract:true,is_oa:true,is_retracted:false,type:article&sample=${Math.min(n * 2, 25)}&seed=${Math.floor(Math.random() * 1e6)}&per-page=${Math.min(n * 2, 25)}&select=id,doi,title,abstract_inverted_index,authorships,publication_date,primary_location,is_retracted,open_access&mailto=hello@heliusnetwork.com${key ? `&api_key=${encodeURIComponent(key)}` : ''}`);
    return openalexCandidates(r?.results || [], n);
  },
  async pubmed(n) {
    const terms = ['review[pt] AND open access[filter]', 'public health[MeSH] AND review[pt]', 'nutrition[MeSH] AND review[pt]', 'exercise[MeSH] AND review[pt]', 'climate change[MeSH]', 'vaccination[MeSH] AND review[pt]'];
    const term = terms[Math.floor(Math.random() * terms.length)];
    const s: any = await get(`https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=${encodeURIComponent(term)}&retmax=${n}&retstart=${Math.floor(Math.random() * 500)}&sort=pub_date&retmode=json`);
    return pubmedByIds(pubmedSearchIds(s));
  },
};

/* ---------- search per source, for gap filling: the same mappers, a topic instead of chance ---------- */
const search: Record<string, (topic: string, n: number) => Promise<Candidate[]>> = {
  async wikipedia(topic, n) { const r: any = await get(searchUrl('wikipedia', topic, n * 2)!); return wikiByTitles('en', wikiSearchTitles(r), n); },
  async wikipedia_es(topic, n) { const r: any = await get(searchUrl('wikipedia_es', topic, n * 2)!); return wikiByTitles('es', wikiSearchTitles(r), n); },
  async wikidata(topic, n) { const r: any = await get(searchUrl('wikidata', topic, n * 2)!); return wikidataByIds(wikidataSearchIds(r), n); },
  async arxiv(topic, n) { const xml: string = await get(searchUrl('arxiv', topic, n)!, 'application/atom+xml'); return arxivCandidates(xml); },
  async pubmed(topic, n) { const s: any = await get(searchUrl('pubmed', topic, n)!); return pubmedByIds(pubmedSearchIds(s)); },
  async wikinews(topic, n) { const r: any = await get(searchUrl('wikinews', topic, n)!); return wikinewsCandidates(r, n); },
  async openalex(topic, n) { const r: any = await get(searchUrl('openalex', topic, n)!); return openalexCandidates(r?.results || [], n); },
};

function quality(c: Candidate, trust: number) {
  let q = trust;
  if (!c.summary || c.summary.length < 120) q -= 15;
  if ((c.content || '').length < 300) q -= 10;
  if (c.authors && c.authors.length) q += 3;
  if (c.published_at) q += 2;
  return Math.max(0, Math.min(100, Math.round(q)));
}

// Only the service role may call this. The bearer is accepted when it equals the
// key injected into this function, or when it passes a real admin call against
// the project (which only a service key can). That keeps the cron working across
// key rotations and the legacy-JWT / sb_secret changeover, without trusting the
// caller's say-so.
async function isServiceCaller(req: Request, supabaseUrl: string, serviceKey: string) {
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!token || token.length < 32) return false;
  if (token === serviceKey) return true;
  try {
    const r = await fetch(`${supabaseUrl}/auth/v1/admin/users?per_page=1`, { headers: { apikey: token, Authorization: `Bearer ${token}` } });
    return r.status === 200;
  } catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!, serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  if (!(await isServiceCaller(req, supabaseUrl, serviceKey))) return json({ error: 'forbidden' }, 403);
  const body = await req.json().catch(() => ({}));
  // Small batches: the Edge runtime's CPU budget allows roughly a dozen embeddings
  // per invocation, so the cron calls this every 15 minutes with a small budget
  // rather than hourly with a large one.
  const budget = Math.max(2, Math.min(Number(body.budget) || 8, 120));
  // Edge Functions have a hard CPU and wall-clock budget; embedding is the costly
  // part. Stop discovering new sources after this and write the tally, so a run
  // that gets cut off still leaves an accurate record. The next run continues.
  const DEADLINE_MS = 40_000, t0 = Date.now();
  const outOfTime = () => Date.now() - t0 > DEADLINE_MS;
  const sb = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  // @ts-ignore Supabase.ai is provided by the Edge runtime
  const model = new Supabase.ai.Session('gte-small');

  const { data: run } = await sb.from('olo_ingest_runs').insert({ note: body.source || 'manual' }).select().single();
  // Least recently run first, so no source is starved when a run is cut short.
  const { data: sources } = await sb.from('olo_sources').select('*').eq('enabled', true).order('last_run_at', { ascending: true, nullsFirst: true });
  const stats = { fetched: 0, added: 0, skipped: 0, failed: 0, linked: 0 };
  // Why things failed, per source, written into the run note at the end (see runlog.ts).
  const errors: RunError[] = [];
  const fail = (slug: string, e: unknown) => { stats.failed++; errors.push({ slug, message: e instanceof Error ? e.message : String(e) }); };
  const checkpoint = () => sb.from('olo_ingest_runs').update({ ...stats }).eq('id', run?.id);
  let cutShort = false;

  // How many atoms a source added today; a source over the daily cap is skipped until tomorrow.
  const addedToday = new Map<string, number>();
  async function overCap(src: Source) {
    if (!addedToday.has(src.id)) {
      const { count: n } = await sb.from('olo_atoms').select('id', { count: 'exact', head: true }).eq('source_id', src.id).gte('created_at', new Date().toISOString().slice(0, 10));
      addedToday.set(src.id, n || 0);
    }
    return (addedToday.get(src.id) || 0) >= DAILY_CAP;
  }

  // Insert one atom with provenance and trust, link it, and score it and the neighbours that now agree with it.
  // Returns the new id, or null when it was a duplicate or could not be stored.
  async function store(src: Source, c: Candidate, title: string, summary: string, content: string, hash: string): Promise<string | null> {
    const emb: number[] = await model.run((title + '. ' + (summary || content)).slice(0, EMBED_CHARS), { mean_pool: true, normalize: true });
    const row = { source_id: src.id, external_id: c.external_id || null, url: c.url, title, summary: summary || null, content: content || null, lang: c.lang || 'en', licence: c.licence || src.licence, authors: c.authors || null, published_at: c.published_at || null, content_hash: hash, quality: quality({ ...c, summary, content }, src.trust), tokens: Math.round((title + summary + content).length / 4), embedding: emb,
      // sql/002: time and provenance. A fact is assumed to hold from its publication date; observed_at is now.
      valid_from: c.published_at || null, source_revision: c.source_revision || null, doi: c.doi || null, pmid: c.pmid || null, observed_at: new Date().toISOString() };
    const { data: atom, error } = await sb.from('olo_atoms').insert(row).select('id').single();
    if (error || !atom) {
      // Older schema (sql/002 not run yet): store without the new columns rather than lose the atom.
      if (error && /column|schema cache/i.test(error.message || '')) {
        const { valid_from: _v, source_revision: _r, doi: _d, pmid: _p, observed_at: _o, ...legacy } = row;
        const again = await sb.from('olo_atoms').insert(legacy).select('id').single();
        if (again.error || !again.data) return null;
        return again.data.id;
      }
      return null;
    }
    const { data: nb } = await sb.rpc('olo_neighbours', { p_embedding: emb, p_exclude: atom.id, p_k: LINK_K });
    const near = (nb || []).filter((x: any) => x.sim >= MIN_LINK);
    const links = near.flatMap((x: any) => [{ from_atom: atom.id, to_atom: x.id, relation: 'similar', weight: x.sim }, { from_atom: x.id, to_atom: atom.id, relation: 'similar', weight: x.sim }]);
    if (links.length) { const { error: le } = await sb.from('olo_links').upsert(links, { onConflict: 'from_atom,to_atom,relation', ignoreDuplicates: true }); if (!le) stats.linked += links.length; }
    // Score: this atom, and the close neighbours whose agreement count may have risen (sql/002; ignored on the older schema).
    await sb.rpc('olo_rescore_atom', { p_id: atom.id }).then(() => {}, () => {});
    for (const x of near.filter((x: any) => x.sim >= AGREE).slice(0, 5)) await sb.rpc('olo_rescore_atom', { p_id: x.id }).then(() => {}, () => {});
    addedToday.set(src.id, (addedToday.get(src.id) || 0) + 1);
    return atom.id;
  }

  // Insert candidates for one source: clean, hash, refuse duplicates, embed, insert, link. Returns how many were added.
  async function ingest(src: Source, cands: Candidate[]): Promise<number> {
    stats.fetched += cands.length;
    let addedHere = 0;
    if (cands.length && await overCap(src)) { errors.push({ slug: src.slug, message: `daily cap of ${DAILY_CAP} atoms reached; skipped ${cands.length}` }); stats.skipped += cands.length; return 0; }
    for (const c of cands) {
      if (outOfTime()) { cutShort = true; break; }
      try {
        const title = clean(c.title).slice(0, 300), summary = clean(c.summary || '').slice(0, 1000), content = clean(c.content || '').slice(0, MAX_CONTENT);
        if (!title || !/^https:\/\//.test(c.url)) { stats.skipped++; continue; }
        const hash = await sha256(title + '\n' + summary + '\n' + content);
        const { data: dup } = await sb.from('olo_atoms').select('id').or(`content_hash.eq.${hash},url.eq.${c.url}`).limit(1);
        if (dup && dup.length) { stats.skipped++; continue; }
        const id = await store(src, c, title, summary, content, hash);
        if (!id) { stats.failed++; continue; }
        stats.added++; addedHere++;
        await checkpoint();
      } catch (e) { fail(src.slug, e); }
    }
    if (addedHere) { src.atoms = (src.atoms || 0) + addedHere; await sb.from('olo_sources').update({ atoms: src.atoms }).eq('id', src.id); }
    return addedHere;
  }

  // Re-check: read the oldest-observed Wikipedia and Wikidata atoms at their source again. Unchanged: observed_at moves
  // forward. Changed text: the old atom becomes history (status superseded, its url the permalink of its revision,
  // valid_to today) and the new text is stored as a new atom that points back. Nothing is ever overwritten or deleted.
  let recheckNote = '';
  async function recheck(src: Source) {
    const { data: batch } = await sb.rpc('olo_recheck_batch', { p_slug: src.slug, p_n: RECHECK_N });
    if (!Array.isArray(batch) || !batch.length) return;
    let same = 0, changed = 0;
    for (const old of batch) {
      if (outOfTime()) { cutShort = true; break; }
      try {
        let c: Candidate | null = null;
        if (src.slug === 'wikipedia' || src.slug === 'wikipedia_es') {
          const lang = src.slug === 'wikipedia_es' ? 'es' : 'en';
          const title = decodeURIComponent(String(old.url).split('/wiki/')[1] || old.title).replace(/_/g, ' ');
          c = wikiCandidate(await get(`https://${lang}.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(title.replace(/ /g, '_'))}`), lang);
        } else if (src.slug === 'wikidata') {
          c = (await wikidataByIds([String(old.external_id)], 1))[0] || null;
        }
        if (!c) continue;  // gone or no longer an article: left as is, re-tried in a week
        const title = clean(c.title).slice(0, 300), summary = clean(c.summary || '').slice(0, 1000), content = clean(c.content || '').slice(0, MAX_CONTENT);
        const hash = await sha256(title + '\n' + summary + '\n' + content);
        const plan = planRecheck(old, { hash, revision: c.source_revision });
        if (plan.action === 'same') {
          same++;
          await sb.from('olo_atoms').update({ observed_at: new Date().toISOString(), source_revision: c.source_revision || old.source_revision || null }).eq('id', old.id);
          continue;
        }
        // changed: the old row keeps its text under a permalink; the new text takes the live url
        const oldUrl = permalink(src.slug, String(old.url), old.source_revision ? String(old.source_revision) : null);
        const moved = await sb.from('olo_atoms').update({ url: oldUrl }).eq('id', old.id);
        if (moved.error) { fail(src.slug + ' (recheck)', moved.error.message); continue; }
        const id = await store(src, { ...c, url: String(old.url) }, title, summary, content, hash);
        if (!id) { await sb.from('olo_atoms').update({ url: String(old.url) }).eq('id', old.id); continue; }
        await sb.rpc('olo_supersede', { p_old: old.id, p_new: id });
        changed++; stats.added++;
      } catch (e) { fail(src.slug + ' (recheck)', e); }
    }
    if (same || changed) recheckNote += ` (${src.slug} re-check: ${same} unchanged, ${changed} updated)`;
  }

  // 1. Gap filling: the most-asked open topic, searched across the sources that can search.
  let gapNote = '';
  const searchable = (sources || []).filter((s: Source) => search[s.slug]);
  if (budget >= 6 && searchable.length) {
    const { data: gap } = await sb.rpc('olo_next_gap');
    if (gap && gap.topic) {
      const gapBudget = Math.max(2, Math.floor(budget / 3));
      const perSrc = Math.max(1, Math.ceil(gapBudget / searchable.length));
      let gapAdded = 0, gapFetched = 0;
      for (const src of searchable) {
        if (outOfTime() || gapAdded >= gapBudget) break;
        let cands: Candidate[] = [];
        try { cands = await search[src.slug](gap.topic, perSrc); } catch (e) { fail(src.slug + ' (gap search)', e); continue; }
        gapFetched += cands.length;
        gapAdded += await ingest(src, cands.slice(0, gapBudget - gapAdded));
      }
      await sb.from('olo_gaps').update({ tries: (gap.tries || 0) + 1, last_tried_at: new Date().toISOString(), atoms_added: gapAdded, ...(gapAdded > 0 ? { filled_at: new Date().toISOString() } : {}) }).eq('id', gap.id);
      gapNote = ` (gap "${gap.topic}": ${gapAdded} added of ${gapFetched} found)`;
    }
  }

  // 2. Re-checks at the source (sql/002): a few atoms per run, so every Wikipedia and Wikidata atom is re-read within weeks.
  if (budget >= 6) {
    for (const src of (sources || []).filter((s: Source) => ['wikipedia', 'wikipedia_es', 'wikidata'].includes(s.slug))) {
      if (outOfTime()) { cutShort = true; break; }
      await recheck(src);
    }
  }

  // 3. The random walk through every enabled source, as before.
  const perSource = Math.max(1, Math.floor(budget / Math.max(1, (sources || []).length)));
  for (const src of sources || []) {
    if (outOfTime()) { cutShort = true; break; }
    const fn = discover[src.slug]; if (!fn) continue;
    let cands: Candidate[] = [];
    try { cands = await fn(perSource, src); } catch (e) { fail(src.slug, e); continue; }
    await ingest(src, cands);
    await sb.from('olo_sources').update({ last_run_at: new Date().toISOString() }).eq('id', src.id);
    await checkpoint();
    if (cutShort) break;
  }
  await sb.from('olo_ingest_runs').update({ ...stats, finished_at: new Date().toISOString(), note: (body.source || 'manual') + gapNote + recheckNote + (cutShort ? ' (time budget reached, continues next run)' : '') + errorNote(errors) }).eq('id', run?.id);
  await sb.rpc('olo_snapshot');
  return json({ ok: true, run: run?.id, ...stats });
});

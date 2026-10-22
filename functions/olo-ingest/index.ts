// supabase/functions/olo-ingest/index.ts
//
// Grows Olo Commons. Runs hourly from pg_cron (or by hand with the service key).
// For each enabled source it discovers a few new items from that source's own
// public API, turns each into an atom with provenance, embeds it with gte-small
// INSIDE Supabase (no external AI key, nothing leaves the project), inserts it
// if the content hash is new, and links it to its nearest neighbours.
//
// Deploy:  supabase functions deploy olo-ingest --no-verify-jwt
// Only the service role may call it. Sources are read from olo_sources; a
// source that is not enabled there is never fetched, whatever the code says.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { clean, delatex } from './text.ts';
import { ckanCandidates, OPEN_LICENCES } from './ckan.ts';

const UA = 'OloCommons/1.0 (+https://heliusnetwork.app/olo; hello@heliusnetwork.com)';
const MAX_CONTENT = 8000;      // characters of plain text kept per atom
const EMBED_CHARS = 1500;      // characters fed to the embedding model
const LINK_K = 5;              // neighbours linked per new atom
const MIN_LINK = 0.72;         // cosine similarity needed to make a link

type Candidate = { external_id?: string; url: string; title: string; summary?: string; content?: string; authors?: string[]; published_at?: string; licence?: string; lang?: string };
// The registry row a connector is called with, so a connector can read its own api_base.
type Source = { slug: string; api_base?: string | null };

function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }); }
async function sha256(s: string) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)); return Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join(''); }
async function get(url: string, accept = 'application/json') { const r = await fetch(url, { headers: { 'User-Agent': UA, Accept: accept }, signal: AbortSignal.timeout(8000) }); if (!r.ok) throw new Error(`${r.status} ${url}`); return accept.includes('json') ? r.json() : r.text(); }
const pick = (arr: any[], n: number) => arr.sort(() => Math.random() - 0.5).slice(0, n);

/* ---------- discovery per source: each returns a few candidates from the source's own API ---------- */
// Random article summaries from one language edition of Wikipedia.
async function wikiRandom(lang: string, n: number): Promise<Candidate[]> {
  const out: Candidate[] = [];
  for (let i = 0; i < n; i++) {
    try {
      const p: any = await get(`https://${lang}.wikipedia.org/api/rest_v1/page/random/summary`);
      if (p.type !== 'standard' || !p.extract || p.extract.length < 200) continue;
      out.push({ external_id: String(p.pageid), url: p.content_urls?.desktop?.page || `https://${lang}.wikipedia.org/wiki/${encodeURIComponent(p.title)}`, title: p.title, summary: clean(p.description ? p.description + '. ' + p.extract : p.extract).slice(0, 600), content: clean(p.extract), published_at: p.timestamp ? p.timestamp.slice(0, 10) : undefined, licence: 'CC BY-SA 4.0', lang });
    } catch (_) {}
  }
  return out;
}

const discover: Record<string, (n: number, src: Source) => Promise<Candidate[]>> = {
  wikipedia: (n) => wikiRandom('en', n),
  wikipedia_es: (n) => wikiRandom('es', n),
  // data.gov dataset descriptions through CKAN package_search (issue #3). Only
  // packages under an open licence id are requested and kept (see ckan.ts). The
  // API base comes from the registry row so a portal move needs no code change.
  async data_gov(n, src) {
    const api = (src.api_base || 'https://catalog.data.gov/api/3').replace(/\/+$/, '');
    const fq = 'license_id:(' + Object.keys(OPEN_LICENCES).map(id => `"${id}"`).join(' OR ') + ')';
    const r: any = await get(`${api}/action/package_search?rows=${Math.min(n * 3, 30)}&start=${Math.floor(Math.random() * 2000)}&fq=${encodeURIComponent(fq)}`);
    return pick(ckanCandidates(r, 'https://catalog.data.gov', n * 3), n);
  },
  async wikidata(n) {
    const r: any = await get(`https://www.wikidata.org/w/api.php?action=query&list=random&rnnamespace=0&rnlimit=${Math.min(n * 2, 20)}&format=json`);
    const ids = (r.query?.random || []).map((x: any) => x.title).filter((t: string) => /^Q\d+$/.test(t));
    if (!ids.length) return [];
    const e: any = await get(`https://www.wikidata.org/w/api.php?action=wbgetentities&ids=${ids.join('|')}&props=labels|descriptions|sitelinks&languages=en&format=json`);
    const out: Candidate[] = [];
    for (const id of ids) {
      const ent = e.entities?.[id]; const label = ent?.labels?.en?.value, desc = ent?.descriptions?.en?.value;
      if (!label || !desc) continue;
      const links = Object.keys(ent.sitelinks || {}).length;
      if (links < 3) continue;   // keep entities with some notability
      out.push({ external_id: id, url: `https://www.wikidata.org/wiki/${id}`, title: label, summary: `${label}: ${desc}.`, content: `${label}. ${desc}. Described in ${links} Wikimedia projects.`, licence: 'CC0 1.0' });
      if (out.length >= n) break;
    }
    return out;
  },
  async archive_org(n) {
    const page = 1 + Math.floor(Math.random() * 200);
    const r: any = await get(`https://archive.org/advancedsearch.php?q=mediatype%3Atexts+AND+description%3A*&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=description&fl%5B%5D=creator&fl%5B%5D=date&fl%5B%5D=licenseurl&rows=${n * 2}&page=${page}&output=json`);
    return pick((r.response?.docs || []).filter((d: any) => d.title && d.description), n).map((d: any) => ({ external_id: d.identifier, url: `https://archive.org/details/${d.identifier}`, title: clean(d.title).slice(0, 200), summary: clean(Array.isArray(d.description) ? d.description.join(' ') : d.description).slice(0, 600), content: clean(Array.isArray(d.description) ? d.description.join(' ') : d.description), authors: d.creator ? [].concat(d.creator).map(clean) : undefined, published_at: /^\d{4}-\d{2}-\d{2}/.test(String(d.date || '')) ? String(d.date).slice(0, 10) : undefined, licence: d.licenseurl ? `See ${d.licenseurl}` : 'Public domain / as stated by the Archive' }));
  },
  async arxiv(n) {
    const cats = ['cs.AI', 'cs.LG', 'cs.CR', 'q-bio', 'physics.soc-ph', 'econ', 'stat.ML', 'cs.CY', 'eess.SP', 'math.OC'];
    const cat = cats[Math.floor(Math.random() * cats.length)];
    const xml: string = await get(`https://export.arxiv.org/api/query?search_query=cat:${cat}&sortBy=submittedDate&sortOrder=descending&start=${Math.floor(Math.random() * 50)}&max_results=${n}`, 'application/atom+xml');
    const out: Candidate[] = [];
    for (const m of xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)) {
      const e = m[1]; const id = (e.match(/<id>(.*?)<\/id>/) || [])[1]; const title = clean(delatex((e.match(/<title>([\s\S]*?)<\/title>/) || [])[1])); const abs = clean(delatex((e.match(/<summary>([\s\S]*?)<\/summary>/) || [])[1]));
      const authors = Array.from(e.matchAll(/<name>(.*?)<\/name>/g)).map(x => clean(x[1])); const pub = (e.match(/<published>(.*?)<\/published>/) || [])[1];
      if (!id || !title || abs.length < 100) continue;
      out.push({ external_id: id.replace('http://arxiv.org/abs/', ''), url: id.replace('http://', 'https://'), title, summary: abs.slice(0, 600), content: abs, authors, published_at: pub ? pub.slice(0, 10) : undefined, licence: 'arXiv.org perpetual non-exclusive licence (abstract)' });
    }
    return out;
  },
  async gutenberg(n) {
    const r: any = await get(`https://gutendex.com/books?page=${1 + Math.floor(Math.random() * 60)}`);
    return pick((r.results || []).filter((b: any) => b.title && (b.summaries?.length || b.subjects?.length)), n).map((b: any) => ({ external_id: String(b.id), url: `https://www.gutenberg.org/ebooks/${b.id}`, title: clean(b.title).slice(0, 200), summary: clean(b.summaries?.[0] || `${b.title}. Subjects: ${(b.subjects || []).slice(0, 6).join('; ')}`).slice(0, 600), content: clean(b.summaries?.[0] || '') + ' Subjects: ' + (b.subjects || []).join('; '), authors: (b.authors || []).map((a: any) => a.name), published_at: undefined, licence: 'Public domain' }));
  },
  async pubmed(n) {
    const terms = ['review[pt] AND open access[filter]', 'public health[MeSH] AND review[pt]', 'nutrition[MeSH] AND review[pt]', 'exercise[MeSH] AND review[pt]', 'climate change[MeSH]', 'vaccination[MeSH] AND review[pt]'];
    const term = terms[Math.floor(Math.random() * terms.length)];
    const s: any = await get(`https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=${encodeURIComponent(term)}&retmax=${n}&retstart=${Math.floor(Math.random() * 500)}&sort=pub_date&retmode=json`);
    const ids: string[] = s.esearchresult?.idlist || []; if (!ids.length) return [];
    const xml: string = await get(`https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=${ids.join(',')}&rettype=abstract&retmode=xml`, 'text/xml');
    const out: Candidate[] = [];
    for (const m of xml.matchAll(/<PubmedArticle>([\s\S]*?)<\/PubmedArticle>/g)) {
      const a = m[1]; const pmid = (a.match(/<PMID[^>]*>(\d+)<\/PMID>/) || [])[1]; const title = clean((a.match(/<ArticleTitle>([\s\S]*?)<\/ArticleTitle>/) || [])[1]);
      const abs = clean(Array.from(a.matchAll(/<AbstractText[^>]*>([\s\S]*?)<\/AbstractText>/g)).map(x => x[1]).join(' ')); const year = (a.match(/<PubDate>[\s\S]*?<Year>(\d{4})<\/Year>/) || [])[1];
      const authors = Array.from(a.matchAll(/<Author[^>]*>[\s\S]*?<LastName>(.*?)<\/LastName>[\s\S]*?<ForeName>(.*?)<\/ForeName>/g)).slice(0, 8).map(x => clean(x[2] + ' ' + x[1]));
      if (!pmid || !title || abs.length < 150) continue;
      out.push({ external_id: pmid, url: `https://pubmed.ncbi.nlm.nih.gov/${pmid}/`, title, summary: abs.slice(0, 600), content: abs, authors, published_at: year ? `${year}-01-01` : undefined, licence: 'Abstract as published; citation data public domain (NLM)' });
    }
    return out;
  },
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
  // that gets cut off still leaves an accurate record. The next hour continues.
  const DEADLINE_MS = 40_000, t0 = Date.now();
  const outOfTime = () => Date.now() - t0 > DEADLINE_MS;
  const sb = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  // @ts-ignore Supabase.ai is provided by the Edge runtime
  const model = new Supabase.ai.Session('gte-small');

  const { data: run } = await sb.from('olo_ingest_runs').insert({ note: body.source || 'manual' }).select().single();
  // Least recently run first, so no source is starved when a run is cut short.
  const { data: sources } = await sb.from('olo_sources').select('*').eq('enabled', true).order('last_run_at', { ascending: true, nullsFirst: true });
  const stats = { fetched: 0, added: 0, skipped: 0, failed: 0, linked: 0 };
  const perSource = Math.max(1, Math.floor(budget / Math.max(1, (sources || []).length)));

  const checkpoint = () => sb.from('olo_ingest_runs').update({ ...stats }).eq('id', run?.id);
  let cutShort = false;
  for (const src of sources || []) {
    if (outOfTime()) { cutShort = true; break; }
    const fn = discover[src.slug]; if (!fn) continue;
    let cands: Candidate[] = [];
    try { cands = await fn(perSource, src); } catch (e) { stats.failed++; continue; }
    stats.fetched += cands.length;
    let addedHere = 0;
    for (const c of cands) {
      if (outOfTime()) { cutShort = true; break; }
      try {
        const title = clean(c.title).slice(0, 300), summary = clean(c.summary || '').slice(0, 1000), content = clean(c.content || '').slice(0, MAX_CONTENT);
        if (!title || !/^https:\/\//.test(c.url)) { stats.skipped++; continue; }
        const hash = await sha256(title + '\n' + summary + '\n' + content);
        const { data: dup } = await sb.from('olo_atoms').select('id').or(`content_hash.eq.${hash},url.eq.${c.url}`).limit(1);
        if (dup && dup.length) { stats.skipped++; continue; }
        const emb: number[] = await model.run((title + '. ' + (summary || content)).slice(0, EMBED_CHARS), { mean_pool: true, normalize: true });
        const row = { source_id: src.id, external_id: c.external_id || null, url: c.url, title, summary: summary || null, content: content || null, lang: c.lang || 'en', licence: c.licence || src.licence, authors: c.authors || null, published_at: c.published_at || null, content_hash: hash, quality: quality({ ...c, summary, content }, src.trust), tokens: Math.round((title + summary + content).length / 4), embedding: emb };
        const { data: atom, error } = await sb.from('olo_atoms').insert(row).select('id').single();
        if (error || !atom) { stats.failed++; continue; }
        stats.added++; addedHere++;
        const { data: nb } = await sb.rpc('olo_neighbours', { p_embedding: emb, p_exclude: atom.id, p_k: LINK_K });
        const links = (nb || []).filter((x: any) => x.sim >= MIN_LINK).flatMap((x: any) => [{ from_atom: atom.id, to_atom: x.id, relation: 'similar', weight: x.sim }, { from_atom: x.id, to_atom: atom.id, relation: 'similar', weight: x.sim }]);
        if (links.length) { const { error: le } = await sb.from('olo_links').upsert(links, { onConflict: 'from_atom,to_atom,relation', ignoreDuplicates: true }); if (!le) stats.linked += links.length; }
        await checkpoint();
      } catch (_) { stats.failed++; }
    }
    await sb.from('olo_sources').update({ last_run_at: new Date().toISOString(), atoms: (src.atoms || 0) + addedHere }).eq('id', src.id);
    await checkpoint();
    if (cutShort) break;
  }
  await sb.from('olo_ingest_runs').update({ ...stats, finished_at: new Date().toISOString(), note: (body.source || 'manual') + (cutShort ? ' (time budget reached, continues next run)' : '') }).eq('id', run?.id);
  await sb.rpc('olo_snapshot');
  return json({ ok: true, run: run?.id, ...stats });
});

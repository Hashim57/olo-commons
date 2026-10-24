// supabase/functions/olo-query/index.ts
//
// The one read API for Olo Commons. Used by heliusnetwork.app/olo, by
// helius-olo.io and by the Helius Network app (Olo in-app). Read-only.
//
//   POST /functions/v1/olo-query   { "q": "how do coral reefs recover", "k": 8 }
//   GET  /functions/v1/olo-query?q=...&k=8
//   GET  /functions/v1/olo-query?status=1      the Commons' health, no key needed
//
// Returns atoms with full provenance (source, URL, licence, retrieved_at,
// content hash) so the caller can cite. Meaning search (embedding computed in
// Supabase with gte-small) merged with keyword search by reciprocal rank fusion
// (see rank.ts): an atom both retrievers find comes first. Each result says
// which retriever found it (`match`: both, semantic or keyword).
//
// Deploy:  supabase functions deploy olo-query --no-verify-jwt
// Optional secrets: OLO_API_KEYS="key1,key2" for partners who need the higher
// limit (send as header x-olo-key); OLO_SALT for hashing client addresses.
//
// Limits: anonymous callers 120 queries per hour per address (hashed), keyed
// callers 3000. Query text is never stored; only its length and result count.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { citation, fuse } from './rank.ts';

const ALLOWED_ORIGINS = ['https://heliusnetwork.app', 'https://helius-olo.io', 'https://www.helius-olo.io', 'https://kokorozashi.io', 'https://heliusnetwork.com'];
const ANON_PER_HOUR = 120, KEYED_PER_HOUR = 3000, MAX_Q = 400;

function cors(origin: string | null) {
  const ok = origin && (ALLOWED_ORIGINS.includes(origin) || /^https:\/\/[a-z0-9-]+--stupendous-begonia-5e8cf9\.netlify\.app$/.test(origin));
  return { 'Access-Control-Allow-Origin': ok ? origin! : ALLOWED_ORIGINS[0], 'Access-Control-Allow-Headers': 'Content-Type, x-olo-key, apikey, authorization', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Vary': 'Origin', 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
}
async function sha256(s: string) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)); return Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join(''); }

Deno.serve(async (req) => {
  const H = cors(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response('', { status: 204, headers: H });
  if (req.method !== 'GET' && req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: H });

  let q = '', k = 8, mode = 'hybrid', status = false;
  if (req.method === 'POST') { const b = await req.json().catch(() => ({})); q = String(b.q || ''); k = Number(b.k) || 8; mode = String(b.mode || 'hybrid'); status = b.status === true || b.status === 1; }
  else { const u = new URL(req.url); q = u.searchParams.get('q') || ''; k = Number(u.searchParams.get('k')) || 8; mode = u.searchParams.get('mode') || 'hybrid'; status = u.searchParams.has('status'); }

  // Health of the Commons in one call: the same public figures as olo_stats()
  // (readable with the anon key already) plus the last twelve ingest runs, so a
  // status page or a monitor needs no key in its URL. Read-only, cacheable for a minute.
  if (status) {
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const [{ data: stats, error: se }, { data: runs, error: re }] = await Promise.all([
      sb.rpc('olo_stats'),
      sb.from('olo_ingest_runs').select('id, started_at, finished_at, fetched, added, skipped, failed, linked, note').order('started_at', { ascending: false }).limit(12),
    ]);
    if (se || re) return new Response(JSON.stringify({ error: 'status_unavailable' }), { status: 503, headers: H });
    const open = (runs || []).filter((r: any) => !r.finished_at).length, failing = (runs || []).filter((r: any) => (r.failed || 0) > 0).length;
    return new Response(JSON.stringify({ ok: true, at: new Date().toISOString(), stats, runs: runs || [], runs_unfinished: open, runs_with_failures: failing }), { headers: { ...H, 'Cache-Control': 'public, max-age=60' } });
  }
  q = q.replace(/\s+/g, ' ').trim().slice(0, MAX_Q); k = Math.max(1, Math.min(k, 20));
  if (!['hybrid', 'semantic', 'keyword'].includes(mode)) mode = 'hybrid';
  if (q.length < 2) return new Response(JSON.stringify({ error: 'q is required (2 to 400 characters)' }), { status: 400, headers: H });

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  // rate limit by hashed address (never the raw address), higher for keyed partners
  const keys = (Deno.env.get('OLO_API_KEYS') || '').split(',').map(s => s.trim()).filter(Boolean);
  const hdrKey = req.headers.get('x-olo-key') || '';
  let keyed = keys.length > 0 && keys.includes(hdrKey);
  if (!keyed && hdrKey.startsWith('olo_')) { const { data } = await sb.rpc('olo_key_valid', { p_key: hdrKey }); keyed = data === true; }
  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown').split(',')[0].trim();
  const ipHash = (await sha256(ip + '|' + (Deno.env.get('OLO_SALT') || 'olo') + '|' + new Date().toISOString().slice(0, 10))).slice(0, 32);
  const { count } = await sb.from('olo_query_log').select('id', { count: 'exact', head: true }).eq('ip_hash', ipHash).gt('at', new Date(Date.now() - 3600e3).toISOString());
  if ((count || 0) >= (keyed ? KEYED_PER_HOUR : ANON_PER_HOUR)) return new Response(JSON.stringify({ error: 'rate_limited', retry_after_seconds: 600 }), { status: 429, headers: { ...H, 'Retry-After': '600' } });

  // Ask each retriever for more than k so the fusion has something to reorder;
  // both SQL functions cap their own limits, so this stays bounded.
  const want = Math.min(k * 2, 30);
  let semantic: any[] = [], keyword: any[] = [];
  if (mode !== 'keyword') {
    try {
      // @ts-ignore provided by the Edge runtime
      const model = new Supabase.ai.Session('gte-small');
      const emb: number[] = await model.run(q, { mean_pool: true, normalize: true });
      const { data } = await sb.rpc('olo_match', { p_embedding: emb, p_k: want, p_min: 0.5 });
      semantic = Array.isArray(data) ? data : [];
    } catch (_) { /* fall through to keyword */ }
  }
  if (mode !== 'semantic') { const { data } = await sb.rpc('olo_search_text', { p_q: q, p_k: want }); keyword = Array.isArray(data) ? data : []; }

  // merge by reciprocal rank fusion: an atom found by both retrievers rises to the top
  const results = fuse(semantic, keyword, k).map((r: any) => ({
    id: r.id, title: r.title, summary: r.summary, content: r.content || null, url: r.url, source: r.source, source_slug: r.source_slug, licence: r.licence,
    published_at: r.published_at || null, retrieved_at: r.retrieved_at, similarity: typeof r.similarity === 'number' ? r.similarity : null, match: r.match, citation: citation(r),
  }));
  await sb.from('olo_query_log').insert({ ip_hash: ipHash, q_len: q.length, results: results.length, client: keyed ? 'keyed' : (req.headers.get('origin') || 'api').slice(0, 80) });
  return new Response(JSON.stringify({ q, k, mode, results, attribution: 'Olo Commons by Helius Network. Each result carries its own source and licence; cite them.', api: 'https://heliusnetwork.app/olo/#api' }), { headers: H });
});

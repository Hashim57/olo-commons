// supabase/functions/olo-query/index.ts
//
// The one read API for Olo Commons. Used by heliusnetwork.app/olo, by
// helius-olo.io and by the Helius Network app (Olo in-app). Read-only.
//
//   POST /functions/v1/olo-query   { "q": "how do coral reefs recover", "k": 8 }
//   GET  /functions/v1/olo-query?q=...&k=8
//
// Returns atoms with full provenance (source, URL, licence, retrieved_at,
// content hash) so the caller can cite. Meaning search (embedding computed in
// Supabase with gte-small) merged with keyword search.
//
// Deploy:  supabase functions deploy olo-query --no-verify-jwt
// Optional secrets: OLO_API_KEYS="key1,key2" for partners who need the higher
// limit (send as header x-olo-key); OLO_SALT for hashing client addresses.
//
// Limits: anonymous callers 120 queries per hour per address (hashed), keyed
// callers 3000. Query text is never stored; only its length and result count.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

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

  let q = '', k = 8, mode = 'hybrid';
  if (req.method === 'POST') { const b = await req.json().catch(() => ({})); q = String(b.q || ''); k = Number(b.k) || 8; mode = String(b.mode || 'hybrid'); }
  else { const u = new URL(req.url); q = u.searchParams.get('q') || ''; k = Number(u.searchParams.get('k')) || 8; mode = u.searchParams.get('mode') || 'hybrid'; }
  q = q.replace(/\s+/g, ' ').trim().slice(0, MAX_Q); k = Math.max(1, Math.min(k, 20));
  if (q.length < 2) return new Response(JSON.stringify({ error: 'q is required (2 to 400 characters)' }), { status: 400, headers: H });

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  // rate limit by hashed address (never the raw address), higher for keyed partners
  const keys = (Deno.env.get('OLO_API_KEYS') || '').split(',').map(s => s.trim()).filter(Boolean);
  const keyed = keys.length > 0 && keys.includes(req.headers.get('x-olo-key') || '');
  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown').split(',')[0].trim();
  const ipHash = (await sha256(ip + '|' + (Deno.env.get('OLO_SALT') || 'olo') + '|' + new Date().toISOString().slice(0, 10))).slice(0, 32);
  const { count } = await sb.from('olo_query_log').select('id', { count: 'exact', head: true }).eq('ip_hash', ipHash).gt('at', new Date(Date.now() - 3600e3).toISOString());
  if ((count || 0) >= (keyed ? KEYED_PER_HOUR : ANON_PER_HOUR)) return new Response(JSON.stringify({ error: 'rate_limited', retry_after_seconds: 600 }), { status: 429, headers: { ...H, 'Retry-After': '600' } });

  let semantic: any[] = [], keyword: any[] = [];
  if (mode !== 'keyword') {
    try {
      // @ts-ignore provided by the Edge runtime
      const model = new Supabase.ai.Session('gte-small');
      const emb: number[] = await model.run(q, { mean_pool: true, normalize: true });
      const { data } = await sb.rpc('olo_match', { p_embedding: emb, p_k: k, p_min: 0.5 });
      semantic = data || [];
    } catch (_) { /* fall through to keyword */ }
  }
  if (mode !== 'semantic') { const { data } = await sb.rpc('olo_search_text', { p_q: q, p_k: k }); keyword = data || []; }

  // merge: semantic first, then keyword hits not already present
  const seen = new Set(semantic.map((r: any) => r.id));
  const results = [...semantic, ...keyword.filter((r: any) => !seen.has(r.id))].slice(0, k).map((r: any) => ({
    id: r.id, title: r.title, summary: r.summary, content: r.content || null, url: r.url, source: r.source, source_slug: r.source_slug, licence: r.licence,
    published_at: r.published_at || null, retrieved_at: r.retrieved_at, similarity: r.similarity ?? null, citation: `${r.title} (${r.source}, ${r.licence}). ${r.url}`,
  }));
  await sb.from('olo_query_log').insert({ ip_hash: ipHash, q_len: q.length, results: results.length, client: keyed ? 'keyed' : (req.headers.get('origin') || 'api').slice(0, 80) });
  return new Response(JSON.stringify({ q, k, results, attribution: 'Olo Commons by Helius Network. Each result carries its own source and licence; cite them.', api: 'https://heliusnetwork.app/olo/#api' }), { headers: H });
});

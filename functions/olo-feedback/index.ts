// supabase/functions/olo-feedback/index.ts
//
// Sentence-level flags from Olo's apps: "this sentence was marked supported but
// the source does not say that", with the passages it was checked against. A
// person reviews them (status new -> accepted or rejected); accepted flags become
// Zeus training examples through zeus/feedback_to_gold.py. This is how Olo and
// Zeus improve from being used.
//
//   POST /functions/v1/olo-feedback
//     { "client": "web|ios|macos|commons|api", "answer_source": "olo|commons|offline",
//       "claim": "<the sentence>", "verdict_given": "supported", "verdict_user": "not_covered",
//       "passages": [{ "atom": "<uuid>", "url": "https://...", "quote": "..." }], "evidence_quote": "...", "note": "..." }
//     -> { "ok": true, "id": "<uuid>" }   (or { "ok": true, "stored": false } for an uninformative or repeated flag)
//   GET  /functions/v1/olo-feedback?stats=1   -> public counts only
//
// Stored: the flag above and a daily-salted hash of the address for the rate limit. Never the question,
// never who asked. 60 flags an hour per address. Deploy: supabase functions deploy olo-feedback --no-verify-jwt
// Needs sql/002 (table olo_feedback, function olo_feedback_stats).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { isInformative, parseFeedback } from './feedback.ts';

const ALLOWED_ORIGINS = ['https://heliusnetwork.app', 'https://helius-olo.io', 'https://www.helius-olo.io', 'https://kokorozashi.io', 'https://heliusnetwork.com'];
const PER_HOUR = 60;

function cors(origin: string | null) {
  const ok = origin && (ALLOWED_ORIGINS.includes(origin) || /^https:\/\/[a-z0-9-]+--stupendous-begonia-5e8cf9\.netlify\.app$/.test(origin));
  return { 'Access-Control-Allow-Origin': ok ? origin! : ALLOWED_ORIGINS[0], 'Access-Control-Allow-Headers': 'Content-Type, apikey, authorization', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Vary': 'Origin', 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
}
async function sha256(s: string) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)); return Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join(''); }

Deno.serve(async (req) => {
  const H = cors(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: H });
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  if (req.method === 'GET') {
    if (!new URL(req.url).searchParams.has('stats')) return new Response(JSON.stringify({ error: 'use POST to send a flag, or GET ?stats=1' }), { status: 400, headers: H });
    const { data, error } = await sb.rpc('olo_feedback_stats');
    if (error) return new Response(JSON.stringify({ error: 'stats_unavailable' }), { status: 503, headers: H });
    return new Response(JSON.stringify(data), { headers: { ...H, 'Cache-Control': 'public, max-age=60' } });
  }
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: H });

  const body = await req.json().catch(() => null);
  const parsed = parseFeedback(body);
  if (!parsed.ok) return new Response(JSON.stringify({ error: parsed.error }), { status: 400, headers: H });
  const f = parsed.value;

  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown').split(',')[0].trim();
  const ipHash = (await sha256(ip + '|' + (Deno.env.get('OLO_SALT') || 'olo') + '|' + new Date().toISOString().slice(0, 10))).slice(0, 32);
  const since = new Date(Date.now() - 3600e3).toISOString();
  const { count } = await sb.from('olo_feedback').select('id', { count: 'exact', head: true }).eq('ip_hash', ipHash).gt('at', since);
  if ((count || 0) >= PER_HOUR) return new Response(JSON.stringify({ error: 'rate_limited', retry_after_seconds: 600 }), { status: 429, headers: { ...H, 'Retry-After': '600' } });

  if (!isInformative(f)) return new Response(JSON.stringify({ ok: true, stored: false, reason: 'agrees with the verdict; nothing to learn' }), { headers: H });

  // The same person flagging the same sentence the same way within a day counts once.
  const { data: dup } = await sb.from('olo_feedback').select('id').eq('ip_hash', ipHash).eq('claim', f.claim).eq('verdict_user', f.verdict_user).gt('at', new Date(Date.now() - 864e5).toISOString()).limit(1);
  if (dup && dup.length) return new Response(JSON.stringify({ ok: true, stored: false, id: dup[0].id, reason: 'already recorded' }), { headers: H });

  const { data, error } = await sb.from('olo_feedback').insert({ ...f, ip_hash: ipHash }).select('id').single();
  if (error || !data) return new Response(JSON.stringify({ error: 'could not store the flag' + (error && /relation|does not exist/i.test(error.message) ? ' (run sql/002)' : '') }), { status: 503, headers: H });
  return new Response(JSON.stringify({ ok: true, id: data.id, stored: true }), { headers: H });
});

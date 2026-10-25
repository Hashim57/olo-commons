// supabase/functions/olo-brain-ask/index.ts
//
// The Olo brain: questions people choose to share become small orbs in the public
// brain at heliusnetwork.app/olo#brain, linked to the Commons atoms that answered
// them. Unanswered questions also feed olo_gaps, so what people ask drives what
// the Commons reads next.
//
//   POST /functions/v1/olo-brain-ask
//     { "question": "1..500 chars", "client": "web|ios|macos", "atoms": ["<atom uuid>", ...max 12], "answered": true }
//     -> { "status": "published" | "held" | "skipped", "id": 123 | null, "reason"?: "..." }
//   GET  /functions/v1/olo-brain-ask?recent=200  -> { "questions": [ { id, text, client, asks, created_at, atoms } ] }  (published only, newest first, max 500)
//   GET  /functions/v1/olo-brain-ask?stats=1     -> { "published", "held", "today" }
//
// Stored: the scrubbed question text, the client name, the atom ids, whether it was answered and a
// count of asks. Never a user id, never an address (a daily-salted hash lives only in the rate-limit
// tables and is deleted after two days), never the conversation or the answer. Anything that still
// looks personal after scrubbing, crisis text, abuse or a question under 8 characters is held for a
// person and never shown (docs/BRAIN.md). 30 questions an hour per address; olo-web, which calls from
// one server address with the service key for every user, gets a larger budget.
//
// Deploy: supabase functions deploy olo-brain-ask --no-verify-jwt   (needs sql/003_brain_questions.sql)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { bearer, judge, normalise, parseAsk, PER_HOUR, PER_HOUR_SERVICE, recentLimit, sameSecret } from './brain.ts';

const ALLOWED_ORIGINS = ['https://heliusnetwork.app', 'https://helius-olo.io', 'https://www.helius-olo.io', 'https://kokorozashi.io', 'https://heliusnetwork.com'];

function cors(origin: string | null) {
  const ok = origin && (ALLOWED_ORIGINS.includes(origin) || /^https:\/\/[a-z0-9-]+--stupendous-begonia-5e8cf9\.netlify\.app$/.test(origin));
  return { 'Access-Control-Allow-Origin': ok ? origin! : ALLOWED_ORIGINS[0], 'Access-Control-Allow-Headers': 'Content-Type, apikey, authorization', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Vary': 'Origin', 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
}
async function sha256(s: string) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)); return Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join(''); }
const json = (body: unknown, status: number, headers: Record<string, string>) => new Response(JSON.stringify(body), { status, headers });
const missingSql = (e: { message?: string } | null) => !!e && /relation|does not exist|function .* not found|Could not find the function/i.test(e.message || '');

Deno.serve(async (req) => {
  const H = cors(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: H });
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, { auth: { persistSession: false } });

  if (req.method === 'GET') {
    const p = new URL(req.url).searchParams;
    if (p.has('stats')) {
      const { data, error } = await sb.rpc('olo_brain_stats');
      if (error || !data) return json({ error: 'stats_unavailable' + (missingSql(error) ? ' (run sql/003)' : '') }, 503, H);
      return json(data, 200, { ...H, 'Cache-Control': 'public, max-age=30' });
    }
    if (p.has('recent')) {
      const { data, error } = await sb.rpc('olo_brain_recent', { p_limit: recentLimit(p.get('recent')) });
      if (error) return json({ error: 'recent_unavailable' + (missingSql(error) ? ' (run sql/003)' : '') }, 503, H);
      return json({ questions: Array.isArray(data) ? data : [] }, 200, { ...H, 'Cache-Control': 'public, max-age=30' });
    }
    return json({ error: 'use POST to add a question, or GET ?recent=200 or ?stats=1' }, 400, H);
  }
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, H);

  const parsed = parseAsk(await req.json().catch(() => null));
  if (!parsed.ok) return json({ error: parsed.error }, 400, H);
  const ask = parsed.value;

  // olo-web calls from its server with the service key, for every signed-in user, from one address.
  const service = sameSecret(bearer(req.headers.get('authorization')), serviceKey) || sameSecret(req.headers.get('apikey') || '', serviceKey);
  const ip = service ? 'olo-web-server' : (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown').split(',')[0].trim();
  const ipHash = (await sha256(ip + '|' + (Deno.env.get('OLO_SALT') || 'olo') + '|' + new Date().toISOString().slice(0, 10))).slice(0, 32);

  const v = judge(ask.question);
  const normHash = await sha256(normalise(v.text));
  const { data, error } = await sb.rpc('olo_brain_record', {
    p_text: v.text, p_norm_hash: normHash, p_client: ask.client, p_atoms: ask.atoms, p_answered: ask.answered,
    p_status: v.status, p_reason: v.reason, p_ip_hash: ipHash,
    p_per_hour: service ? PER_HOUR_SERVICE : PER_HOUR,
    // The gap table caps each address at 20 topics a day; olo-web's single address would hit that for everyone.
    p_gap_ip_hash: service ? null : ipHash,
    // One address asking the same question twice in a day counts once. olo-web's address is shared by everyone.
    p_once_per_address: !service,
  });
  if (error || !data) return json({ status: 'skipped', id: null, reason: 'could not store the question' + (missingSql(error) ? ' (run sql/003)' : '') }, 503, H);
  const r = data as { limited?: boolean; id?: number; status?: string; counted?: boolean };
  if (r.limited) return json({ status: 'skipped', id: null, reason: 'rate_limited' }, 429, { ...H, 'Retry-After': '600' });
  // A rejected row is reported as held: the caller learns nothing about review decisions.
  const status = r.status === 'published' ? 'published' : 'held';
  if (!r.counted) return json({ status: 'skipped', id: r.id ?? null, reason: 'already counted today' }, 200, H);
  return json(status === 'held' ? { status, id: r.id ?? null, reason: v.reason || 'under review' } : { status, id: r.id ?? null }, 200, H);
});

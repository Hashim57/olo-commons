// supabase/functions/olo-answer/index.ts
//
// Olo answers a question from the Commons and has every sentence checked.
//
//   POST /functions/v1/olo-answer   { "q": "when was project gutenberg founded", "k": 8 }
//   GET  /functions/v1/olo-answer?q=...&k=8
//
// Steps: retrieve passages exactly as olo-query does (meaning search merged
// with keyword search by reciprocal rank fusion), ask a hosted open-weight
// model for two to four sentences that cite passage ids, then ask the verifier
// for every sentence whether its passages support, contradict or do not cover
// it. The response carries the answer, each sentence with its verdict and
// quoted evidence, every passage with full provenance, and which verifier ran.
//
// Deploy:  supabase functions deploy olo-answer --no-verify-jwt
// Secrets (Supabase project secrets, never in code):
//   OLO_LLM_API_KEY    key for an OpenAI-compatible chat API (required; without it the function answers 503)
//   OLO_LLM_BASE_URL   default https://api.groq.com/openai/v1
//   OLO_LLM_MODEL      default qwen/qwen3-32b (Apache 2.0 weights)
//   OLO_ZEUS_URL       optional: an OpenAI-compatible endpoint serving a Zeus adapter (zeus/serve.py).
//                      When unset, the same hosted model verifies with the Zeus prompt and the
//                      response says so (verifier: "llm-fallback"), never pretending Zeus ran.
//   OLO_ZEUS_MODEL     model name to send to OLO_ZEUS_URL (default default_model, which makes
//                      mlx_lm.server, started by zeus/serve_mac.sh, answer with the adapter it loaded)
//   OLO_API_KEYS, OLO_SALT   as in olo-query
//
// Limits: the same rate limit as olo-query (120 an hour per hashed address,
// 3000 with a partner key), shared through olo_query_log with client "answer".
// Question text is never stored. The model calls are bounded (max_tokens) and
// time-limited so a slow provider cannot hold the function open.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { fuse } from './rank.ts';
import { ANSWER_SYSTEM, checkEvidence, labelPassages, NOT_COVERED_TEXT, parseVerdict, renderAnswerPrompt, renderZeusPrompt, splitSentences, summarise, ZEUS_SYSTEM, type Passage, type Verdict } from './answer.ts';

const ALLOWED_ORIGINS = ['https://heliusnetwork.app', 'https://helius-olo.io', 'https://www.helius-olo.io', 'https://kokorozashi.io', 'https://heliusnetwork.com'];
const ANON_PER_HOUR = 120, KEYED_PER_HOUR = 3000, MAX_Q = 400, MAX_SENTENCES = 5;
const LLM_TIMEOUT_MS = 25_000, VERIFY_TIMEOUT_MS = 20_000;

function cors(origin: string | null) {
  const ok = origin && (ALLOWED_ORIGINS.includes(origin) || /^https:\/\/[a-z0-9-]+--stupendous-begonia-5e8cf9\.netlify\.app$/.test(origin));
  return { 'Access-Control-Allow-Origin': ok ? origin! : ALLOWED_ORIGINS[0], 'Access-Control-Allow-Headers': 'Content-Type, x-olo-key, apikey, authorization', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Vary': 'Origin', 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
}
async function sha256(s: string) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)); return Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join(''); }

/** One chat completion against an OpenAI-compatible API. Returns the text or throws. */
async function chat(baseUrl: string, apiKey: string, model: string, system: string, user: string, maxTokens: number, timeoutMs: number): Promise<string> {
  const r = await fetch(`${baseUrl.replace(/\/+$/, '')}/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}) },
    body: JSON.stringify({ model, messages: [{ role: 'system', content: system }, { role: 'user', content: user }], temperature: 0, max_tokens: maxTokens }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!r.ok) throw new Error(`model ${r.status}`);
  const j = await r.json();
  const text = j?.choices?.[0]?.message?.content;
  if (typeof text !== 'string') throw new Error('model returned no text');
  // some providers wrap reasoning in <think> blocks; the answer is what follows
  return text.replace(/<think>[\s\S]*?<\/think>/g, '').trim();
}

Deno.serve(async (req) => {
  const H = cors(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response('', { status: 204, headers: H });
  if (req.method !== 'GET' && req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: H });

  let q = '', k = 8;
  if (req.method === 'POST') { const b = await req.json().catch(() => ({})); q = String(b.q || ''); k = Number(b.k) || 8; }
  else { const u = new URL(req.url); q = u.searchParams.get('q') || ''; k = Number(u.searchParams.get('k')) || 8; }
  q = q.replace(/\s+/g, ' ').trim().slice(0, MAX_Q); k = Math.max(2, Math.min(k, 12));
  if (q.length < 2) return new Response(JSON.stringify({ error: 'q is required (2 to 400 characters)' }), { status: 400, headers: H });

  const llmKey = Deno.env.get('OLO_LLM_API_KEY') || '';
  if (!llmKey) return new Response(JSON.stringify({ error: 'answering_not_configured', hint: 'set OLO_LLM_API_KEY' }), { status: 503, headers: H });
  const llmBase = Deno.env.get('OLO_LLM_BASE_URL') || 'https://api.groq.com/openai/v1';
  const llmModel = Deno.env.get('OLO_LLM_MODEL') || 'qwen/qwen3-32b';
  const zeusUrl = Deno.env.get('OLO_ZEUS_URL') || '';
  const zeusModel = Deno.env.get('OLO_ZEUS_MODEL') || 'default_model';

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  // rate limit, shared with olo-query (same log, same hashing, never the raw address)
  const keys = (Deno.env.get('OLO_API_KEYS') || '').split(',').map(s => s.trim()).filter(Boolean);
  const hdrKey = req.headers.get('x-olo-key') || '';
  let keyed = keys.length > 0 && keys.includes(hdrKey);
  if (!keyed && hdrKey.startsWith('olo_')) { const { data } = await sb.rpc('olo_key_valid', { p_key: hdrKey }); keyed = data === true; }
  const ip = (req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown').split(',')[0].trim();
  const ipHash = (await sha256(ip + '|' + (Deno.env.get('OLO_SALT') || 'olo') + '|' + new Date().toISOString().slice(0, 10))).slice(0, 32);
  const { count } = await sb.from('olo_query_log').select('id', { count: 'exact', head: true }).eq('ip_hash', ipHash).gt('at', new Date(Date.now() - 3600e3).toISOString());
  if ((count || 0) >= (keyed ? KEYED_PER_HOUR : ANON_PER_HOUR)) return new Response(JSON.stringify({ error: 'rate_limited', retry_after_seconds: 600 }), { status: 429, headers: { ...H, 'Retry-After': '600' } });

  // retrieve, exactly as olo-query does
  const want = Math.min(k * 2, 30);
  let semantic: any[] = [], keyword: any[] = [];
  try {
    // @ts-ignore provided by the Edge runtime
    const model = new Supabase.ai.Session('gte-small');
    const emb: number[] = await model.run(q, { mean_pool: true, normalize: true });
    const { data } = await sb.rpc('olo_match', { p_embedding: emb, p_k: want, p_min: 0.5 });
    semantic = Array.isArray(data) ? data : [];
  } catch (_) { /* keyword only */ }
  { const { data } = await sb.rpc('olo_search_text', { p_q: q, p_k: want }); keyword = Array.isArray(data) ? data : []; }
  const results = fuse(semantic, keyword, k);
  const passages: Passage[] = labelPassages(results);
  const provenance = results.map((r: any, i: number) => ({ id: `p${i + 1}`, atom: r.id, title: r.title, url: r.url, source: r.source, source_slug: r.source_slug, licence: r.licence, published_at: r.published_at || null, retrieved_at: r.retrieved_at, match: r.match }));

  const logIt = (results_n: number) => sb.from('olo_query_log').insert({ ip_hash: ipHash, q_len: q.length, results: results_n, client: 'answer' + (keyed ? ':keyed' : '') }).then(() => {}, () => {});

  if (!passages.length) {
    await logIt(0);
    return new Response(JSON.stringify({ q, answer: NOT_COVERED_TEXT, sentences: [], passages: [], verifier: null, model: null, summary: summarise([]), covered: false, attribution: 'Olo Commons by Helius Network.' }), { headers: H });
  }

  // draft
  let answer: string;
  try { answer = await chat(llmBase, llmKey, llmModel, ANSWER_SYSTEM, renderAnswerPrompt(q, passages), 400, LLM_TIMEOUT_MS); }
  catch (e) { await logIt(passages.length); return new Response(JSON.stringify({ error: 'model_unavailable', detail: String((e as Error).message || e).slice(0, 120) }), { status: 502, headers: H }); }

  const covered = !answer.includes(NOT_COVERED_TEXT);
  const sentences = covered ? splitSentences(answer).slice(0, MAX_SENTENCES) : [];

  // verify every sentence against its cited passages (all passages when it cites none)
  const verifier = zeusUrl ? `zeus:${zeusModel}` : 'llm-fallback';
  const verdicts = await Promise.all(sentences.map(async (s) => {
    const cited = passages.filter(p => s.citations.includes(p.id));
    const scope = cited.length ? cited : passages;
    let v: Verdict | null = null;
    try {
      const text = zeusUrl
        ? await chat(zeusUrl, Deno.env.get('OLO_ZEUS_API_KEY') || '', zeusModel, ZEUS_SYSTEM, renderZeusPrompt(s.text, scope), 200, VERIFY_TIMEOUT_MS)
        : await chat(llmBase, llmKey, llmModel, ZEUS_SYSTEM, renderZeusPrompt(s.text, scope), 200, VERIFY_TIMEOUT_MS);
      v = parseVerdict(text);
    } catch (_) { v = null; }
    const checked = v ? checkEvidence(v, scope) : { label: 'not_covered' as const, evidence: [], rationale: 'The verifier gave no usable answer.', evidence_checked: false };
    return { text: s.text, citations: s.citations, verdict: checked.label, evidence: checked.evidence, rationale: checked.rationale, evidence_checked: checked.evidence_checked };
  }));

  await logIt(passages.length);
  // a question the Commons could not answer is a gap worth filling; the RPC exists once sql/001 has been rerun, so a failure here is ignored
  if (!covered || (verdicts.length && verdicts.every(v => v.verdict === 'not_covered'))) sb.rpc('olo_record_gap', { p_q: q }).then(() => {}, () => {});

  return new Response(JSON.stringify({
    q, answer: covered ? sentences.map(s => s.text).join(' ') : NOT_COVERED_TEXT, covered, sentences: verdicts, summary: summarise(verdicts),
    passages: provenance, verifier, model: llmModel,
    attribution: 'Olo Commons by Helius Network. Each passage carries its own source and licence; cite them.', api: 'https://heliusnetwork.app/olo/#api',
  }), { headers: H });
});

// Zeus on Cloudflare Workers AI.
//
// A fixed, always-on address for the Zeus verifier: an OpenAI-compatible API in
// front of Workers AI running Mistral 7B Instruct v0.2 with the Zeus LoRA
// adapter trained on Olo Commons. Both olo-answer (Commons) and helius-olo.io
// call it exactly as they would call any OpenAI-style endpoint.
//
//   GET  /health                      no key: {ok, version, lora}
//   GET  /v1/models                   Bearer ZEUS_TOKEN: the model list plus the measured scores of the version serving
//   POST /v1/chat/completions         Bearer ZEUS_TOKEN: model "default_model" (or "zeus") runs one Zeus
//                                     verification; model "olo-draft" runs the fallback writer (DRAFT_MODEL),
//                                     which both sites use when their main model provider is down
//
// Settings (wrangler.toml vars, updated by zeus/cloudflare/publish.sh when a version is promoted):
//   ZEUS_LORA     name of the uploaded fine-tune (zeus-v6, zeus-v7, ...)
//   ZEUS_VERSION  the Zeus version it holds
//   ZEUS_SCORES   JSON of that version's measured scores (from zeus/BEST.json)
//   ZEUS_MODEL    base model id (default @cf/mistral/mistral-7b-instruct-v0.2-lora)
//   DRAFT_MODEL   the fallback writer (default @cf/meta/llama-3.3-70b-instruct-fp8-fast)
//   ZEUS_FORMAT_RETRY  optional, "1" turns the format retry on for every verification (off when unset);
//                 a request's boolean "format_retry" overrides it either way
//   ZEUS_RETRY_TIMEOUT_MS  optional, a lower time cap for the retry (never above 15000)
//
// Format retry: when the answer is not a valid verdict (no JSON object, bad JSON, a label
// outside supported/contradicted/not_covered), the Worker asks once more with the original
// messages, the bad answer and a short repair instruction, at temperature 0, at most 200
// tokens and 15 seconds. Never more than one retry. The response says "retried" (and, when
// true, carries "zeus_first_answer") so a scorer can keep first-attempt numbers apart; if the
// retry does not parse either, the answer is 502 {error: "zeus_unparseable_answer", ...}.
// Constrained decoding (Workers AI JSON mode, response_format) is not used: the base model
// here is not on Cloudflare's list of JSON mode models.
// Secret: ZEUS_TOKEN (wrangler secret put ZEUS_TOKEN), the key callers send.
//
// The caller never chooses the model or the adapter, bodies are capped, the
// answer is capped at 400 tokens, and the system prompt is folded into the user
// turn because Mistral v0.2 has no system role (Zeus was trained that way).

const DEFAULT_MODEL = '@cf/mistral/mistral-7b-instruct-v0.2-lora';
const MAX_BODY = 64 * 1024;
const MAX_TOKENS = 400;
const DEFAULT_DRAFT = '@cf/meta/llama-3.3-70b-instruct-fp8-fast';
const DRAFT_MAX_TOKENS = 1500;

const LABELS = ['supported', 'contradicted', 'not_covered'];
// Format retry: the one repair turn (identical to REPAIR in zeus/eval.py) and its caps.
export const REPAIR = 'Your answer was not one valid JSON object in the required format. Answer again with only the JSON object '
  + '{"label": "supported" | "contradicted" | "not_covered", "evidence": [{"passage": "<id>", "quote": "<exact words from that passage>"}], '
  + '"rationale": "<one sentence>"} and no other text.';
export const RETRY_MAX_TOKENS = 200;
export const RETRY_TIMEOUT_MS = 15000;
const ANSWER_ECHO = 2000;

/** The verdict in a Zeus answer, or null: the same rule as parse() in zeus/eval.py and parseVerdict in olo-answer. */
export function parseVerdict(text) {
  const m = String(text || '').match(/\{[\s\S]*\}/);
  if (!m) return null;
  let o;
  try { o = JSON.parse(m[0]); } catch { return null; }
  if (!o || typeof o !== 'object' || !LABELS.includes(o.label)) return null;
  return o;
}

/** Retry is off unless ZEUS_FORMAT_RETRY is "1"/"true"; a request's boolean format_retry overrides it either way. */
export function formatRetryOn(env, body) {
  if (typeof body?.format_retry === 'boolean') return body.format_retry;
  return ['1', 'true'].includes(String(env.ZEUS_FORMAT_RETRY || '').toLowerCase());
}

function retryTimeoutMs(env) {
  const n = Number(env.ZEUS_RETRY_TIMEOUT_MS);
  return n > 0 ? Math.min(n, RETRY_TIMEOUT_MS) : RETRY_TIMEOUT_MS;
}

/** The promise, or a rejection after ms; the timer is always cleared. */
export function withTimeout(promise, ms) {
  let timer;
  const t = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('retry timed out after ' + ms + ' ms')), ms); });
  return Promise.race([promise, t]).finally(() => clearTimeout(timer));
}

function json(obj,status = 200, extra = {}) {
  return new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...extra } });
}

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function foldSystem(messages) {
  const sys = messages.filter(m => m && m.role === 'system').map(m => String(m.content ?? '')).join('\n\n');
  const rest = messages.filter(m => m && (m.role === 'user' || m.role === 'assistant')).map(m => ({ role: m.role, content: String(m.content ?? '') }));
  if (!rest.length) return [];
  if (sys) {
    const i = rest.findIndex(m => m.role === 'user');
    if (i >= 0) rest[i] = { role: 'user', content: sys + '\n\n' + rest[i].content };
  }
  return rest;
}

/** Mistral Instruct's own prompt format, for the raw path: the template Zeus was trained with. */
export function mistralPrompt(messages) {
  let out = '<s>';
  for (const m of messages) {
    if (m.role === 'user') out += `[INST] ${m.content} [/INST]`;
    else if (m.role === 'assistant') out += ` ${m.content}</s>`;
  }
  return out;
}

/** The text in whatever shape Workers AI returned it (response, result.response, a bare string). */
export function answerText(out) {
  if (typeof out === 'string') return out.trim();
  if (typeof out?.response === 'string') return out.response.trim();
  if (typeof out?.result?.response === 'string') return out.result.response.trim();
  if (Array.isArray(out?.choices) && typeof out.choices[0]?.message?.content === 'string') return out.choices[0].message.content.trim();
  return '';
}

export function scores(env) {
  try { return env.ZEUS_SCORES ? JSON.parse(env.ZEUS_SCORES) : null; } catch { return null; }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '');
    if (request.method === 'GET' && path === '/health') {
      return json({ ok: Boolean(env.ZEUS_LORA), version: env.ZEUS_VERSION || null, lora: env.ZEUS_LORA || null, model: env.ZEUS_MODEL || DEFAULT_MODEL });
    }
    if (!path.startsWith('/v1/')) return json({ error: 'not_found' }, 404);
    const auth = request.headers.get('authorization') || '';
    if (!env.ZEUS_TOKEN || !auth.startsWith('Bearer ') || !safeEqual(auth.slice(7).trim(), env.ZEUS_TOKEN)) {
      return json({ error: 'unauthorized' }, 401);
    }
    if (request.method === 'GET' && path === '/v1/models') {
      return json({ object: 'list', data: [{ id: 'default_model', object: 'model', owned_by: 'olo' }, { id: 'olo-draft', object: 'model', owned_by: 'olo' }], zeus: scores(env) });
    }
    if (request.method !== 'POST' || path !== '/v1/chat/completions') return json({ error: 'not_found' }, 404);

    const len = Number(request.headers.get('content-length') || 0);
    if (len > MAX_BODY) return json({ error: 'body_too_large' }, 413);
    const raw = await request.text();
    if (!raw || raw.length > MAX_BODY) return json({ error: 'body_too_large_or_empty' }, 413);
    let body;
    try { body = JSON.parse(raw); } catch { return json({ error: 'bad_json' }, 400); }
    const draft = body?.model === 'olo-draft';
    const incoming = Array.isArray(body?.messages) ? body.messages : [];
    if (draft) {
      const messages = incoming.filter(m => m && ['system', 'user', 'assistant'].includes(m.role)).map(m => ({ role: m.role, content: String(m.content ?? '') }));
      if (!messages.some(m => m.role === 'user')) return json({ error: 'messages_required' }, 400);
      const maxTokens = Math.max(1, Math.min(Number(body.max_tokens) || 800, DRAFT_MAX_TOKENS));
      const temperature = Math.max(0, Math.min(Number(body.temperature ?? 0.3), 1));
      try {
        const out = await env.AI.run(env.DRAFT_MODEL || DEFAULT_DRAFT, { messages, max_tokens: maxTokens, temperature });
        const text = typeof out?.response === 'string' ? out.response : '';
        if (!text) return json({ error: 'draft_empty_answer' }, 502);
        return json({ id: 'draft-' + crypto.randomUUID(), object: 'chat.completion', created: Math.floor(Date.now() / 1000), model: 'olo-draft',
          choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }], usage: out?.usage || undefined });
      } catch (e) {
        return json({ error: 'draft_unavailable', detail: String(e?.message || e).slice(0, 160) }, 502);
      }
    }

    if (!env.ZEUS_LORA) return json({ error: 'zeus_not_published', detail: 'no adapter uploaded yet; run zeus/cloudflare/publish.sh' }, 503);
    const messages = foldSystem(incoming);
    if (!messages.length) return json({ error: 'messages_required' }, 400);
    const maxTokens = Math.max(1, Math.min(Number(body.max_tokens) || 200, MAX_TOKENS));

    try {
      // Two ways to run the adapter: the chat form, then the raw form with Mistral's own template (what Zeus
      // trained on). Workers AI has answered empty to one and not the other; the response says which one answered.
      const model = env.ZEUS_MODEL || DEFAULT_MODEL;
      const attempts = [
        { how: 'messages', input: { messages, lora: env.ZEUS_LORA, max_tokens: maxTokens, temperature: 0 } },
        { how: 'raw', input: { prompt: mistralPrompt(messages), raw: true, lora: env.ZEUS_LORA, max_tokens: maxTokens, temperature: 0 } },
        { how: 'messages-default-temperature', input: { messages, lora: env.ZEUS_LORA, max_tokens: maxTokens } },
      ];
      let text = '', how = '', shapes = [], out = null;
      for (const a of attempts) {
        out = await env.AI.run(model, a.input);
        text = answerText(out);
        shapes.push(a.how + ':' + (out && typeof out === 'object' ? Object.keys(out).join('|') : typeof out));
        if (text) { how = a.how; break; }
      }
      if (!text) return json({ error: 'zeus_empty_answer', detail: 'Workers AI returned no text; shapes ' + shapes.join(', ') + '; lora ' + env.ZEUS_LORA + ' on ' + model }, 502);

      // Format retry (opt in): one repair attempt when the first answer is not a valid verdict. Never more than one.
      let retried = false, firstAnswer = null;
      if (formatRetryOn(env, body) && !parseVerdict(text)) {
        retried = true; firstAnswer = text;
        const fixMessages = [...messages, { role: 'assistant', content: text }, { role: 'user', content: REPAIR }];
        const fixTokens = Math.min(maxTokens, RETRY_MAX_TOKENS);
        const fixInput = how === 'raw'
          ? { prompt: mistralPrompt(fixMessages), raw: true, lora: env.ZEUS_LORA, max_tokens: fixTokens, temperature: 0 }
          : { messages: fixMessages, lora: env.ZEUS_LORA, max_tokens: fixTokens, temperature: 0 };
        let fixed = '', retryError = '';
        try {
          fixed = answerText(await withTimeout(env.AI.run(model, fixInput), retryTimeoutMs(env)));
        } catch (e) {
          retryError = String(e?.message || e).slice(0, 160);
        }
        if (!parseVerdict(fixed)) {
          return json({ error: 'zeus_unparseable_answer', retried: true,
            detail: retryError ? 'first answer did not parse; the one retry failed: ' + retryError : 'neither the answer nor the one retry parsed as a verdict',
            first_answer: firstAnswer.slice(0, ANSWER_ECHO), retry_answer: fixed.slice(0, ANSWER_ECHO) }, 502);
        }
        text = fixed;
      }
      return json({
        zeus_path: how,
        retried,
        ...(retried ? { zeus_first_answer: firstAnswer.slice(0, ANSWER_ECHO) } : {}),
        id: 'zeus-' + crypto.randomUUID(), object: 'chat.completion', created: Math.floor(Date.now() / 1000),
        model: 'zeus-' + (env.ZEUS_VERSION || 'unknown'),
        choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
        usage: out?.usage || undefined,
      });
    } catch (e) {
      return json({ error: 'zeus_unavailable', detail: String(e?.message || e).slice(0, 160) }, 502);
    }
  },
};

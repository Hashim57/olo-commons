// deno test --allow-read tests/
import { assert, assertEquals } from './_assert.ts';
// @ts-ignore plain JS module
import worker, { foldSystem } from '../zeus/cloudflare/worker.js';

const TOKEN = 'z'.repeat(40);
function env(over: Record<string, unknown> = {}) {
  const calls: unknown[] = [];
  return {
    calls,
    ZEUS_TOKEN: TOKEN, ZEUS_LORA: 'zeus-v6', ZEUS_VERSION: 'v6', ZEUS_SCORES: '{"version":"v6","label_accuracy":0.86}',
    AI: { run: async (model: string, input: unknown) => { calls.push({ model, input }); return { response: '{"label":"supported","evidence":[],"rationale":"ok"}' }; } },
    ...over,
  };
}
const req = (path: string, init: RequestInit = {}, token: string | null = TOKEN) =>
  new Request('https://zeus.example.workers.dev' + path, { ...init, headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}), ...(init.headers || {}) } });

Deno.test('health is public and says which adapter serves', async () => {
  const r = await worker.fetch(req('/health', {}, null), env());
  assertEquals(r.status, 200);
  const j = await r.json();
  assertEquals(j.version, 'v6'); assertEquals(j.lora, 'zeus-v6'); assertEquals(j.ok, true);
});

Deno.test('everything under /v1 needs the token', async () => {
  assertEquals((await worker.fetch(req('/v1/models', {}, null), env())).status, 401);
  assertEquals((await worker.fetch(req('/v1/models', {}, 'wrong'), env())).status, 401);
  assertEquals((await worker.fetch(req('/v1/models', {}, TOKEN), env({ ZEUS_TOKEN: '' }))).status, 401);
  const m = await (await worker.fetch(req('/v1/models'), env())).json();
  assertEquals(m.data[0].id, 'default_model'); assertEquals(m.zeus.label_accuracy, 0.86);
});

Deno.test('a verification runs the adapter with the system prompt folded in and the caller unable to pick the model', async () => {
  const e = env();
  const r = await worker.fetch(req('/v1/chat/completions', { method: 'POST', body: JSON.stringify({ model: 'evil', max_tokens: 9999, messages: [{ role: 'system', content: 'SYS' }, { role: 'user', content: 'Claim: x' }] }) }), e);
  assertEquals(r.status, 200);
  const j = await r.json();
  assert(j.choices[0].message.content.includes('supported'));
  assertEquals(j.model, 'zeus-v6');
  const call = e.calls[0] as { model: string; input: { messages: { role: string; content: string }[]; lora: string; max_tokens: number; temperature: number } };
  assertEquals(call.model, '@cf/mistral/mistral-7b-instruct-v0.2-lora');
  assertEquals(call.input.lora, 'zeus-v6');
  assertEquals(call.input.max_tokens, 400);
  assertEquals(call.input.temperature, 0);
  assertEquals(call.input.messages, [{ role: 'user', content: 'SYS\n\nClaim: x' }]);
});

Deno.test('failures are reported, never turned into an answer', async () => {
  assertEquals((await worker.fetch(req('/v1/chat/completions', { method: 'POST', body: '{"messages":[{"role":"user","content":"x"}]}' }), env({ ZEUS_LORA: '' }))).status, 503);
  const boom = env({ AI: { run: async () => { throw new Error('capacity'); } } });
  const r = await worker.fetch(req('/v1/chat/completions', { method: 'POST', body: '{"messages":[{"role":"user","content":"x"}]}' }), boom);
  assertEquals(r.status, 502); assertEquals((await r.json()).error, 'zeus_unavailable');
  assertEquals((await worker.fetch(req('/v1/chat/completions', { method: 'POST', body: 'nope' }), env())).status, 400);
  assertEquals((await worker.fetch(req('/v1/chat/completions', { method: 'POST', body: '{"messages":[]}' }), env())).status, 400);
  assertEquals((await worker.fetch(req('/v1/other', { method: 'POST', body: '{}' }), env())).status, 404);
});

Deno.test('olo-draft runs the fallback writer with the system role kept, and works before any adapter exists', async () => {
  const e = env({ ZEUS_LORA: '' });
  const r = await worker.fetch(req('/v1/chat/completions', { method: 'POST', body: JSON.stringify({ model: 'olo-draft', max_tokens: 99999, temperature: 5, messages: [{ role: 'system', content: 'S' }, { role: 'user', content: 'Q' }] }) }), e);
  assertEquals(r.status, 200);
  assertEquals((await r.json()).model, 'olo-draft');
  const call = e.calls[0] as { model: string; input: { messages: unknown[]; max_tokens: number; temperature: number; lora?: string } };
  assertEquals(call.model, '@cf/meta/llama-3.3-70b-instruct-fp8-fast');
  assertEquals(call.input.messages, [{ role: 'system', content: 'S' }, { role: 'user', content: 'Q' }]);
  assertEquals(call.input.max_tokens, 1500); assertEquals(call.input.temperature, 1); assertEquals(call.input.lora, undefined);
});

Deno.test('foldSystem keeps the conversation and joins system text into the first user turn', () => {
  assertEquals(foldSystem([{ role: 'user', content: 'a' }]), [{ role: 'user', content: 'a' }]);
  assertEquals(foldSystem([{ role: 'system', content: 's' }]), []);
  assertEquals(foldSystem([{ role: 'system', content: 's1' }, { role: 'system', content: 's2' }, { role: 'user', content: 'u' }, { role: 'assistant', content: 'a' }]),
    [{ role: 'user', content: 's1\n\ns2\n\nu' }, { role: 'assistant', content: 'a' }]);
});

// @ts-ignore plain JS module
import { answerText, mistralPrompt } from '../zeus/cloudflare/worker.js';

Deno.test('mistralPrompt renders the Instruct template Zeus trained with', () => {
  assertEquals(mistralPrompt([{ role: 'user', content: 'Claim: x' }]), '<s>[INST] Claim: x [/INST]');
  assertEquals(mistralPrompt([{ role: 'user', content: 'a' }, { role: 'assistant', content: 'b' }, { role: 'user', content: 'c' }]), '<s>[INST] a [/INST] b</s>[INST] c [/INST]');
});

Deno.test('answerText reads every shape Workers AI has used', () => {
  assertEquals(answerText({ response: ' {"label":"supported"} ' }), '{"label":"supported"}');
  assertEquals(answerText({ result: { response: 'x' } }), 'x');
  assertEquals(answerText('plain'), 'plain');
  assertEquals(answerText({ choices: [{ message: { content: 'c' } }] }), 'c');
  assertEquals(answerText({ response: '' }), '');
  assertEquals(answerText(null), '');
});

Deno.test('the Worker falls back to the raw Mistral prompt when the chat form answers empty', async () => {
  let n = 0;
  const e = env({ AI: { run: async (_m: string, input: any) => { n++; return input.raw ? { response: '{"label":"not_covered","evidence":[],"rationale":"r"}' } : { response: '' }; } } });
  const r = await worker.fetch(new Request('https://zeus.test/v1/chat/completions', { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' }, body: JSON.stringify({ model: 'default_model', messages: [{ role: 'user', content: 'Claim: y' }] }) }), e);
  const j = await r.json();
  assertEquals(r.status, 200);
  assertEquals(j.zeus_path, 'raw');
  assertEquals(n, 2);
  assert(j.choices[0].message.content.includes('not_covered'));
});

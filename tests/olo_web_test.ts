// deno test --allow-read tests/
import { assert, assertEquals } from './_assert.ts';
import { answerText, askCommons, commonsEvents, toSources, toVerification, verifierLabel, type CommonsAnswer } from '../integrations/olo-web/commons.ts';

const SAMPLE: CommonsAnswer = {
  q: 'when was project gutenberg founded', covered: true, verifier: 'llm-fallback', model: 'openai/gpt-oss-120b',
  answer: 'Project Gutenberg was founded in 1971 by Michael Hart. It hosts over one million books.',
  sentences: [
    { text: 'Project Gutenberg was founded in 1971 by Michael Hart.', citations: ['p1'], verdict: 'supported', evidence: [{ passage: 'p1', quote: 'founded in 1971 by Michael S. Hart' }], rationale: 'Stated in p1.', evidence_checked: true },
    { text: 'It hosts over one million books.', citations: ['p2'], verdict: 'contradicted', evidence: [{ passage: 'p2', quote: 'over 70,000 free eBooks' }], rationale: 'p2 gives a far smaller number.', evidence_checked: true },
    { text: 'It is the oldest digital library.', citations: [], verdict: 'not_covered', evidence: [], rationale: 'Not settled by the passages.', evidence_checked: true },
  ],
  summary: { supported: 1, contradicted: 1, not_covered: 1 },
  passages: [
    { id: 'p1', atom: 'a1', title: 'Project Gutenberg', summary: 'Founded in 1971 by Michael S. Hart.', url: 'https://en.wikipedia.org/wiki/Project_Gutenberg', source: 'Wikipedia', source_slug: 'wikipedia', licence: 'CC BY-SA 4.0', retrieved_at: '2026-10-20T10:00:00Z', match: 'both' },
    { id: 'p2', atom: 'a2', title: 'Gutenberg collection', summary: 'over 70,000 free eBooks', url: 'https://www.gutenberg.org/', source: 'Project Gutenberg', source_slug: 'gutenberg', licence: 'Public domain', retrieved_at: '2026-10-21T10:00:00Z', match: 'keyword' },
  ],
};

Deno.test('sources are numbered from 1 and keep provenance', () => {
  const s = toSources(SAMPLE);
  assertEquals(s.map(x => x.index), [1, 2]);
  assertEquals(s[0].url, 'https://en.wikipedia.org/wiki/Project_Gutenberg');
  assertEquals(s[0].publisher, 'Wikipedia');
  assertEquals(s[1].licence, 'Public domain');
});

Deno.test('verification maps verdicts and citations to the client shape', () => {
  const v = toVerification(SAMPLE);
  assertEquals(v.claims.map(c => c.verdict), ['supported', 'contradicted', 'unsupported']);
  assertEquals(v.claims[0].citedBy, [1]);
  assertEquals(v.claims[1].excerpt, 'over 70,000 free eBooks');
  assertEquals(v.claims[2].citedBy, []);
  assert(v.claims.every(c => c.recalled === false));
  assertEquals(v.verifier, 'llm-fallback');
});

Deno.test('events come in the order the client expects', () => {
  const ev = commonsEvents(SAMPLE, { followups: ['Who was Michael Hart?'] });
  assertEquals(ev.map(e => e.type), ['status', 'sources', 'status', 'delta', 'delta', 'delta', 'verification', 'followups']);
  assertEquals(ev[3].text, 'Project Gutenberg was founded in 1971 by Michael Hart. [1]');
  assertEquals(ev[5].text, ' It is the oldest digital library.');
  assert(String(ev[2].detail).includes('Zeus not connected'));
  assertEquals(answerText(SAMPLE), 'Project Gutenberg was founded in 1971 by Michael Hart. [1] It hosts over one million books. [2] It is the oldest digital library.');
});

Deno.test('an uncovered answer becomes a notice, never an empty claim list', () => {
  const none: CommonsAnswer = { ...SAMPLE, covered: false, sentences: [], passages: [] };
  const ev = commonsEvents(none);
  assertEquals(ev.map(e => e.type), ['status', 'notice']);
  assertEquals(answerText(none), 'Olo Commons does not cover this yet.');
  assertEquals(verifierLabel({ ...SAMPLE, verifier: 'zeus:default_model' }), 'Checked by Zeus against Olo Commons passages');
});

Deno.test('askCommons returns null on any failure and the parsed answer on success', async () => {
  const bad = async () => new Response('{"error":"rate_limited"}', { status: 429 });
  assertEquals(await askCommons('x'.repeat(5), { fetchFn: bad as unknown as typeof fetch }), null);
  const boom = async () => { throw new Error('offline'); };
  assertEquals(await askCommons('hello world', { fetchFn: boom as unknown as typeof fetch }), null);
  assertEquals(await askCommons('a', {}), null); // too short, no call made
  let seen: unknown = null;
  const good = async (_u: unknown, init: RequestInit) => { seen = JSON.parse(String(init.body)); return new Response(JSON.stringify(SAMPLE), { status: 200 }); };
  const a = await askCommons('  when was   project gutenberg founded ', { k: 50, fetchFn: good as unknown as typeof fetch });
  assertEquals((seen as { q: string; k: number }).q, 'when was project gutenberg founded');
  assertEquals((seen as { k: number }).k, 12);
  assertEquals(a?.sentences.length, 3);
});

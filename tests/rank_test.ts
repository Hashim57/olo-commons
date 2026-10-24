// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { citation, fuse, RRF_C } from '../functions/olo-query/rank.ts';

const sem = (id: string, similarity: number, extra: Record<string, unknown> = {}) => ({ id, similarity, content: `content of ${id}`, ...extra });
const key = (id: string, rank: number, extra: Record<string, unknown> = {}) => ({ id, rank, ...extra });

Deno.test('an atom found by both retrievers outranks one found by only the semantic search', () => {
  // s1 is the top semantic hit but only semantic; s2 is second semantic and top keyword
  const out = fuse([sem('s1', 0.84), sem('s2', 0.82), sem('s3', 0.80)], [key('s2', 0.9), key('k1', 0.5)], 10);
  assertEquals(out.map(r => r.id), ['s2', 's1', 'k1', 's3']);
  assertEquals(out[0].match, 'both');
  assertEquals(out[1].match, 'semantic');
  assertEquals(out[2].match, 'keyword');
});

Deno.test('scores follow the reciprocal rank formula', () => {
  const out = fuse([sem('a', 0.9)], [key('a', 1)], 5, 60);
  assertEquals(out[0].score, Math.round((1 / 61 + 1 / 61) * 1e6) / 1e6);
  assertEquals(RRF_C, 60);
});

Deno.test('either list alone keeps its own order', () => {
  assertEquals(fuse([sem('a', 0.9), sem('b', 0.8), sem('c', 0.7)], [], 10).map(r => r.id), ['a', 'b', 'c']);
  assertEquals(fuse([], [key('x', 3), key('y', 2), key('z', 1)], 10).map(r => r.id), ['x', 'y', 'z']);
});

Deno.test('k bounds the output and ids are unique', () => {
  const out = fuse([sem('a', 0.9), sem('b', 0.8), sem('c', 0.7)], [key('c', 1), key('d', 0.5), key('a', 0.4)], 2);
  assertEquals(out.length, 2);
  assertEquals(new Set(out.map(r => r.id)).size, 2);
  assertEquals(fuse([sem('a', 0.9)], [], 0).length, 0);
});

Deno.test('fields come from the semantic record, filled from the keyword record where missing', () => {
  const out = fuse([sem('a', 0.9, { published_at: null })], [key('a', 1, { published_at: '2020-01-01', content: 'should not win' })], 5);
  assertEquals(out[0].content, 'content of a');
  assertEquals(out[0].published_at, '2020-01-01');
  assertEquals(out[0].similarity, 0.9);
});

Deno.test('a keyword-only hit has no similarity and a duplicate inside one list counts once', () => {
  const out = fuse([], [key('a', 1), key('a', 1), key('b', 0.5)], 5);
  assertEquals(out.map(r => r.id), ['a', 'b']);
  assertEquals(out[0].similarity, undefined);
  assertEquals(out[0].score, Math.round((1 / 61) * 1e6) / 1e6);
});

Deno.test('ties on score break on similarity, then on first appearance', () => {
  const out = fuse([sem('low', 0.70)], [key('kw', 1)], 5);
  // both have a single position-1 contribution; the semantic one has a similarity, the keyword one does not
  assertEquals(out.map(r => r.id), ['low', 'kw']);
  const out2 = fuse([], [key('first', 1)], 5).concat(fuse([], [key('second', 1)], 5));
  assertEquals(out2.map(r => r.id), ['first', 'second']);
});

Deno.test('malformed entries are skipped', () => {
  const out = fuse([{ id: 'ok', similarity: 0.8 }, { similarity: 0.9 } as unknown as { id: string }, null as unknown as { id: string }], [], 5);
  assertEquals(out.map(r => r.id), ['ok']);
});

Deno.test('citation never prints undefined', () => {
  assertEquals(citation({ title: 'Coral reefs', source: 'Wikipedia', licence: 'CC BY-SA 4.0', url: 'https://x' }), 'Coral reefs (Wikipedia, CC BY-SA 4.0). https://x');
  assertEquals(citation({ title: 'T', source: 'S', url: 'https://x' }), 'T (S). https://x');
  assertEquals(citation({}), 'Untitled.');
  assert(!citation({ title: undefined, source: undefined }).includes('undefined'));
});

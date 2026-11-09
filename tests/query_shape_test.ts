// deno test tests/
// The shape of one olo-query result (functions/olo-query/shape.ts): the fields
// the API has always returned stay exactly as they were, and each result now
// carries the trust and time fields the search RPCs have returned since sql/002.
import { assert, assertEquals } from './_assert.ts';
import { resultOf } from '../functions/olo-query/shape.ts';
import { rank } from '../functions/olo-query/rank.ts';

// One row as olo_match() returns it after sql/002.
const row = {
  id: 'a1', title: 'Project Gutenberg', summary: 'Project Gutenberg is a volunteer effort to digitise books.', content: 'Founded in 1971 by Michael S. Hart.',
  url: 'https://en.wikipedia.org/wiki/Project_Gutenberg', source: 'Wikipedia', source_slug: 'wikipedia', source_kind: 'encyclopedia', licence: 'CC BY-SA 4.0',
  published_at: '2026-10-01', retrieved_at: '2026-10-20T17:00:00Z', observed_at: '2026-11-08T09:15:00Z', valid_from: '2026-10-01', valid_to: null,
  status: 'verified', credibility: 92, corroboration: 2, source_revision: '1250001', similarity: 0.81, match: 'both', score: 0.9,
};

const V1_KEYS = ['id', 'title', 'summary', 'content', 'url', 'source', 'source_slug', 'licence', 'published_at', 'retrieved_at', 'similarity', 'match', 'citation'];
const TRUST_KEYS = ['status', 'credibility', 'corroboration', 'valid_from', 'valid_to', 'observed_at', 'source_revision', 'source_kind'];

Deno.test('the fields the API has always returned come first and are unchanged', () => {
  const r = resultOf(row);
  assertEquals(Object.keys(r), [...V1_KEYS, ...TRUST_KEYS]);
  assertEquals(r.id, 'a1');
  assertEquals(r.content, 'Founded in 1971 by Michael S. Hart.');
  assertEquals(r.similarity, 0.81);
  assertEquals(r.match, 'both');
  assertEquals(r.citation, 'Project Gutenberg (Wikipedia, CC BY-SA 4.0). https://en.wikipedia.org/wiki/Project_Gutenberg');
  // the internal ranking score is not part of the response
  assert(!('score' in r));
});

Deno.test('a result carries its trust and time fields', () => {
  const r = resultOf(row);
  assertEquals(r.status, 'verified');
  assertEquals(r.credibility, 92);
  assertEquals(r.corroboration, 2);
  assertEquals(r.valid_from, '2026-10-01');
  assertEquals(r.valid_to, null);
  assertEquals(r.observed_at, '2026-11-08T09:15:00Z');
  assertEquals(r.source_revision, '1250001');
  assertEquals(r.source_kind, 'encyclopedia');
});

Deno.test('a database from before sql/002 gives nulls, never a guess', () => {
  const old = { id: 'b2', title: 'T', summary: 'S', url: 'https://example.org/t', source: 'arXiv', source_slug: 'arxiv', licence: 'x', retrieved_at: '2026-10-20T17:00:00Z', rank: 0.2, match: 'keyword' };
  const r = resultOf(old);
  for (const k of TRUST_KEYS) assertEquals((r as Record<string, unknown>)[k], null, k);
  assertEquals(r.content, null);
  assertEquals(r.published_at, null);
  assertEquals(r.similarity, null);
});

Deno.test('odd values are not passed on as trust', () => {
  const r = resultOf({ ...row, status: 'trusted', credibility: '92', corroboration: -3, observed_at: '', source_revision: 7 });
  assertEquals(r.status, null);        // not one of the five statuses
  assertEquals(r.credibility, null);   // a string is not a score
  assertEquals(r.corroboration, 0);
  assertEquals(r.observed_at, null);
  assertEquals(r.source_revision, null);
  assertEquals(resultOf({ ...row, credibility: 140 }).credibility, 100);
  assertEquals(resultOf({ ...row, credibility: 66.6 }).credibility, 67);
  assertEquals(resultOf({ ...row, credibility: NaN }).credibility, null);
});

Deno.test('the trust fields survive the ranking that feeds the shape', () => {
  const semantic = [{ ...row, match: undefined, score: undefined }];
  const keyword = [{ id: 'k9', title: 'Michael S. Hart', summary: 'Founder of Project Gutenberg.', url: 'https://en.wikipedia.org/wiki/Michael_S._Hart', source: 'Wikipedia', source_slug: 'wikipedia', licence: 'CC BY-SA 4.0', retrieved_at: '2026-10-20T17:00:00Z', status: 'candidate', credibility: 70, corroboration: 0, rank: 0.3 }];
  const out = rank('who founded project gutenberg', semantic, keyword, 5).map(resultOf);
  assertEquals(out.length, 2);
  const byId = Object.fromEntries(out.map(r => [r.id, r]));
  assertEquals(byId['a1'].status, 'verified');
  assertEquals(byId['a1'].credibility, 92);
  assertEquals(byId['k9'].status, 'candidate');
  assertEquals(byId['k9'].match, 'keyword');
});

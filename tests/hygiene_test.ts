// deno test tests/   (citation hygiene in olo-answer)
import { assert, assertEquals } from './_assert.ts';
import { applyFigureCheck, checkLinks, COULD_NOT_VERIFY, figures, linkOk, missingFigures, shownAnswer, sourceSummary, timeSensitive } from '../functions/olo-answer/hygiene.ts';

const P = (id: string, text: string) => ({ id, source: 'wikipedia', url: `https://x/${id}`, text });

Deno.test('figures: two-digit numbers, decimals, percents and grouped thousands; single digits ignored', () => {
  assertEquals(figures('Founded in 1971 by 3 people, it grew 12.5% to 1,200,000 books.'), ['1971', '12.5', '1200000']);
  assertEquals(figures('No numbers at all'), []);
});

Deno.test('missingFigures: a figure must appear in the cited passages, not inside a longer number', () => {
  const scope = [P('p1', 'Project Gutenberg was founded in 1971. It holds over 70,000 books.')];
  assertEquals(missingFigures('It was founded in 1971 and holds 70000 books.', scope), []);
  assertEquals(missingFigures('It was founded in 1972.', scope), ['1972']);
  assertEquals(missingFigures('It was founded in 197.', scope), ['197']);
});

Deno.test('applyFigureCheck downgrades a supported sentence whose number the source lacks, and leaves others alone', () => {
  const scope = [P('p1', 'The bridge opened in 1932 and is 503 metres long.')];
  const good = applyFigureCheck({ verdict: 'supported' as const, rationale: 'stated' }, 'It opened in 1932.', scope);
  assertEquals(good.verdict, 'supported');
  assertEquals(good.figures_missing, []);
  const bad = applyFigureCheck({ verdict: 'supported' as const, rationale: 'stated' }, 'It is 530 metres long.', scope);
  assertEquals(bad.verdict, 'not_covered');
  assert(bad.rationale.includes('530'));
  const already = applyFigureCheck({ verdict: 'contradicted' as const, rationale: 'r' }, 'It is 530 metres long.', scope);
  assertEquals(already.verdict, 'contradicted');
});

Deno.test('sourceSummary counts independent publishers and finds the newest and oldest dates', () => {
  const s = sourceSummary([
    { source_slug: 'wikipedia', published_at: '2024-05-01', observed_at: '2026-10-01T00:00:00Z', credibility: 85, status: 'verified' },
    { source_slug: 'wikipedia', published_at: '2020-01-01', credibility: 60, status: 'candidate' },
    { source_slug: 'arxiv', published_at: null, credibility: 90, status: 'verified' },
  ]);
  assertEquals(s.independent_sources, 2);
  assertEquals(s.newest_published, '2024-05-01');
  assertEquals(s.oldest_published, '2020-01-01');
  assertEquals(s.verified_passages, 2);
  assertEquals(s.median_credibility, 85);
  assertEquals(s.last_observed, '2026-10-01T00:00:00Z');
});

Deno.test('timeSensitive spots questions about things that change', () => {
  assert(timeSensitive('who is the current president of France'));
  assert(timeSensitive('latest iPhone price'));
  assert(!timeSensitive('when was project gutenberg founded'));
});

Deno.test('shownAnswer keeps only supported sentences and abstains when there are none', () => {
  const a = shownAnswer([{ text: 'A.', verdict: 'supported' }, { text: 'B.', verdict: 'not_covered' }, { text: 'C.', verdict: 'supported' }]);
  assertEquals(a, { text: 'A. C.', shown: 2, hidden: 1, abstained: false });
  const b = shownAnswer([{ text: 'B.', verdict: 'contradicted' }]);
  assertEquals(b.text, COULD_NOT_VERIFY);
  assertEquals(b.abstained, true);
  assertEquals(b.hidden, 1);
});

Deno.test('linkOk: ok on 2xx and 3xx, retries HEAD refusals as GET, null on a network failure', async () => {
  const calls: string[] = [];
  const fake = (status: number, headFails = false) => (async (_u: any, init: any) => { calls.push(init.method); if (headFails && init.method === 'HEAD') return new Response(null, { status: 405 }); return new Response(null, { status }); }) as unknown as typeof fetch;
  assertEquals(await linkOk('https://a', 1000, fake(200)), true);
  assertEquals(await linkOk('https://a', 1000, fake(404)), false);
  assertEquals(await linkOk('https://a', 1000, fake(200, true)), true);
  assertEquals(calls.filter(c => c === 'GET').length, 1);
  const boom = (async () => { throw new Error('offline'); }) as unknown as typeof fetch;
  assertEquals(await linkOk('https://a', 1000, boom), null);
  const map = await checkLinks(['https://a', 'https://a', 'ftp://b', 'https://c'], 6, fake(200));
  assertEquals(Object.keys(map).sort(), ['https://a', 'https://c']);
});

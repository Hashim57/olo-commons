import { assert, assertEquals } from './_assert.ts';
import { doajCandidate, doajCandidates, doajSearchUrl, DOAJ_API, DOAJ_LICENCE } from '../functions/olo-ingest/doaj.ts';

const ABSTRACT = 'Coral reefs along the eastern coast were surveyed over ten years. Bleaching events became more frequent after 2015, and recovery was slower where water quality was poor, which suggests that local management can improve resilience.';

function rec(over: Record<string, unknown> = {}, bib: Record<string, unknown> = {}) {
  return {
    id: '0a1b2c3d4e5f60718293a4b5c6d7e8f9',
    created_date: '2026-03-01T00:00:00Z',
    bibjson: {
      title: 'Ten years of coral reef <b>bleaching</b>',
      abstract: ABSTRACT,
      author: [{ name: 'Ana Silva' }, { name: 'Tom Okafor' }, { name: '' }],
      year: '2025', month: '7',
      identifier: [{ type: 'pissn', id: '1234-5678' }, { type: 'doi', id: 'https://doi.org/10.1234/REEF.2025.07' }],
      link: [{ type: 'fulltext', url: 'https://journal.example/article/42' }],
      journal: { title: 'Marine Ecology Open', publisher: 'Open Science Press', language: ['EN'] },
      keywords: ['coral', 'bleaching'],
      ...bib,
    },
    ...over,
  };
}

Deno.test('doajCandidate maps an article with its DOI URL, date, authors and journal', () => {
  const c = doajCandidate(rec())!;
  assertEquals(c.url, 'https://doi.org/10.1234/reef.2025.07');
  assertEquals(c.doi, '10.1234/reef.2025.07');
  assertEquals(c.external_id, '0a1b2c3d4e5f60718293a4b5c6d7e8f9');
  assertEquals(c.title, 'Ten years of coral reef bleaching');
  assertEquals(c.authors, ['Ana Silva', 'Tom Okafor']);
  assertEquals(c.published_at, '2025-07-01');
  assertEquals(c.licence, DOAJ_LICENCE);
  assertEquals(c.lang, 'en');
  assert(c.content!.includes('Published in Marine Ecology Open (Open Science Press).'));
  assert(c.content!.endsWith('Keywords: coral; bleaching.'));
});

Deno.test('without a DOI the stable DOAJ article page is the URL', () => {
  const c = doajCandidate(rec({}, { identifier: [{ type: 'eissn', id: '1234-5678' }] }))!;
  assertEquals(c.url, 'https://doaj.org/article/0a1b2c3d4e5f60718293a4b5c6d7e8f9');
  assertEquals(c.doi, undefined);
});

Deno.test('short abstracts, missing titles and bad ids are skipped', () => {
  assertEquals(doajCandidate(rec({}, { abstract: 'Too short.' })), null);
  assertEquals(doajCandidate(rec({}, { abstract: undefined })), null);
  assertEquals(doajCandidate(rec({}, { title: '' })), null);
  assertEquals(doajCandidate(rec({ id: '../etc/passwd' })), null);
  assertEquals(doajCandidate(null), null);
});

Deno.test('dates and languages are only set when they are unambiguous', () => {
  assertEquals(doajCandidate(rec({}, { month: undefined }))!.published_at, '2025-01-01');
  assertEquals(doajCandidate(rec({}, { month: '13' }))!.published_at, '2025-01-01');
  assertEquals(doajCandidate(rec({}, { year: 'n.d.' }))!.published_at, undefined);
  assertEquals(doajCandidate(rec({}, { journal: { title: 'Revista', language: ['ES'] } }))!.lang, 'es');
  assertEquals(doajCandidate(rec({}, { journal: { title: 'Revista', language: ['ES', 'EN'] } }))!.lang, undefined);
});

Deno.test('doajCandidates reads the results array and stops at n', () => {
  const resp = { total: 4, page: 1, pageSize: 10, results: [rec(), rec({ id: 'ffffffffffffffffffffffffffffffff' }), rec({}, { abstract: 'x' }), rec({ id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' })] };
  assertEquals(doajCandidates(resp, 2).length, 2);
  assertEquals(doajCandidates(resp, 10).length, 3);
  assertEquals(doajCandidates({}, 5).length, 0);
});

Deno.test('the search URL encodes the query in the path and keeps page * pageSize within 1000', () => {
  assertEquals(doajSearchUrl(DOAJ_API + '/', 'climate change', 30, 4), 'https://doaj.org/api/search/articles/climate%20change?page=4&pageSize=30');
  assertEquals(doajSearchUrl(DOAJ_API, 'x', 300, 50), 'https://doaj.org/api/search/articles/x?page=10&pageSize=100');
});

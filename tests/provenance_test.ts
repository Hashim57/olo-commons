// deno test tests/   (sql/002: revisions, DOIs, the new connectors and the re-check plan)
import { assert, assertEquals } from './_assert.ts';
import { arxivCandidates, bareDoi, openalexAbstract, openalexCandidates, pubmedCandidates, searchUrl, wikiCandidate, wikidataCandidates, wikinewsCandidates, wikinewsDate } from '../functions/olo-ingest/sources.ts';
import { permalink, planRecheck } from '../functions/olo-ingest/recheck.ts';

const LONG = 'x'.repeat(260);

Deno.test('bareDoi finds a DOI in a URL or a string and lower-cases it', () => {
  assertEquals(bareDoi('https://doi.org/10.1038/S41586-024-07566-Y'), '10.1038/s41586-024-07566-y');
  assertEquals(bareDoi('doi:10.1000/abc.123.'), '10.1000/abc.123');
  assertEquals(bareDoi('no doi here'), undefined);
  assertEquals(bareDoi(null), undefined);
});

Deno.test('wikipedia and wikidata candidates carry the revision they were read from', () => {
  const w = wikiCandidate({ type: 'standard', pageid: 1, title: 'T', extract: LONG, revision: '1234567', content_urls: { desktop: { page: 'https://en.wikipedia.org/wiki/T' } } }, 'en')!;
  assertEquals(w.source_revision, '1234567');
  const d = wikidataCandidates({ entities: { Q42: { lastrevid: 99, labels: { en: { value: 'Douglas Adams' } }, descriptions: { en: { value: 'English writer' } }, sitelinks: { a: 1, b: 1, c: 1 } } } }, ['Q42'], 5);
  assertEquals(d[0].source_revision, '99');
});

Deno.test('arXiv and PubMed candidates keep DOI, PMID and version for the retraction check', () => {
  const a = arxivCandidates(`<feed><entry><id>http://arxiv.org/abs/2401.00001v2</id><title>A paper</title><summary>${LONG}</summary><arxiv:doi>10.1000/xyz123</arxiv:doi><published>2024-01-01T00:00:00Z</published></entry></feed>`)[0];
  assertEquals(a.doi, '10.1000/xyz123');
  assertEquals(a.source_revision, 'v2');
  const p = pubmedCandidates(`<PubmedArticleSet><PubmedArticle><MedlineCitation><PMID Version="1">123456</PMID><Article><ArticleTitle>Title</ArticleTitle><Abstract><AbstractText>${LONG}</AbstractText></Abstract></Article></MedlineCitation><PubmedData><ArticleIdList><ArticleId IdType="doi">10.1016/J.CELL.2020.01.001</ArticleId></ArticleIdList></PubmedData></PubmedArticle></PubmedArticleSet>`)[0];
  assertEquals(p.pmid, '123456');
  assertEquals(p.doi, '10.1016/j.cell.2020.01.001');
});

Deno.test('wikinews: the dateline is the date of the fact, and project pages are skipped', () => {
  assertEquals(wikinewsDate('Sunday, October 25, 2026 Something happened in town.'), '2026-10-25');
  assertEquals(wikinewsDate('March 3, 2019 A short one.'), '2019-03-03');
  assertEquals(wikinewsDate('No date here'), undefined);
  const r = { query: { pages: {
    '1': { pageid: 1, title: 'Floods hit the valley', extract: 'Sunday, October 25, 2026 ' + LONG, fullurl: 'https://en.wikinews.org/wiki/Floods_hit_the_valley', lastrevid: 555, touched: '2026-10-26T00:00:00Z' },
    '2': { pageid: 2, title: 'Wikinews:Water cooler', extract: LONG, fullurl: 'https://en.wikinews.org/wiki/Wikinews:Water_cooler' },
    '3': { pageid: 3, title: 'Stub', extract: 'short', fullurl: 'https://en.wikinews.org/wiki/Stub' },
  } } };
  const out = wikinewsCandidates(r, 5);
  assertEquals(out.length, 1);
  assertEquals(out[0].published_at, '2026-10-25');
  assertEquals(out[0].source_revision, '555');
  assertEquals(out[0].licence, 'CC BY 2.5');
  assert(!out[0].content!.startsWith('Sunday'), 'dateline stripped from the body');
});

Deno.test('openalex: inverted abstracts are rebuilt, retracted works dropped, DOI kept', () => {
  assertEquals(openalexAbstract({ world: [1], Hello: [0], again: [2] }), 'Hello world again');
  const works = [
    { id: 'https://openalex.org/W1', doi: 'https://doi.org/10.5555/abc', title: 'Good', abstract_inverted_index: Object.fromEntries(Array.from({ length: 40 }, (_, i) => [`word${i}`, [i]])), authorships: [{ author: { display_name: 'A. Person' } }], publication_date: '2025-02-03', primary_location: { landing_page_url: 'https://example.org/paper', source: { display_name: 'A Journal' }, license: 'cc-by' }, is_retracted: false },
    { id: 'https://openalex.org/W2', title: 'Retracted', abstract_inverted_index: { a: [0] }, is_retracted: true },
  ];
  const out = openalexCandidates(works, 5);
  assertEquals(out.length, 1);
  assertEquals(out[0].doi, '10.5555/abc');
  assertEquals(out[0].url, 'https://example.org/paper');
  assertEquals(out[0].authors, ['A. Person']);
  assert(out[0].licence!.includes('CC-BY'));
  assert(searchUrl('openalex', 'ocean warming', 3)!.includes('search=ocean%20warming'));
  assert(!searchUrl('openalex', 'ocean warming', 3)!.includes('api_key='));
  assert(searchUrl('openalex', 'ocean warming', 3, 'k e y')!.endsWith('&api_key=k%20e%20y'));
  assert(searchUrl('wikinews', 'ocean warming', 3)!.includes('gsrsearch='));
});

Deno.test('planRecheck: same revision or same text means unchanged; new text means superseded', () => {
  const old = { id: 'a', url: 'https://en.wikipedia.org/wiki/T', content_hash: 'h1', source_revision: '10' };
  assertEquals(planRecheck(old, { hash: 'h2', revision: '10' }).action, 'same');
  assertEquals(planRecheck(old, { hash: 'h1', revision: '11' }).action, 'same');
  assertEquals(planRecheck(old, { hash: 'h2', revision: '11' }).action, 'changed');
  assertEquals(planRecheck({ ...old, source_revision: null }, { hash: 'h2' }).action, 'changed');
});

Deno.test('permalink keeps history reachable and unique', () => {
  assertEquals(permalink('wikipedia', 'https://en.wikipedia.org/wiki/Project_Gutenberg', '123'), 'https://en.wikipedia.org/w/index.php?title=Project_Gutenberg&oldid=123');
  assertEquals(permalink('wikidata', 'https://www.wikidata.org/wiki/Q42', '9'), 'https://www.wikidata.org/w/index.php?title=Q42&oldid=9');
  assertEquals(permalink('arxiv', 'https://arxiv.org/abs/1', '2'), 'https://arxiv.org/abs/1#rev=2');
  assert(permalink('wikipedia', 'https://en.wikipedia.org/wiki/T', null).includes('#observed='));
});

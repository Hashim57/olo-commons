// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { archiveCandidates, arxivCandidates, gutenbergCandidates, pubmedCandidates, pubmedSearchIds, searchUrl, wikiCandidate, wikidataCandidates, wikidataSearchIds, wikiSearchTitles } from '../functions/olo-ingest/sources.ts';

const EXTRACT = 'Project Gutenberg is a volunteer effort to digitize and archive cultural works, as well as to encourage the creation and distribution of eBooks. It was founded in 1971 by American writer Michael S. Hart and is the oldest digital library.';

Deno.test('wikiCandidate maps a standard summary and rejects stubs and disambiguations', () => {
  const c = wikiCandidate({ type: 'standard', pageid: 23301, title: 'Project Gutenberg', description: 'Digital library', extract: EXTRACT, timestamp: '2026-10-01T12:00:00Z', content_urls: { desktop: { page: 'https://en.wikipedia.org/wiki/Project_Gutenberg' } } }, 'en')!;
  assertEquals(c.external_id, '23301');
  assertEquals(c.url, 'https://en.wikipedia.org/wiki/Project_Gutenberg');
  assert(c.summary!.startsWith('Digital library. Project Gutenberg'));
  assertEquals(c.published_at, '2026-10-01');
  assertEquals(c.licence, 'CC BY-SA 4.0');
  assertEquals(c.lang, 'en');
  assertEquals(wikiCandidate({ type: 'disambiguation', extract: EXTRACT }, 'en'), null);
  assertEquals(wikiCandidate({ type: 'standard', extract: 'too short' }, 'en'), null);
  assertEquals(wikiCandidate(null, 'en'), null);
  assertEquals(wikiCandidate({ type: 'standard', pageid: 1, title: 'A B', extract: EXTRACT }, 'es')!.url, 'https://es.wikipedia.org/wiki/A%20B');
});

Deno.test('wikiSearchTitles and wikidataSearchIds read search responses defensively', () => {
  assertEquals(wikiSearchTitles({ query: { search: [{ title: 'Coral reef' }, { title: '' }, {}] } }), ['Coral reef']);
  assertEquals(wikiSearchTitles(null), []);
  assertEquals(wikidataSearchIds({ search: [{ id: 'Q42' }, { id: 'P31' }, { id: 'Q1' }] }), ['Q42', 'Q1']);
  assertEquals(wikidataSearchIds({}), []);
});

Deno.test('wikidataCandidates keeps labelled, described, notable entities in id order up to n', () => {
  const e = { entities: { Q1: { labels: { en: { value: 'Universe' } }, descriptions: { en: { value: 'all of space and time' } }, sitelinks: { a: 1, b: 1, c: 1, d: 1 } }, Q2: { labels: { en: { value: 'Nameless' } }, sitelinks: {} }, Q3: { labels: { en: { value: 'Minor' } }, descriptions: { en: { value: 'x' } }, sitelinks: { a: 1 } }, Q4: { labels: { en: { value: 'Earth' } }, descriptions: { en: { value: 'third planet' } }, sitelinks: { a: 1, b: 1, c: 1 } } } };
  const out = wikidataCandidates(e, ['Q1', 'Q2', 'Q3', 'Q4'], 5);
  assertEquals(out.map(c => c.external_id), ['Q1', 'Q4']);
  assertEquals(out[0].summary, 'Universe: all of space and time.');
  assertEquals(out[0].licence, 'CC0 1.0');
  assertEquals(wikidataCandidates(e, ['Q1', 'Q4'], 1).length, 1);
});

Deno.test('archive and gutenberg mappers keep provenance and drop incomplete rows', () => {
  const a = archiveCandidates([{ identifier: 'abc', title: 'A <b>Book</b>', description: ['Part one describes the book in enough words to keep.', 'Part two adds a second paragraph of description.'], creator: 'Someone', date: '1901-02-03T00:00:00Z', licenseurl: 'https://creativecommons.org/publicdomain/zero/1.0/' }, { identifier: 'nodesc', title: 'x' }]);
  assertEquals(a.length, 1);
  assertEquals(a[0].url, 'https://archive.org/details/abc');
  assertEquals(a[0].title, 'A Book');
  assertEquals(a[0].summary, 'Part one describes the book in enough words to keep. Part two adds a second paragraph of description.');
  assertEquals(a[0].authors, ['Someone']);
  assertEquals(a[0].published_at, '1901-02-03');
  assert(a[0].licence!.startsWith('See https://creativecommons.org'));
  const g = gutenbergCandidates([{ id: 7, title: 'Tale', summaries: ['A tale of two cities.'], subjects: ['Fiction'], authors: [{ name: 'Dickens, Charles' }] }, { id: 8, title: 'Empty' }]);
  assertEquals(g.length, 1);
  assertEquals(g[0].url, 'https://www.gutenberg.org/ebooks/7');
  assertEquals(g[0].authors, ['Dickens, Charles']);
  assertEquals(g[0].licence, 'Public domain');
});

Deno.test('arxivCandidates parses entries and delatexes titles', () => {
  const xml = `<feed><entry><id>http://arxiv.org/abs/2401.00001v1</id><title>On $O(n \\log n)$ sorting</title><summary>${'An abstract long enough to pass the one hundred character minimum, describing a method for sorting things. '.repeat(2)}</summary><author><name>A. Person</name></author><published>2024-01-01T00:00:00Z</published></entry><entry><id>http://arxiv.org/abs/2401.00002v1</id><title>Short</title><summary>too short</summary></entry></feed>`;
  const out = arxivCandidates(xml);
  assertEquals(out.length, 1);
  assertEquals(out[0].external_id, '2401.00001v1');
  assertEquals(out[0].url, 'https://arxiv.org/abs/2401.00001v1');
  assertEquals(out[0].title, 'On O(n log n) sorting');
  assertEquals(out[0].authors, ['A. Person']);
  assertEquals(out[0].published_at, '2024-01-01');
  assertEquals(arxivCandidates(''), []);
});

Deno.test('pubmedCandidates parses articles with a long enough abstract and pubmedSearchIds filters ids', () => {
  const abs = 'Background: this abstract is long enough to pass the one hundred and fifty character minimum that the connector applies to PubMed records before keeping them. Results: fine.';
  const xml = `<PubmedArticleSet><PubmedArticle><MedlineCitation><PMID Version="1">123</PMID><Article><ArticleTitle>A &amp; B</ArticleTitle><Abstract><AbstractText Label="BACKGROUND">${abs}</AbstractText></Abstract><AuthorList><Author><LastName>Smith</LastName><ForeName>Ann</ForeName></Author></AuthorList></Article></MedlineCitation><PubmedData><History><PubMedPubDate><Year>2020</Year></PubMedPubDate></History></PubmedData></PubmedArticle><PubmedArticle><MedlineCitation><PMID>9</PMID><Article><ArticleTitle>No abstract</ArticleTitle></Article></MedlineCitation></PubmedArticle></PubmedArticleSet>`;
  const out = pubmedCandidates(xml);
  assertEquals(out.length, 1);
  assertEquals(out[0].external_id, '123');
  assertEquals(out[0].url, 'https://pubmed.ncbi.nlm.nih.gov/123/');
  assertEquals(out[0].title, 'A & B');
  assertEquals(out[0].authors, ['Ann Smith']);
  assertEquals(pubmedSearchIds({ esearchresult: { idlist: ['1', 'x', '22'] } }), ['1', '22']);
  assertEquals(pubmedSearchIds(null), []);
});

Deno.test('searchUrl builds one URL per searchable source and none for the rest', () => {
  assertEquals(searchUrl('wikipedia', 'coral reef', 5), 'https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=coral%20reef&srlimit=5&format=json');
  assert(searchUrl('wikipedia_es', 'arrecife coral', 3)!.startsWith('https://es.wikipedia.org/'));
  assert(searchUrl('wikidata', 'coral reef', 3)!.includes('wbsearchentities&search=coral%20reef'));
  assertEquals(searchUrl('arxiv', 'coral reef', 4), 'https://export.arxiv.org/api/query?search_query=all:coral+AND+all:reef&max_results=4');
  assert(searchUrl('pubmed', 'coral reef', 4)!.includes('term=coral+AND+reef&retmax=4'));
  assertEquals(searchUrl('gutenberg', 'coral reef', 4), null);
  assertEquals(searchUrl('wikipedia', '   ', 4), null);
});

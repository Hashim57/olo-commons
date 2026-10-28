// deno test --allow-read tests/   (every olo-ingest connector against recorded API responses; no network)
//
// The fixtures in tests/fixtures/ingest/ are real API responses, trimmed, or
// reconstructed from each API's documentation where the live API could not be
// reached; tests/fixtures/ingest/README.md says which is which.
import { assert, assertEquals } from './_assert.ts';
import { archiveCandidates, arxivCandidates, bareDoi, gutenbergCandidates, openalexAbstract, openalexCandidates, pubmedCandidates, pubmedSearchIds, searchUrl, wikiCandidate, wikidataCandidates, wikidataSearchIds, wikinewsCandidates, wikinewsDate, wikiSearchTitles } from '../functions/olo-ingest/sources.ts';
import { dataGovCandidates } from '../functions/olo-ingest/datagov.ts';

const text = (name: string) => Deno.readTextFile(new URL(`./fixtures/ingest/${name}`, import.meta.url));
const json = async (name: string) => JSON.parse(await text(name));
const noHtml = (s: string | undefined) => !/<[a-z/][^>]*>|&[a-z]+;|&#\d+;/i.test(s || '');

/* ---------- wikipedia, wikipedia_es ---------- */

Deno.test('wikipedia: a live REST summary maps to a candidate with its revision', async () => {
  const c = wikiCandidate(await json('wikipedia.summary.json'), 'en')!;
  assertEquals(c.external_id, '23301');
  assertEquals(c.url, 'https://en.wikipedia.org/wiki/Project_Gutenberg');
  assertEquals(c.title, 'Project Gutenberg');
  assert(c.summary!.startsWith('Online digital book library. Project Gutenberg (PG) is a volunteer effort'));
  assert(c.content!.includes('"encourage the creation and distribution of eBooks."'), 'quotes kept as plain text');
  assertEquals(c.published_at, '2026-10-12');
  assertEquals(c.source_revision, '1379930713');
  assertEquals(c.licence, 'CC BY-SA 4.0');
  assert(noHtml(c.summary) && noHtml(c.content));
});

Deno.test('wikipedia: a live disambiguation page is rejected', async () => {
  assertEquals(wikiCandidate(await json('wikipedia.disambiguation.json'), 'en'), null);
});

Deno.test('wikipedia: a live list=search response gives titles; snippets with HTML are ignored', async () => {
  assertEquals(wikiSearchTitles(await json('wikipedia.search.json')), ['Coral reef', 'Coral bleaching', 'Great Barrier Reef']);
});

Deno.test('wikipedia_es: a Spanish summary keeps lang es, accents and the es URL', async () => {
  const c = wikiCandidate(await json('wikipedia_es.summary.json'), 'es')!;
  assertEquals(c.lang, 'es');
  assertEquals(c.url, 'https://es.wikipedia.org/wiki/Proyecto_Gutenberg');
  assert(c.summary!.startsWith('biblioteca digital de libros electrónicos gratuitos. El Proyecto Gutenberg'));
  assert(c.content!.includes('más antigua'));
  assertEquals(c.source_revision, '170123456');
});

Deno.test('wikipedia: a summary just under 200 characters is a stub and is rejected', async () => {
  const p = await json('wikipedia.summary.json');
  assertEquals(wikiCandidate({ ...p, extract: p.extract.slice(0, 199) }, 'en'), null);
  assert(wikiCandidate({ ...p, extract: p.extract.slice(0, 200) }, 'en') !== null);
  assertEquals(wikiCandidate({ ...p, extract: undefined }, 'en'), null);
});

/* ---------- wikidata ---------- */

Deno.test('wikidata: live wbgetentities; an item named only by its "mul" label is kept (Q42)', async () => {
  const e = await json('wikidata.entities.json');
  // Recorded with the old request (languages=en): Q42 came back with no label at all, so it was dropped.
  assertEquals(e.entities.Q42.labels.en, undefined, 'the live record really has no English label');
  assertEquals(wikidataCandidates(e, ['Q42', 'Q1'], 5).map(c => c.external_id), ['Q1']);
  // index.ts now asks for languages=en|mul, which adds the language-independent label.
  e.entities.Q42.labels.mul = { language: 'mul', value: 'Douglas Adams' };
  const out = wikidataCandidates(e, ['Q42', 'Q1'], 5);
  assertEquals(out.map(c => c.external_id), ['Q42', 'Q1']);
  assertEquals(out[0].title, 'Douglas Adams');
  assertEquals(out[0].summary, 'Douglas Adams: British science fiction writer and humorist (1952-2001).');
  assertEquals(out[0].url, 'https://www.wikidata.org/wiki/Q42');
  assertEquals(out[0].source_revision, '2560674217');
  assertEquals(out[1].title, 'universe');
  assertEquals(out[1].content, 'universe. totality consisting of space, time, matter and energy. Described in 5 Wikimedia projects.');
});

Deno.test('wikidata: no description, fewer than 3 sitelinks, or a missing entity are skipped', async () => {
  const e = await json('wikidata.edge.json');
  const out = wikidataCandidates(e, ['Q11292', 'Q130000001', 'Q999999999', 'Q7343', 'Q404'], 5);
  assertEquals(out.map(c => c.external_id), ['Q7343']);
  assertEquals(out[0].title, 'Great Barrier Reef');
  assertEquals(wikidataCandidates(e, ['Q7343'], 0).length, 1, 'n is checked after a push, so at least one is returned');
});

Deno.test('wikidata: wbsearchentities ids keep items only (no lexemes or properties)', async () => {
  assertEquals(wikidataSearchIds(await json('wikidata.search.json')), ['Q11292', 'Q7343']);
});

/* ---------- archive_org ---------- */

Deno.test('archive_org: live advancedsearch docs; one-word stub descriptions are rejected', async () => {
  const r = await json('archive_org.json');
  const out = archiveCandidates(r.response.docs);
  assertEquals(out.map(c => c.external_id), ['introducingmanag0002will', 'masonsretreat00tilgrich']);
  const book = out[0];
  assertEquals(book.url, 'https://archive.org/details/introducingmanag0002will');
  assertEquals(book.title, 'Introducing management : a development guide');
  assert(book.summary!.startsWith('1 online resource (xii, 348 pages) : This book explains'), 'description array joined');
  assertEquals(book.summary!.length, 600);
  assertEquals(book.authors, ['Williams, Kate']);
  assertEquals(book.published_at, '2004-01-01');
  assertEquals(book.licence, 'Public domain / as stated by the Archive');
  assertEquals(out[1].content, "After many years in England an impoverished, upper-class American family return to an inherited estate on Chesapeake Bay. The novel describes their reaction to the new surroundings--country living versus city living, America versus Europe--and the resulting conflicts. The father returns to England, one son wants to follow, another wants to remain, and the mother is torn. By the author of In a Father's Place");
});

Deno.test('archive_org: HTML and entities cleaned, creator arrays kept, rows without identifier or title dropped', async () => {
  const r = await json('archive_org.edge.json');
  const out = archiveCandidates(r.response.docs);
  assertEquals(out.length, 1);
  const c = out[0];
  assertEquals(c.url, 'https://archive.org/details/origintheoryofli00darw');
  assert(c.summary!.startsWith("First edition, London: John Murray, 1859. Darwin's account of descent with modification & natural selection"));
  assert(noHtml(c.summary));
  assertEquals(c.authors, ['Darwin, Charles, 1809-1882', 'Murray, John, 1808-1892, publisher']);
  assertEquals(c.published_at, undefined, 'a bare year is not a date');
  assertEquals(c.licence, 'See http://creativecommons.org/publicdomain/mark/1.0/');
  assert(!out.some(x => x.url.endsWith('/undefined')));
  assertEquals(archiveCandidates(null as unknown as any[]), []);
});

/* ---------- arxiv ---------- */

Deno.test('arxiv: live Atom entries keep version, DOI, all listed authors and decoded entities', async () => {
  const out = arxivCandidates(await text('arxiv.xml'));
  assertEquals(out.map(c => c.external_id), ['1706.03762v7', '1207.7214v2']);
  const [attn, higgs] = out;
  assertEquals(attn.url, 'https://arxiv.org/abs/1706.03762v7');
  assertEquals(attn.title, 'Attention Is All You Need');
  assertEquals(attn.authors, ['Ashish Vaswani', 'Noam Shazeer', 'Niki Parmar']);
  assertEquals(attn.published_at, '2017-06-12');
  assertEquals(attn.source_revision, 'v7');
  assertEquals(attn.doi, undefined);
  assertEquals(higgs.doi, '10.1016/j.physletb.2012.08.020');
  assertEquals(higgs.source_revision, 'v2');
  assert(higgs.content!.includes('H->ZZ^(*)->llll'), '&gt; decoded');
  assert(noHtml(higgs.content));
});

Deno.test('arxiv: live LaTeX in titles and abstracts becomes readable text', async () => {
  const out = arxivCandidates(await text('arxiv.latex.xml'));
  assertEquals(out.length, 3);
  const [tail, kl, stack] = out;
  assert(tail.content!.startsWith('Let T_n be the number of triangles in the Erdős-Rényi random graph G(n,p) with n^-1/2ll pll1'), tail.content!.slice(0, 120));
  assert(tail.content!.includes('η_*=0.009217...'));
  assertEquals(kl.title, 'Kazhdan--Lusztig Polynomials for permutations with P_id,w(1)=3 and Irreducible Singular Locus');
  assert(kl.content!.includes('positions a<b<c<d'), '&lt; decoded after delatex');
  assert(!/[$\\]/.test(kl.title + kl.content), 'no dollar signs or backslashes left');
  assert(stack.content!.includes('length n + 1'));
});

Deno.test('arxiv: old-style ids, multi-line titles, stubs, missing ids and missing versions', async () => {
  const out = arxivCandidates(await text('arxiv.edge.xml'));
  assertEquals(out.map(c => c.external_id), ['hep-th/9711200v3', '2601.00077']);
  const [old, nov] = out;
  assertEquals(old.url, 'https://arxiv.org/abs/hep-th/9711200v3');
  assertEquals(old.title, 'The Large N Limit of Superconformal Field Theories and Supergravity');
  assertEquals(old.doi, '10.4310/atmp.1998.v2.n2.a1');
  assertEquals(old.source_revision, 'v3');
  assert(old.content!.startsWith('We show that the large N limit'));
  assertEquals(nov.source_revision, undefined);
  assertEquals(nov.doi, undefined);
  assertEquals(nov.title, 'A O(sqrt(n)) bound with no version suffix');
  assertEquals(nov.content, 'We prove that the error is at most 10^-3 when alpha <= 1/2, improving the previous O(n) bound; the constant is explicit and the proof is short & elementary.');
  assertEquals(nov.authors, ['B. Author', 'C. Author']);
});

/* ---------- gutenberg ---------- */

Deno.test('gutenberg: gutendex books with a summary or subjects are kept, others dropped', async () => {
  const r = await json('gutenberg.json');
  const out = gutenbergCandidates(r.results);
  assertEquals(out.map(c => c.external_id), ['84', '2701']);
  const [frank, moby] = out;
  assertEquals(frank.url, 'https://www.gutenberg.org/ebooks/84');
  assertEquals(frank.authors, ['Shelley, Mary Wollstonecraft']);
  assert(frank.summary!.includes('dead matter & then abandons it'), 'entity decoded');
  assertEquals(frank.licence, 'Public domain');
  assertEquals(frank.published_at, undefined);
  assertEquals(moby.summary, 'Moby Dick; Or, The Whale. Subjects: Adventure stories; Ahab, Captain (Fictitious character) -- Fiction; Mentally ill -- Fiction; Sea stories; Whales -- Fiction; Whaling -- Fiction');
  assert(moby.content!.endsWith('Whaling ships -- Fiction'), 'content lists every subject');
  assertEquals(gutenbergCandidates(undefined as unknown as any[]), []);
});

/* ---------- pubmed ---------- */

Deno.test('pubmed: live efetch records keep PMID, own DOI, structured abstracts and inline markup removed', async () => {
  const out = pubmedCandidates(await text('pubmed.efetch.xml'));
  assertEquals(out.map(c => c.pmid), ['31452104', '32015507', '33301246']);
  const [docking, bat, vaccine] = out;
  assertEquals(docking.url, 'https://pubmed.ncbi.nlm.nih.gov/31452104/');
  assertEquals(docking.doi, '10.1007/978-1-4939-9752-7_10');
  assertEquals(docking.authors, ['Gabriela Bitencourt-Ferreira', 'Walter Filgueira de Azevedo']);
  assertEquals(docking.published_at, '2019-01-01');
  assertEquals(bat.doi, '10.1038/s41586-020-2012-7', 'own DOI, not the bioRxiv DOI in the references');
  assert(noHtml(bat.content), 'the <sup> tags in the abstract are gone');
  assertEquals(vaccine.doi, '10.1056/nejmoa2034577', 'own DOI, not the cited NEJMoa2027906');
  assertEquals(vaccine.authors, ['Fernando P Polack', 'Stephen J Thomas', 'Nicholas Kitchin'], 'the collective author is not a person');
  assert(vaccine.content!.startsWith('Severe acute respiratory syndrome coronavirus 2'), vaccine.content!.slice(0, 80));
  assert(vaccine.content!.length > 1000, 'all four labelled sections joined');
});

Deno.test('pubmed: no own DOI means none (not a reference DOI); an author without ForeName keeps their name', async () => {
  const out = pubmedCandidates(await text('pubmed.edge.xml'));
  assertEquals(out.length, 1, 'the letter without an abstract is dropped');
  const c = out[0];
  assertEquals(c.doi, undefined);
  assertEquals(c.authors, ['Tran', 'Ada Okafor']);
  assertEquals(c.title, 'Handwashing and diarrhoeal disease in day-care centres: a cluster randomised trial.');
  assert(c.content!.includes('0.60 to 0.94; p<0.05'), c.content);
  assertEquals(c.published_at, '1998-01-01');
});

Deno.test('pubmed: live esearch JSON gives the id list', async () => {
  assertEquals(pubmedSearchIds(await json('pubmed.esearch.json')), ['42927558', '42926947', '42923753']);
});

/* ---------- wikinews ---------- */

Deno.test('wikinews: a live random page keeps the dateline as its date and drops it from the body', async () => {
  const out = wikinewsCandidates(await json('wikinews.json'), 5);
  assertEquals(out.length, 1);
  const c = out[0];
  assertEquals(c.external_id, '126663');
  assertEquals(c.url, 'https://en.wikinews.org/wiki/Malawian_president_inaugurated_after_reelection');
  assertEquals(c.published_at, '2009-05-23');
  assert(c.content!.startsWith('Bingu wa Mutharika, the president of the African country of Malawi'), c.content!.slice(0, 80));
  assertEquals(c.source_revision, '4821552');
  assertEquals(c.licence, 'CC BY 2.5');
});

Deno.test('wikinews: no dateline falls back to touched, no fullurl builds one, project pages and stubs are skipped', async () => {
  const r = await json('wikinews.edge.json');
  const out = wikinewsCandidates(r, 5);
  assertEquals(out.map(c => c.external_id), ['2001', '2004']);
  assertEquals(out[0].published_at, '2026-07-14');
  assertEquals(out[0].url, 'https://en.wikinews.org/wiki/Solar_eclipse_seen_across_the_Pacific');
  assertEquals(out[1].published_at, '2026-05-01', 'an unknown month is not a date');
  assertEquals(wikinewsCandidates(r, 1).length, 1);
  assertEquals(wikinewsCandidates({}, 5), []);
});

Deno.test('wikinewsDate: weekday optional, single-digit days padded, unknown months and late datelines ignored', () => {
  assertEquals(wikinewsDate('Saturday, May 23, 2009\n \nBingu wa Mutharika'), '2009-05-23');
  assertEquals(wikinewsDate('July 4, 1976 Celebrations'), '1976-07-04');
  assertEquals(wikinewsDate('Smarch 13, 2026 A month that does not exist.'), undefined);
  assertEquals(wikinewsDate('x'.repeat(130) + ' May 23, 2009'), undefined);
  assertEquals(wikinewsDate(''), undefined);
});

/* ---------- openalex ---------- */

Deno.test('openalex: works with abstracts kept; http landing pages fall back to the DOI; no DOI uses OpenAlex', async () => {
  const r = await json('openalex.json');
  const out = openalexCandidates(r.results, 10);
  assertEquals(out.map(c => c.external_id), ['W2741809807', 'W2100000002', 'W2100000003']);
  const [oa, http, nodoi] = out;
  assertEquals(oa.url, 'https://doi.org/10.7717/peerj.4375');
  assertEquals(oa.doi, '10.7717/peerj.4375');
  assertEquals(oa.authors, ['Heather Piwowar', 'Jason Priem'], 'an authorship with no name is dropped');
  assertEquals(oa.published_at, '2018-02-13');
  assertEquals(oa.licence, 'CC0 1.0 (metadata); abstract as published (CC-BY)');
  assert(oa.content!.startsWith('Despite growing interest in Open Access (OA) to scholarly literature,'));
  assert(oa.content!.endsWith('is OA & growing. Published in PeerJ.'));
  assertEquals(http.url, 'https://doi.org/10.1000/http.landing.42');
  assertEquals(http.title, 'A work whose landing page is plain http');
  assertEquals(http.published_at, undefined, 'a year-month date is not kept');
  assertEquals(http.licence, 'CC0 1.0 (metadata); abstract as published', 'oa_status green is not a licence');
  assertEquals(nodoi.url, 'https://openalex.org/W2100000003');
  assertEquals(nodoi.doi, undefined);
  assertEquals(openalexCandidates(r.results, 2).length, 2);
});

Deno.test('openalexAbstract: gaps and empty input', () => {
  assertEquals(openalexAbstract({ b: [2], a: [0] }), 'a b');
  assertEquals(openalexAbstract({ a: [0], c: [] }), 'a');
  assertEquals(openalexAbstract(null), '');
  assertEquals(openalexAbstract('text'), '');
});

/* ---------- data_gov ---------- */

Deno.test('data_gov: a live v4 response; the CC BY state dataset is kept, the unlicensed state dataset dropped', async () => {
  const out = dataGovCandidates(await json('data_gov.json'), 5);
  assertEquals(out.length, 1);
  const c = out[0];
  assertEquals(c.url, 'https://catalog.data.gov/dataset/drinking-water-public-water-system-annually-reported-water-production-and-delive-2013-2022');
  assertEquals(c.licence, 'CC BY');
  assertEquals(c.external_id, 'f4d572d2-252b-4019-8820-e0782f132508');
  assertEquals(c.authors, ['California State Water Resources Control Board']);
  assertEquals(c.published_at, '2024-05-23');
  assert(c.content!.includes('Keywords: Drinking Water;'));
});

/* ---------- bareDoi and searchUrl ---------- */

Deno.test('bareDoi: prefixes, trailing punctuation, upper case and non-DOIs', () => {
  assertEquals(bareDoi('https://dx.doi.org/10.1016/J.PHYSLETB.2012.08.020'), '10.1016/j.physletb.2012.08.020');
  assertEquals(bareDoi('(doi: 10.1000/xyz123);'), '10.1000/xyz123');
  assertEquals(bareDoi('10.1101/2020.02.07.937862v1'), '10.1101/2020.02.07.937862v1');
  assertEquals(bareDoi('10.12/abc'), undefined, 'registrant code needs at least four digits');
  assertEquals(bareDoi(''), undefined);
  assertEquals(bareDoi(undefined), undefined);
});

Deno.test('searchUrl: the exact URL for every searchable source', () => {
  assertEquals(searchUrl('wikipedia_es', 'arrecife coral', 3), 'https://es.wikipedia.org/w/api.php?action=query&list=search&srsearch=arrecife%20coral&srlimit=3&format=json');
  assertEquals(searchUrl('wikidata', 'coral reef', 3), 'https://www.wikidata.org/w/api.php?action=wbsearchentities&search=coral%20reef&language=en&limit=3&format=json');
  assertEquals(searchUrl('wikinews', 'coral reef', 3), 'https://en.wikinews.org/w/api.php?action=query&generator=search&gsrsearch=coral%20reef&gsrnamespace=0&gsrlimit=3&prop=extracts|info&exintro=1&explaintext=1&exlimit=3&inprop=url&format=json');
  assertEquals(searchUrl('openalex', 'coral reef', 3), 'https://api.openalex.org/works?search=coral%20reef&filter=has_abstract:true,is_retracted:false&per-page=3&select=id,doi,title,abstract_inverted_index,authorships,publication_date,primary_location,is_retracted,open_access&mailto=hello@heliusnetwork.com');
  assertEquals(searchUrl('pubmed', 'coral reef', 4), 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=coral+AND+reef&retmax=4&sort=relevance&retmode=json');
});

Deno.test('searchUrl: words are encoded and collapsed; sources without search get null', () => {
  assertEquals(searchUrl('wikipedia', '  coral   reef  ', 2), 'https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=coral%20reef&srlimit=2&format=json');
  assertEquals(searchUrl('arxiv', 'c++ & rust', 1), 'https://export.arxiv.org/api/query?search_query=all:c%2B%2B+AND+all:%26+AND+all:rust&max_results=1');
  assertEquals(searchUrl('pubmed', 'covid#19', 1), 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=covid%2319&retmax=1&sort=relevance&retmode=json');
  for (const slug of ['archive_org', 'gutenberg', 'data_gov', 'crossref_retractions', 'unknown']) assertEquals(searchUrl(slug, 'coral reef', 3), null, slug);
  assertEquals(searchUrl('openalex', '', 3), null);
});

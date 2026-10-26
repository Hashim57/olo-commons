import { assert, assertEquals } from './_assert.ts';
import { europeanaCandidate, europeanaCandidates, europeanaLicence, europeanaSearchUrl, redactKey, EUROPEANA_API } from '../functions/olo-ingest/europeana.ts';

const DESC = 'Oil on canvas showing a girl with a pearl earring, painted in Delft around 1665. The painting is one of the best known works of the Dutch Golden Age.';

function item(over: Record<string, unknown> = {}) {
  return {
    id: '/2021672/resource_document_mauritshuis_670',
    guid: 'https://www.europeana.eu/item/2021672/resource_document_mauritshuis_670?utm_source=api&utm_medium=api&utm_campaign=SECRETKEY',
    title: ['Girl with a <i>Pearl</i> Earring'],
    dcDescription: [DESC],
    dcCreator: ['Johannes Vermeer', 'http://data.europeana.eu/agent/base/146741'],
    dataProvider: ['Mauritshuis'],
    rights: ['http://creativecommons.org/publicdomain/mark/1.0/'],
    year: ['1665'],
    language: ['nl'],
    type: 'IMAGE',
    ...over,
  };
}

Deno.test('europeanaCandidate maps an open record with a key-free URL, provenance and language', () => {
  const c = europeanaCandidate(item())!;
  assertEquals(c.url, 'https://www.europeana.eu/item/2021672/resource_document_mauritshuis_670');
  assert(!c.url.includes('SECRETKEY'));
  assertEquals(c.external_id, '2021672/resource_document_mauritshuis_670');
  assertEquals(c.title, 'Girl with a Pearl Earring');
  assertEquals(c.licence, 'Public Domain Mark 1.0');
  assertEquals(c.authors, ['Johannes Vermeer']);
  assertEquals(c.published_at, '1665-01-01');
  assertEquals(c.lang, 'nl');
  assert(c.content!.endsWith('Held by Mauritshuis.'));
});

Deno.test('europeanaLicence keeps PDM, CC0, CC BY and CC BY-SA and drops everything else', () => {
  assertEquals(europeanaLicence(['https://creativecommons.org/publicdomain/zero/1.0/']), 'CC0 1.0');
  assertEquals(europeanaLicence(['http://creativecommons.org/licenses/by/4.0/']), 'CC BY 4.0');
  assertEquals(europeanaLicence(['http://www.creativecommons.org/licenses/by-sa/3.0']), 'CC BY-SA 3.0');
  assertEquals(europeanaLicence(['http://creativecommons.org/licenses/by-nc/4.0/']), null);
  assertEquals(europeanaLicence(['http://creativecommons.org/licenses/by-nd/4.0/']), null);
  assertEquals(europeanaLicence(['http://rightsstatements.org/vocab/InC/1.0/']), null);
  assertEquals(europeanaLicence(['http://rightsstatements.org/vocab/NoC-NC/1.0/']), null);
  assertEquals(europeanaLicence(undefined), null);
  assertEquals(europeanaCandidate(item({ rights: ['http://rightsstatements.org/vocab/InC/1.0/'] })), null);
});

Deno.test('untitled, short, malformed or closed records are skipped', () => {
  assertEquals(europeanaCandidate(item({ title: [] })), null);
  assertEquals(europeanaCandidate(item({ dcDescription: ['Photograph.'] })), null);
  assertEquals(europeanaCandidate(item({ dcDescription: undefined })), null);
  assertEquals(europeanaCandidate(item({ id: 'not-a-record-id' })), null);
  assertEquals(europeanaCandidate(item({ id: '/2021672/../etc' })), null);
  assertEquals(europeanaCandidate(null), null);
});

Deno.test('language-aware descriptions are used when dcDescription is missing, and duplicates are joined once', () => {
  const c = europeanaCandidate(item({ dcDescription: undefined, dcDescriptionLangAware: { en: [DESC] } }))!;
  assertEquals(c.summary, DESC);
  const d = europeanaCandidate(item({ dcDescription: [DESC, DESC] }))!;
  assertEquals(d.summary, DESC);
});

Deno.test('odd years and multi-language codes are left out', () => {
  const c = europeanaCandidate(item({ year: ['1600-1700'], language: ['mul'] }))!;
  assertEquals(c.published_at, undefined);
  assertEquals(c.lang, undefined);
  assertEquals(europeanaCandidate(item({ year: ['9999'] }))!.published_at, undefined);
});

Deno.test('europeanaCandidates reads the items array and stops at n', () => {
  const resp = { success: true, itemsCount: 4, items: [item(), item({ id: '/1/b' }), item({ rights: ['http://rightsstatements.org/vocab/InC/1.0/'] }), item({ id: '/1/c' })] };
  assertEquals(europeanaCandidates(resp, 2).length, 2);
  assertEquals(europeanaCandidates(resp, 10).length, 3);
  assertEquals(europeanaCandidates({}, 5).length, 0);
});

Deno.test('the search URL asks for open records only and stays inside the 1000-record window', () => {
  assertEquals(europeanaSearchUrl(EUROPEANA_API + '/', 'k e y', 'folk costume', 40, 5), 'https://api.europeana.eu/record/v2/search.json?wskey=k%20e%20y&query=folk%20costume&reusability=open&profile=rich&rows=40&start=5');
  assert(europeanaSearchUrl(EUROPEANA_API, 'k', 'x', 500, 990).endsWith('&rows=100&start=900'));
});

Deno.test('redactKey hides the key in an error message', () => {
  assertEquals(redactKey('401 https://api.europeana.eu/record/v2/search.json?wskey=abc123&query=x'), '401 https://api.europeana.eu/record/v2/search.json?wskey=***&query=x');
  assertEquals(redactKey('timeout'), 'timeout');
});

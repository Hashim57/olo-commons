import { assert, assertEquals } from './_assert.ts';
import { dataGovApiBase, dataGovCandidate, dataGovCandidates, dataGovLicence, dataGovSearchPlan, dataGovSearchUrl, DATAGOV_API, DATAGOV_ORG_TYPES, DATAGOV_SORTS, DATAGOV_TOPICS } from '../functions/olo-ingest/datagov.ts';

const NOTES = 'Daily measurements of dissolved oxygen, temperature and turbidity from monitoring stations along the river, collected by the agency and published for research and public use.';

function row(over: Record<string, unknown> = {}, dcat: Record<string, unknown> = {}) {
  return {
    title: 'River water quality monitoring',
    description: NOTES,
    identifier: 'usgs-wq-123',
    slug: 'river-water-quality-monitoring',
    publisher: 'U.S. Geological Survey',
    keyword: ['water', 'rivers'],
    organization: { name: 'U.S. Geological Survey', slug: 'usgs', organization_type: 'Federal Government' },
    dcat: { title: 'River water quality monitoring', description: NOTES, accessLevel: 'public', modified: '2026-09-01', issued: '2019-04-02', license: 'https://creativecommons.org/publicdomain/zero/1.0/', ...dcat },
    ...over,
  };
}

Deno.test('dataGovCandidate maps an open, public dataset with a catalogue URL and provenance', () => {
  const c = dataGovCandidate(row())!;
  assertEquals(c.url, 'https://catalog.data.gov/dataset/river-water-quality-monitoring');
  assertEquals(c.licence, 'CC0 1.0');
  assertEquals(c.external_id, 'usgs-wq-123');
  assertEquals(c.published_at, '2019-04-02');
  assert(c.summary!.startsWith('Dataset published by U.S. Geological Survey.'));
  assert(c.content!.includes('Keywords: water; rivers.'));
});

Deno.test('licence URLs match across http, https, www and a trailing slash', () => {
  assertEquals(dataGovLicence(row({}, { license: 'http://www.usa.gov/publicdomain/label/1.0/' })), 'Public domain (U.S. Government Work)');
  assertEquals(dataGovLicence(row({}, { license: 'https://creativecommons.org/licenses/by/4.0' })), 'CC BY');
  assertEquals(dataGovLicence(row({}, { license: 'http://opendatacommons.org/licenses/odbl/1.0/' })), 'ODC Open Database Licence');
  // As seen in a live v4 response from a state portal (26 October 2026).
  assertEquals(dataGovLicence(row({}, { license: 'http://www.opendefinition.org/licenses/cc-by' })), 'CC BY');
  assertEquals(dataGovLicence(row({}, { license: 'http://www.opendefinition.org/licenses/cc-by-nc' })), null);
});

Deno.test('unknown or custom licences are dropped', () => {
  assertEquals(dataGovLicence(row({}, { license: 'https://example.gov/terms-of-use' })), null);
  assertEquals(dataGovCandidate(row({}, { license: 'https://creativecommons.org/licenses/by-nc/4.0/' })), null);
});

Deno.test('no licence: federal datasets are U.S. Government Works, others are dropped', () => {
  assertEquals(dataGovLicence(row({}, { license: undefined })), 'Public domain (U.S. Government Work, 17 U.S.C. 105)');
  const state = row({ organization: { name: 'State of X', organization_type: 'State Government' } }, { license: undefined });
  assertEquals(dataGovCandidate(state), null);
});

Deno.test('non-public, short, untitled or slugless datasets are skipped', () => {
  assertEquals(dataGovCandidate(row({}, { accessLevel: 'restricted public' })), null);
  assertEquals(dataGovCandidate(row({ description: 'Too short.' }, { description: 'Too short.' })), null);
  assertEquals(dataGovCandidate(row({ title: '' }, { title: '' })), null);
  assertEquals(dataGovCandidate(row({ slug: '' })), null);
  assertEquals(dataGovCandidate(null), null);
});

Deno.test('dataGovCandidates reads the v4 results array and stops at n', () => {
  const resp = { after: 'x', sort: 'relevance', results: [row(), row({ slug: 'second-dataset' }), row({}, { license: 'https://example.gov/terms' }), row({ slug: 'third-dataset' })] };
  assertEquals(dataGovCandidates(resp, 2).length, 2);
  assertEquals(dataGovCandidates(resp, 10).length, 3);
  assertEquals(dataGovCandidates({}, 5).length, 0);
});

Deno.test('the dead CKAN base in the registry is replaced by the v4 API', () => {
  assertEquals(dataGovApiBase('https://catalog.data.gov/api/3'), DATAGOV_API);
  assertEquals(dataGovApiBase(null), DATAGOV_API);
  assertEquals(dataGovApiBase('https://api.gsa.gov/technology/datagov/v4/'), DATAGOV_API);
  assertEquals(dataGovSearchUrl(DATAGOV_API, 'water quality', 99), 'https://api.gsa.gov/technology/datagov/v4/search?q=water%20quality&per_page=50&sort=relevance');
});

Deno.test('dataGovSearchUrl takes a plan: sort and publisher type go on the query, unknown sorts fall back', () => {
  assertEquals(
    dataGovSearchUrl(DATAGOV_API, { topic: 'air quality', sort: 'last_harvested_date', orgType: 'State Government' }, 40),
    'https://api.gsa.gov/technology/datagov/v4/search?q=air%20quality&per_page=40&sort=last_harvested_date&org_type=State%20Government',
  );
  assertEquals(dataGovSearchUrl(DATAGOV_API, { topic: 'energy', sort: 'popularity' }, 40), 'https://api.gsa.gov/technology/datagov/v4/search?q=energy&per_page=40&sort=popularity');
  assertEquals(dataGovSearchUrl(DATAGOV_API, { topic: 'energy', sort: 'newest' as any }, 40), 'https://api.gsa.gov/technology/datagov/v4/search?q=energy&per_page=40&sort=relevance');
});

Deno.test('dataGovSearchPlan is driven by the injected random source and never leaves the allowed values', () => {
  // random() = 0 picks the first of everything: no publisher filter.
  assertEquals(dataGovSearchPlan(() => 0), { topic: DATAGOV_TOPICS[0], sort: 'relevance' });
  // random() just under 1 picks the last of everything.
  const last = dataGovSearchPlan(() => 0.999999);
  assertEquals(last, { topic: DATAGOV_TOPICS[DATAGOV_TOPICS.length - 1], sort: 'last_harvested_date', orgType: 'University' });
  // A deterministic walk over 500 draws stays inside the lists and uses every sort and a filter-free run.
  let seed = 7;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const sorts = new Set<string>(); let unfiltered = 0;
  for (let i = 0; i < 500; i++) {
    const p = dataGovSearchPlan(rnd);
    assert(DATAGOV_TOPICS.includes(p.topic));
    assert((DATAGOV_SORTS as ReadonlyArray<string>).includes(p.sort));
    assert(p.orgType === undefined || DATAGOV_ORG_TYPES.includes(p.orgType));
    sorts.add(p.sort); if (!p.orgType) unfiltered++;
  }
  assertEquals(sorts.size, 3);
  assert(unfiltered > 50);
});

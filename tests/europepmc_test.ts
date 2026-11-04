import { assert, assertEquals } from './_assert.ts';
import { europePmcApiBase, europePmcCandidate, europePmcCandidates, europePmcLang, europePmcLicence, europePmcSearchUrl, europePmcWalkUrl, EUROPEPMC_API } from '../functions/olo-ingest/europepmc.ts';

const ABSTRACT = '<h4>Background</h4>Regular physical activity is associated with lower all-cause mortality. <h4>Methods</h4>We pooled cohort data from 12 countries &amp; followed 400,000 adults for a median of 11 years. <h4>Results</h4>Risk fell with each additional hour of weekly activity.';

// Shaped like one `resultList.result` entry of a resultType=core JSON search
// (https://europepmc.org/RestfulWebService). Not captured live: the API host is
// unreachable from the build container.
function rec(over: Record<string, unknown> = {}) {
  return {
    id: '31234567', source: 'MED', pmid: '31234567', pmcid: 'PMC6543210', doi: '10.1371/journal.pmed.1002345',
    title: 'Physical activity and mortality: a pooled cohort study.',
    authorString: 'Smith J, Garcia M.',
    authorList: { author: [{ fullName: 'Smith J', firstName: 'Jane', lastName: 'Smith' }, { fullName: 'Garcia M', firstName: 'Maria', lastName: 'Garcia' }] },
    journalInfo: { journal: { title: 'PLoS Medicine' } },
    abstractText: ABSTRACT, language: 'eng',
    pubTypeList: { pubType: ['research-article', 'Journal Article'] },
    isOpenAccess: 'Y', inEPMC: 'Y', inPMC: 'Y', license: 'cc by',
    firstPublicationDate: '2019-06-18',
    ...over,
  };
}

Deno.test('europePmcCandidate maps a CC BY open-access paper with DOI, PMID and a stable article URL', () => {
  const c = europePmcCandidate(rec())!;
  assertEquals(c.external_id, 'PMC6543210');
  assertEquals(c.url, 'https://europepmc.org/article/MED/31234567');
  assertEquals(c.title, 'Physical activity and mortality: a pooled cohort study');
  assertEquals(c.licence, 'CC BY');
  assertEquals(c.doi, '10.1371/journal.pmed.1002345');
  assertEquals(c.pmid, '31234567');
  assertEquals(c.published_at, '2019-06-18');
  assertEquals(c.authors, ['Smith J', 'Garcia M']);
  assertEquals(c.lang, 'en');
  assert(!c.summary!.includes('<'), 'HTML left in summary');
  assert(c.summary!.includes('12 countries & followed'));
  assert(c.content!.endsWith('Published in PLoS Medicine.'));
});

Deno.test('europePmcLicence keeps CC0, CC BY and CC BY-SA only', () => {
  assertEquals(europePmcLicence('cc by'), 'CC BY');
  assertEquals(europePmcLicence('CC-BY 4.0'), 'CC BY');
  assertEquals(europePmcLicence('cc by-sa'), 'CC BY-SA');
  assertEquals(europePmcLicence('CC BY-SA 3.0'), 'CC BY-SA');
  assertEquals(europePmcLicence('cc0'), 'CC0 1.0');
  for (const bad of ['cc by-nc', 'cc by-nd', 'cc by-nc-nd', 'cc by-nc-sa', 'CC BY-NC 4.0', 'other', 'author manuscript', '', undefined]) assertEquals(europePmcLicence(bad), null, String(bad));
});

Deno.test('NC, ND, missing licences and closed papers are dropped even if the server sent them', () => {
  assertEquals(europePmcCandidate(rec({ license: 'cc by-nc-nd' })), null);
  assertEquals(europePmcCandidate(rec({ license: 'cc by-nd' })), null);
  assertEquals(europePmcCandidate(rec({ license: undefined })), null);
  assertEquals(europePmcCandidate(rec({ isOpenAccess: 'N' })), null);
});

Deno.test('preprints, retractions and retraction notices are dropped', () => {
  assertEquals(europePmcCandidate(rec({ source: 'PPR', id: 'PPR123' })), null);
  assertEquals(europePmcCandidate(rec({ pubTypeList: { pubType: ['Journal Article', 'Retracted Publication'] } })), null);
  assertEquals(europePmcCandidate(rec({ commentCorrectionList: { commentCorrection: [{ id: '1', source: 'MED', type: 'Retraction in' }] } })), null);
  assert(europePmcCandidate(rec({ commentCorrectionList: { commentCorrection: [{ id: '1', source: 'MED', type: 'Erratum in' }] } })) !== null);
});

Deno.test('no PMCID, no title, a short abstract or an unknown language are skipped', () => {
  assertEquals(europePmcCandidate(rec({ pmcid: undefined })), null);
  assertEquals(europePmcCandidate(rec({ title: '' })), null);
  assertEquals(europePmcCandidate(rec({ abstractText: 'Too short.' })), null);
  assertEquals(europePmcCandidate(rec({ language: 'xxx' })), null);
  assertEquals(europePmcCandidate(null), null);
  assertEquals(europePmcLang('spa'), 'es');
  assertEquals(europePmcLang(undefined), 'en');
});

Deno.test('a paper outside PubMed links to its PMC page; authorString is the fallback for authors', () => {
  const c = europePmcCandidate(rec({ source: 'PMC', id: 'PMC6543210', pmid: undefined, authorList: undefined, doi: 'https://doi.org/10.1000/ABC.1' }))!;
  assertEquals(c.url, 'https://europepmc.org/article/PMC/PMC6543210');
  assertEquals(c.pmid, undefined);
  assertEquals(c.authors, ['Smith J', 'Garcia M']);
  assertEquals(c.doi, '10.1000/abc.1');
});

Deno.test('europePmcCandidates reads resultList.result and stops at n', () => {
  const resp = { hitCount: 4, nextCursorMark: 'x', resultList: { result: [rec(), rec({ pmcid: 'PMC2' }), rec({ license: 'cc by-nc' }), rec({ pmcid: 'PMC3' })] } };
  assertEquals(europePmcCandidates(resp, 2).length, 2);
  assertEquals(europePmcCandidates(resp, 10).length, 3);
  assertEquals(europePmcCandidates({}, 5).length, 0);
});

Deno.test('search URLs carry the open-licence filter, core results and a safe query', () => {
  assertEquals(europePmcApiBase('ftp://x'), EUROPEPMC_API);
  const walk = decodeURIComponent(europePmcWalkUrl('', 'sleep', 2015, 500));
  assert(walk.startsWith(EUROPEPMC_API + '/search?query="sleep" AND OPEN_ACCESS:y AND (LICENSE:"cc by" OR LICENSE:"cc0" OR LICENSE:"cc by-sa") AND NOT SRC:PPR AND FIRST_PDATE:[2015-01-01 TO 2015-12-31]'), walk);
  assert(walk.endsWith('&resultType=core&format=json&pageSize=100&cursorMark=*'), walk);
  const gap = decodeURIComponent(europePmcSearchUrl('', 'vitamin "D" OR (bones)', 6));
  assert(gap.includes('query=(vitamin D bones) AND OPEN_ACCESS:y'), gap);
});

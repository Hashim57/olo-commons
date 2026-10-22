// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { ckanCandidate, ckanCandidates, ckanLicence } from '../functions/olo-ingest/ckan.ts';

const NOTES = 'Annual counts of bridges by condition rating for every state, compiled from the National Bridge Inventory. Updated each year by the Federal Highway Administration.';
const pkg = (over: Record<string, unknown> = {}) => ({
  id: '0b1c', name: 'national-bridge-condition', title: 'National Bridge <b>Condition</b>', notes: NOTES,
  license_id: 'us-pd', organization: { title: 'Department of Transportation' }, metadata_created: '2019-04-02T10:00:00',
  tags: [{ display_name: 'bridges' }, { name: 'infrastructure' }], ...over,
});
const SITE = 'https://catalog.data.gov';

Deno.test('ckanCandidate maps a public-domain package with provenance', () => {
  const c = ckanCandidate(pkg(), SITE)!;
  assertEquals(c.url, 'https://catalog.data.gov/dataset/national-bridge-condition');
  assertEquals(c.title, 'National Bridge Condition');
  assertEquals(c.licence, 'Public domain (U.S. Government Work)');
  assertEquals(c.authors, ['Department of Transportation']);
  assertEquals(c.published_at, '2019-04-02');
  assertEquals(c.external_id, '0b1c');
  assertEquals(c.lang, 'en');
  assert(c.summary!.startsWith('Dataset published by Department of Transportation. Annual counts'));
  assert(c.content!.endsWith('Keywords: bridges; infrastructure.'));
});

Deno.test('ckanCandidate drops packages that are not openly licensed', () => {
  for (const id of ['', 'notspecified', 'other-closed', 'other-nc', undefined]) assertEquals(ckanCandidate(pkg({ license_id: id }), SITE), null, String(id));
  assertEquals(ckanLicence({ license_id: 'CC-BY' }), 'CC BY 4.0');
  assertEquals(ckanLicence({ license_id: 'uk-ogl' }), 'Open Government Licence v3.0');
});

Deno.test('ckanCandidate drops thin or unsafe packages', () => {
  assertEquals(ckanCandidate(pkg({ notes: 'Short.' }), SITE), null);
  assertEquals(ckanCandidate(pkg({ title: '' }), SITE), null);
  assertEquals(ckanCandidate(pkg({ name: '../../admin' }), SITE), null);
  assertEquals(ckanCandidate(pkg(), 'http://catalog.data.gov'), null);
  assertEquals(ckanCandidate(null, SITE), null);
});

Deno.test('ckanCandidate never lets HTML through', () => {
  const c = ckanCandidate(pkg({ notes: '<script>x()</script><p>' + NOTES + '</p>' }), SITE)!;
  assertEquals(/<[^>]+>/.test(c.summary! + c.content! + c.title), false);
});

Deno.test('ckanCandidates keeps at most n and skips bad rows', () => {
  const r = { result: { results: [pkg({ license_id: 'other-closed' }), pkg({ name: 'a1' }), pkg({ name: 'a2' }), pkg({ name: 'a3' })] } };
  assertEquals(ckanCandidates(r, SITE, 2).map(c => c.url.split('/').pop()), ['a1', 'a2']);
  assertEquals(ckanCandidates({}, SITE, 5), []);
  assertEquals(ckanCandidate(pkg(), SITE + '/')!.url, 'https://catalog.data.gov/dataset/national-bridge-condition');
});

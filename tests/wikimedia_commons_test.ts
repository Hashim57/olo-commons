import { assert, assertEquals } from './_assert.ts';
import { commonsApiBase, commonsCandidate, commonsCandidates, commonsFileLicence, commonsSearchUrl, commonsTitleFromFile, commonsWalkStart, commonsWalkUrl, COMMONS_API, looksEnglish } from '../functions/olo-ingest/wikimedia_commons.ts';

// Shaped like a prop=imageinfo&iiprop=url|extmetadata response with formatversion=2
// (https://www.mediawiki.org/wiki/API:Imageinfo, https://www.mediawiki.org/wiki/Extension:CommonsMetadata).
// Reconstructed from the API documentation, not captured live: the Commons API is unreachable from the build container.
function page(over: Record<string, unknown> = {}, meta: Record<string, string> = {}) {
  const m: Record<string, { value: string }> = {};
  const base: Record<string, string> = {
    ImageDescription: '<p>The <a href="/wiki/Forth_Bridge">Forth Bridge</a> seen from the south shore at North Queensferry, with a train crossing the cantilever spans at dusk.</p>',
    ObjectName: 'Forth Bridge at dusk',
    Artist: '<a href="//commons.wikimedia.org/wiki/User:Example">Jane Example</a>',
    LicenseShortName: 'CC BY-SA 4.0',
    DateTimeOriginal: '2019-06-14 21:43:10',
    ...meta,
  };
  for (const [k, v] of Object.entries(base)) if (v !== '') m[k] = { value: v };
  return {
    pageid: 81234567,
    ns: 6,
    title: 'File:Forth Bridge at dusk 2019.jpg',
    imageinfo: [{ url: 'https://upload.wikimedia.org/wikipedia/commons/a/ab/Forth_Bridge_at_dusk_2019.jpg', descriptionurl: 'https://commons.wikimedia.org/wiki/File:Forth_Bridge_at_dusk_2019.jpg', extmetadata: m }],
    ...over,
  };
}

Deno.test('commonsCandidate keeps the caption as plain text with author, date, page URL and both licences', () => {
  const c = commonsCandidate(page())!;
  assertEquals(c.external_id, '81234567');
  assertEquals(c.url, 'https://commons.wikimedia.org/wiki/File:Forth_Bridge_at_dusk_2019.jpg');
  assertEquals(c.title, 'Forth Bridge at dusk');
  assertEquals(c.summary, 'The Forth Bridge seen from the south shore at North Queensferry, with a train crossing the cantilever spans at dusk.');
  assert(!/<|&[a-z]+;/.test(c.content!), 'no HTML in the text');
  assert(c.content!.endsWith('(By Jane Example, taken 2019-06-14, file licence CC BY-SA 4.0.)'));
  assertEquals(c.authors, ['Jane Example']);
  assertEquals(c.published_at, '2019-06-14');
  assertEquals(c.licence, 'CC BY-SA 4.0 (description); file: CC BY-SA 4.0');
  assertEquals(c.lang, 'en');
});

Deno.test('commonsFileLicence keeps CC0, public domain, CC BY and CC BY-SA and drops the rest', () => {
  assertEquals(commonsFileLicence('CC0'), 'CC0 1.0');
  assertEquals(commonsFileLicence('Public domain'), 'Public domain');
  assertEquals(commonsFileLicence('PD-old-70'), 'Public domain');
  assertEquals(commonsFileLicence('CC BY 2.0'), 'CC BY 2.0');
  assertEquals(commonsFileLicence('CC BY-SA 3.0 de'), 'CC BY-SA 3.0');
  assertEquals(commonsFileLicence('CC BY-SA 2.5'), 'CC BY-SA 2.5');
  assertEquals(commonsFileLicence('CC-BY-SA-4.0'), 'CC BY-SA 4.0');
  assertEquals(commonsFileLicence('GFDL'), null);
  assertEquals(commonsFileLicence('FAL'), null);
  assertEquals(commonsFileLicence('CC BY-NC 2.0'), null);
  assertEquals(commonsFileLicence(''), null);
});

Deno.test('files are skipped for a licence outside the four, a short or boilerplate caption, or not being a file page', () => {
  assertEquals(commonsCandidate(page({}, { LicenseShortName: 'GFDL' })), null);
  assertEquals(commonsCandidate(page({}, { ImageDescription: 'Forth Bridge.' })), null);
  assertEquals(commonsCandidate(page({}, { ImageDescription: 'Own work, uploaded from my camera on a sunny afternoon in the summer of that year.' })), null);
  assertEquals(commonsCandidate(page({}, { ImageDescription: 'DSC_0042 taken from the hotel window looking down onto the harbour and the old town.' })), null);
  assertEquals(commonsCandidate(page({ ns: 0 })), null);
  assertEquals(commonsCandidate(page({ missing: true })), null);
  assertEquals(commonsCandidate(page({ imageinfo: [] })), null);
});

Deno.test('the title falls back to the file name; an unknown author and an impossible date are left out', () => {
  const c = commonsCandidate(page({}, { ObjectName: '', Artist: 'Unknown author', DateTimeOriginal: '0000:00:00' }))!;
  assertEquals(c.title, 'Forth Bridge at dusk 2019');
  assertEquals(c.authors, undefined);
  assertEquals(c.published_at, undefined);
  assertEquals(commonsTitleFromFile('File:Some_old_map.of_Edinburgh.png'), 'Some old map.of Edinburgh');
});

Deno.test('commonsCandidates reads pages as an array or an object, keeps English captions only, and at most n', () => {
  const fr = page({ pageid: 2, title: 'File:Pont.jpg' }, { ImageDescription: 'Le pont du Forth vu depuis la rive sud, avec un train qui traverse les travées au crépuscule.' });
  const a = page({ pageid: 1 });
  const b = page({ pageid: 3, title: 'File:B.jpg' });
  assertEquals(commonsCandidates({ query: { pages: [fr, a, b] } }, 5).map(c => c.external_id), ['1', '3']);
  assertEquals(commonsCandidates({ query: { pages: { '1': a, '3': b } } }, 1).length, 1);
  assertEquals(commonsCandidates({}, 5), []);
  assertEquals(commonsCandidates({ error: { code: 'maxlag' } }, 5), []);
  assert(looksEnglish('A view of the harbour from the castle'));
  assert(!looksEnglish('Vista del puerto desde el castillo'));
});

Deno.test('URLs: the walk reads Quality images from a random moment, search is limited to files, and the host is pinned', () => {
  const w = new URL(commonsWalkUrl('', new Date(Date.UTC(2015, 3, 2, 10, 0, 0, 123)), 200));
  assertEquals(w.origin + w.pathname, COMMONS_API);
  assertEquals(w.searchParams.get('generator'), 'categorymembers');
  assertEquals(w.searchParams.get('gcmtitle'), 'Category:Quality_images');
  assertEquals(w.searchParams.get('gcmtype'), 'file');
  assertEquals(w.searchParams.get('gcmstart'), '2015-04-02T10:00:00Z');
  assertEquals(w.searchParams.get('gcmlimit'), '50');
  assertEquals(w.searchParams.get('iiextmetadatafilter'), 'ImageDescription|ObjectName|Artist|LicenseShortName|DateTimeOriginal');
  const s = new URL(commonsSearchUrl('', '  Forth <b>Bridge</b> ', 8));
  assertEquals(s.searchParams.get('gsrnamespace'), '6');
  assertEquals(s.searchParams.get('gsrsearch'), 'Forth Bridge');
  assertEquals(commonsApiBase('https://evil.example.com/steal'), COMMONS_API);
  assertEquals(commonsApiBase('https://commons.wikimedia.org/w/api.php'), COMMONS_API);
  const start = commonsWalkStart(() => 0, Date.UTC(2026, 10, 4)).toISOString();
  assertEquals(start, '2008-01-01T00:00:00.000Z');
  assert(commonsWalkStart(() => 0.999999, Date.UTC(2026, 10, 4)).getTime() <= Date.UTC(2026, 10, 4) - 30 * 86400_000);
});

import { assertEquals } from './_assert.ts';
import { normaliseLicenceUrl, openLicence } from '../functions/olo-ingest/licence.ts';

Deno.test('openLicence names the open licences in every spelling the sources use', () => {
  assertEquals(openLicence('https://creativecommons.org/publicdomain/mark/1.0/'), 'Public Domain Mark 1.0');
  assertEquals(openLicence('http://creativecommons.org/publicdomain/zero/1.0/'), 'CC0 1.0');
  assertEquals(openLicence('http://creativecommons.org/licenses/publicdomain/'), 'Public domain (CC Public Domain Dedication)');
  assertEquals(openLicence('https://creativecommons.org/licenses/by/4.0/'), 'CC BY 4.0');
  assertEquals(openLicence('https://creativecommons.org/licenses/by/4.0'), 'CC BY 4.0', 'no trailing slash');
  assertEquals(openLicence('http://www.creativecommons.org/licenses/by-sa/3.0/'), 'CC BY-SA 3.0');
  assertEquals(openLicence('http://creativecommons.org/licenses/by/3.0/de/'), 'CC BY 3.0', 'a ported licence is the same licence');
  assertEquals(openLicence(['http://creativecommons.org/licenses/by-sa/4.0/']), 'CC BY-SA 4.0', 'a list is read by its first entry');
  assertEquals(openLicence('  HTTPS://CreativeCommons.org/licenses/by/2.5/  '), 'CC BY 2.5');
});

Deno.test('openLicence refuses what may not be passed on: NC, ND, rights statements, unknown URLs, nothing', () => {
  for (const u of [
    'http://creativecommons.org/licenses/by-nc/4.0/',
    'https://creativecommons.org/licenses/by-nc-sa/3.0/',
    'http://creativecommons.org/licenses/by-nd/4.0/',
    'https://creativecommons.org/licenses/by-nc-nd/4.0/',
    'http://rightsstatements.org/vocab/InC/1.0/',
    'http://rightsstatements.org/vocab/NoC-NC/1.0/',
    'https://archive.org/about/terms.php',
    'https://example.com/creativecommons.org/licenses/by/4.0/',
    'creativecommons.org/licenses/by/',
    '',
    '   ',
  ]) assertEquals(openLicence(u), null, u);
  assertEquals(openLicence(undefined), null);
  assertEquals(openLicence(null), null);
  assertEquals(openLicence(42), null);
  assertEquals(openLicence([]), null);
  assertEquals(openLicence([undefined, 'http://creativecommons.org/licenses/by/4.0/']), null, 'only the first entry counts');
});

Deno.test('normaliseLicenceUrl drops the scheme, www. and trailing slashes and lower-cases', () => {
  assertEquals(normaliseLicenceUrl('HTTPS://www.CreativeCommons.org/licenses/BY/4.0//'), 'creativecommons.org/licenses/by/4.0');
  assertEquals(normaliseLicenceUrl('creativecommons.org/licenses/by/4.0'), 'creativecommons.org/licenses/by/4.0');
});

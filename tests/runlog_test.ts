// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { collect, errorNote, errorText } from '../functions/olo-ingest/runlog.ts';

Deno.test('errorText flattens an Error to one bounded line', () => {
  assertEquals(errorText(new Error('403 https://catalog.data.gov/api/3/action/package_search?rows=9')), '403 https://catalog.data.gov/api/3/action/package_search?rows=9');
  assertEquals(errorText('a\nmulti   line\n  message'), 'a multi line message');
  assertEquals(errorText(undefined), 'unknown error');
  assertEquals(errorText({ code: 'ECONN' }), '{"code":"ECONN"}');
  const long = errorText(new Error('x'.repeat(500)));
  assert(long.length <= 90, `kept ${long.length} characters`);
});

Deno.test('collect keeps the first message per source and counts the rest', () => {
  const items = collect([
    { slug: 'data_gov', message: '403 first' }, { slug: 'data_gov', message: '403 second' }, { slug: 'data_gov', message: 'timeout' },
    { slug: 'pubmed', message: 'TimeoutError: signal timed out' },
  ]);
  assertEquals(items, [{ slug: 'data_gov', message: '403 first', count: 3 }, { slug: 'pubmed', message: 'TimeoutError: signal timed out', count: 1 }]);
});

Deno.test('errorNote is empty when nothing failed and names each source once otherwise', () => {
  assertEquals(errorNote([]), '');
  const note = errorNote([{ slug: 'data_gov', message: '403 https://catalog.data.gov/api/3/action/package_search' }, { slug: 'data_gov', message: '403 again' }, { slug: 'arxiv', message: 'TimeoutError' }]);
  assertEquals(note, ' errors: data_gov: 403 https://catalog.data.gov/api/3/action/package_search (x2); arxiv: TimeoutError');
});

Deno.test('errorNote stays bounded when many sources fail', () => {
  const many = Array.from({ length: 40 }, (_, i) => ({ slug: `source_${i}`, message: 'm'.repeat(80) }));
  const note = errorNote(many);
  assert(note.length <= 520, `note is ${note.length} characters`);
  assert(/; and \d+ more sources$/.test(note), note.slice(-40));
});

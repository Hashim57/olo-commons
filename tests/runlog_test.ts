// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { collect, composeNote, errorNote, errorText, redactSecrets } from '../functions/olo-ingest/runlog.ts';

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

Deno.test('credentials in a failing URL never reach the run note', () => {
  assertEquals(redactSecrets('429 https://api.openalex.org/works?search=x&api_key=SECRET123&mailto=a@b.c'), '429 https://api.openalex.org/works?search=x&api_key=***&mailto=a@b.c');
  assertEquals(redactSecrets('401 https://api.europeana.eu/record/v2/search.json?wskey=abc&query=x'), '401 https://api.europeana.eu/record/v2/search.json?wskey=***&query=x');
  assertEquals(redactSecrets('500 https://x.org/a?token=t1 and https://y.org/b?q=1&key=k2'), '500 https://x.org/a?token=*** and https://y.org/b?q=1&key=***');
  assertEquals(redactSecrets('400 https://x.org/a?monkey=1&keyword=2'), '400 https://x.org/a?monkey=1&keyword=2');
  assert(!errorText(new Error('429 https://api.openalex.org/works?api_key=SECRET123')).includes('SECRET123'));
  assert(!errorNote([{ slug: 'openalex', message: '429 https://api.openalex.org/works?api_key=SECRET123' }]).includes('SECRET123'));
});

Deno.test('composeNote builds the run note from its parts, in the order the page has always shown them', () => {
  assertEquals(composeNote({ source: 'cron', errors: [] }), 'cron');
  assertEquals(composeNote({ source: '', errors: [] }), 'manual');
  const note = composeNote({
    source: 'cron', gap: ' (gap "solar": 1 added of 3 found)', recheck: ' (wikipedia re-check: 3 unchanged, 0 updated)',
    sightings: 2, stubs: 1, withEmail: 1, courtRecords: 3, cutShort: true, errors: [{ slug: 'arxiv', message: 'TimeoutError: signal timed out' }],
  });
  assertEquals(note, 'cron (gap "solar": 1 added of 3 found) (wikipedia re-check: 3 unchanged, 0 updated) (2 duplicates recorded as sightings) (1 stubs skipped) (1 with an email address skipped) (3 court records skipped) (time budget reached, continues next run) errors: arxiv: TimeoutError: signal timed out');
});

Deno.test('composeNote leaves out every clause that is zero or empty, so a checkpoint early in the run reads cleanly', () => {
  assertEquals(composeNote({ source: 'cron', gap: '', recheck: '', sightings: 0, stubs: 0, withEmail: 0, courtRecords: 0, cutShort: false, errors: [] }), 'cron');
  assertEquals(composeNote({ source: 'cron', errors: [{ slug: 'gutenberg', message: 'TimeoutError' }] }), 'cron errors: gutenberg: TimeoutError');
});

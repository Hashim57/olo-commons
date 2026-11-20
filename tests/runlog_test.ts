// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { collect, composeNote, errorNote, errorText, failedInNote, redactSecrets, restingInNote, restingNote, restingSources } from '../functions/olo-ingest/runlog.ts';

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

Deno.test('failedInNote reads the random-walk failures and ignores gap searches and message text', () => {
  const slugs = ['arxiv', 'gutenberg', 'data_gov', 'pubmed'];
  const note = 'cron (wikipedia re-check: 2 unchanged, 0 updated) errors: arxiv (gap search): 429; gutenberg: Signal timed out.; data_gov: data.gov v4 429 (see pubmed: docs)';
  assertEquals(Array.from(failedInNote(note, slugs)).sort(), ['data_gov', 'gutenberg']);
  assertEquals(failedInNote('cron (1 stubs skipped)', slugs).size, 0);
  assertEquals(failedInNote(null, slugs).size, 0);
  assertEquals(Array.from(failedInNote('manual errors: arxiv: Signal timed out.', slugs)), ['arxiv']);
});

Deno.test('restingSources rests a source that failed the last four runs, and probes it once an hour', () => {
  const slugs = ['arxiv', 'gutenberg', 'data_gov'];
  const notes = [
    'cron errors: arxiv: Signal timed out.; gutenberg: Signal timed out.',
    'cron errors: gutenberg: Signal timed out.',
    'cron errors: data_gov: 429; gutenberg: Signal timed out.',
    'cron errors: arxiv: 429; gutenberg: Signal timed out.',
    'cron',
  ];
  assertEquals(Array.from(restingSources(notes, slugs, new Date('2026-11-19T07:33:00Z'))), ['gutenberg']);
  // The run in the first quarter of the hour asks every source, so a recovered source is back within the hour.
  assertEquals(restingSources(notes, slugs, new Date('2026-11-19T08:03:00Z')).size, 0);
  // One good run in the last four ends the rest.
  assertEquals(restingSources(['cron', ...notes], slugs, new Date('2026-11-19T07:48:00Z')).size, 0);
  // Too little history: nobody rests.
  assertEquals(restingSources(notes.slice(0, 3), slugs, new Date('2026-11-19T07:33:00Z')).size, 0);
});

Deno.test('the resting clause goes into the run note', () => {
  assertEquals(restingNote(new Set(['gutenberg', 'arxiv'])), ' (resting after 4 failed runs: arxiv, gutenberg)');
  assertEquals(restingNote([]), '');
  assertEquals(composeNote({ source: 'cron', resting: restingNote(['gutenberg']), errors: [] }), 'cron (resting after 4 failed runs: gutenberg)');
});

Deno.test('restingInNote reads the resting clause back', () => {
  const slugs = ['arxiv', 'gutenberg', 'openalex'];
  assertEquals(Array.from(restingInNote('cron (1 stubs skipped) (resting after 4 failed runs: gutenberg, openalex) errors: arxiv: 429', slugs)).sort(), ['gutenberg', 'openalex']);
  assertEquals(restingInNote('cron errors: openalex: 429', slugs).size, 0);
  assertEquals(restingInNote(null, slugs).size, 0);
});

Deno.test('a resting run neither ends nor counts in the streak, so a dead source stays rested between probes', () => {
  const slugs = ['openalex', 'arxiv'];
  // The pattern of 20 November 2026, newest first: the hourly probe at 11:03 failed again after a rest at 10:48.
  const notes = [
    'cron errors: openalex: 429',
    'cron (resting after 4 failed runs: openalex)',
    'cron errors: openalex: 429',
    'cron errors: openalex: 429; arxiv: Signal timed out.',
  ];
  assertEquals(Array.from(restingSources(notes, slugs, new Date('2026-11-20T11:18:00Z'))), ['openalex']);
  // Still resting in the run after a rest.
  assertEquals(Array.from(restingSources(['cron (resting after 4 failed runs: openalex)', ...notes], slugs, new Date('2026-11-20T11:33:00Z'))), ['openalex']);
  // The probe answered: the rest ends.
  assertEquals(restingSources(['cron', ...notes], slugs, new Date('2026-11-20T12:18:00Z')).size, 0);
  // The probe still runs in the first quarter of the hour.
  assertEquals(restingSources(notes, slugs, new Date('2026-11-20T12:03:00Z')).size, 0);
  // Three failures and no rest is not yet a streak.
  assertEquals(restingSources(notes.slice(0, 1).concat(notes.slice(2)), slugs, new Date('2026-11-20T11:18:00Z')).size, 0);
});

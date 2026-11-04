// deno test tests/
// The keyless export cursor (functions/olo-query/export.ts): a Postgres timestamp
// keeps its microseconds on the way back into olo_export(), so a page never
// starts with the atom the previous page ended on.
import { assert, assertEquals } from './_assert.ts';
import { exportAfter, exportLimit } from '../functions/olo-query/export.ts';

Deno.test('a next_after with microseconds is passed through unchanged', () => {
  const t = '2026-10-26T10:00:00.123456+00:00';
  assertEquals(exportAfter(t), t);
  // the old code rounded it down, which re-matched the row it named
  assert(new Date(t).toISOString() !== t);
  assertEquals(new Date(t).toISOString(), '2026-10-26T10:00:00.123Z');
});

Deno.test('the other spellings Postgres uses are passed through too', () => {
  for (const t of ['2026-10-26 10:00:00.123456+00', '2026-10-26T10:00:00Z', '2026-10-26T10:00:00.5+01:00', '2026-10-26', '1970-01-01T00:00:00.000Z']) {
    assertEquals(exportAfter(t), t, t);
  }
});

Deno.test('a readable but unusual date is normalised through Date', () => {
  assertEquals(exportAfter('26 Oct 2026 10:00:00 GMT'), '2026-10-26T10:00:00.000Z');
});

Deno.test('an absent cursor starts at the epoch and an unreadable one is refused', () => {
  assertEquals(exportAfter(null), '1970-01-01T00:00:00.000Z');
  assertEquals(exportAfter(''), '1970-01-01T00:00:00.000Z');
  assertEquals(exportAfter('   '), '1970-01-01T00:00:00.000Z');
  assertEquals(exportAfter('yesterday'), null);
  assertEquals(exportAfter("2026-10-26'; drop table olo_atoms; --"), null);
});

Deno.test('the page size stays within 1 and 500', () => {
  assertEquals(exportLimit(null), 500);
  assertEquals(exportLimit('abc'), 500);
  assertEquals(exportLimit('0'), 500);
  assertEquals(exportLimit('-5'), 1);
  assertEquals(exportLimit('250'), 250);
  assertEquals(exportLimit('250.9'), 250);
  assertEquals(exportLimit('5000'), 500);
});

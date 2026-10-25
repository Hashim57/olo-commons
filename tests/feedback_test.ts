// deno test tests/   (olo-feedback validation)
import { assert, assertEquals } from './_assert.ts';
import { isInformative, parseFeedback } from '../functions/olo-feedback/feedback.ts';

const good = { client: 'ios', answer_source: 'olo', claim: '  The bridge   opened in 1932. ', verdict_given: 'supported', verdict_user: 'not_covered', passages: [{ atom: '78E2BE27-FED2-467A-BF47-DEBF10C93B49', url: 'https://en.wikipedia.org/wiki/X', quote: 'opened in 1934' }, { url: 'javascript:alert(1)' }, { quote: 'no id' }], note: 'the page says 1934' };

Deno.test('parseFeedback accepts a well-formed flag and normalises it', () => {
  const r = parseFeedback(good);
  assert(r.ok);
  if (!r.ok) return;
  assertEquals(r.value.claim, 'The bridge opened in 1932.');
  assertEquals(r.value.passages, [{ atom: '78e2be27-fed2-467a-bf47-debf10c93b49', url: 'https://en.wikipedia.org/wiki/X', quote: 'opened in 1934' }]);
  assertEquals(r.value.evidence_quote, null);
  assertEquals(r.value.note, 'the page says 1934');
});

Deno.test('parseFeedback refuses bad clients, verdicts and empty claims', () => {
  assertEquals(parseFeedback(null).ok, false);
  assertEquals(parseFeedback({ ...good, client: 'bot' }).ok, false);
  assertEquals(parseFeedback({ ...good, verdict_given: 'maybe' }).ok, false);
  assertEquals(parseFeedback({ ...good, verdict_user: 'yes' }).ok, false);
  assertEquals(parseFeedback({ ...good, claim: 'a' }).ok, false);
  const long = parseFeedback({ ...good, claim: 'x'.repeat(2000), note: 'y'.repeat(2000) });
  assert(long.ok && long.value.claim.length === 600 && long.value.note!.length === 500);
});

Deno.test('a flag that agrees and says nothing more is not informative', () => {
  const r = parseFeedback({ ...good, verdict_user: 'supported', note: '' });
  assert(r.ok && !isInformative(r.value));
  const r2 = parseFeedback({ ...good, verdict_user: 'supported', note: 'but the quote is cut' });
  assert(r2.ok && isInformative(r2.value));
});

// deno test tests/   (the re-check of a page that is gone, moved or no longer an article; functions/olo-ingest/recheck.ts)
import { assert, assertEquals } from './_assert.ts';
import { isNotFound, retireUpdate, wikidataEntityState, wikiPageState, wikiPageStateUrl, wikiSummaryUrl } from '../functions/olo-ingest/recheck.ts';

Deno.test('isNotFound recognises only the 404 that get() throws', () => {
  assert(isNotFound(new Error('404 https://en.wikipedia.org/api/rest_v1/page/summary/A_deleted_article')));
  assert(!isNotFound(new Error('429 https://api.openalex.org/works')));
  assert(!isNotFound(new Error('Signal timed out.')));
  assert(!isNotFound('something else entirely'));
});

Deno.test('the summary and action API urls carry the title the way each endpoint wants it', () => {
  assertEquals(wikiSummaryUrl('en', 'A deleted article'), 'https://en.wikipedia.org/api/rest_v1/page/summary/A_deleted_article');
  assertEquals(wikiSummaryUrl('es', 'Río de la Plata'), `https://es.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent('Río_de_la_Plata')}`);
  const u = wikiPageStateUrl('en', 'A deleted article');
  assert(u.startsWith('https://en.wikipedia.org/w/api.php?action=query&titles=A%20deleted%20article'), u);
  assert(u.includes('redirects=1') && u.includes('formatversion=2'), 'redirects are followed and the array format asked for');
});

Deno.test('a deleted page is gone in both API format versions', () => {
  assertEquals(wikiPageState({ batchcomplete: true, query: { pages: [{ ns: 0, title: 'A deleted article', missing: true }] } }), { state: 'gone' });
  assertEquals(wikiPageState({ batchcomplete: '', query: { pages: { '-1': { ns: 0, title: 'A deleted article', missing: '' } } } }), { state: 'gone' });
  assertEquals(wikiPageState({ query: { pages: [{ title: 'Foo|bar', invalid: true, invalidreason: 'The requested page title contains invalid characters' }] } }), { state: 'gone' });
});

Deno.test('a moved page is reported at its new title, an answer without pages is unknown', () => {
  const r = { query: { redirects: [{ from: 'Old name', to: 'New name' }], pages: [{ pageid: 42, ns: 0, title: 'New name' }] } };
  assertEquals(wikiPageState(r), { state: 'at', title: 'New name' });
  assertEquals(wikiPageState({ query: { pages: [{ pageid: 7, ns: 0, title: 'Same name' }] } }), { state: 'at', title: 'Same name' });
  assertEquals(wikiPageState({ query: {} }), { state: 'unknown' });
  assertEquals(wikiPageState(null), { state: 'unknown' });
  assertEquals(wikiPageState({ error: { code: 'maxlag' } }), { state: 'unknown' });
});

Deno.test('a Wikidata item that was deleted or merged away is gone; a present one carries its revision', () => {
  assertEquals(wikidataEntityState({ entities: { Q99999999: { id: 'Q99999999', missing: '' } } }, 'Q99999999'), { state: 'gone' });
  assertEquals(wikidataEntityState({ entities: {} }, 'Q42'), { state: 'gone' });
  assertEquals(wikidataEntityState({ entities: { Q42: { id: 'Q42', lastrevid: 2345, labels: {}, descriptions: {} } } }, 'Q42'), { state: 'at', revision: '2345' });
  assertEquals(wikidataEntityState({ entities: { Q42: { id: 'Q42' } } }, 'Q42'), { state: 'at', revision: undefined });
});

Deno.test('retiring an atom supersedes it with no successor, under the permalink of the revision it was read from', () => {
  const today = new Date('2026-11-12T10:30:00Z');
  const wp = retireUpdate('wikipedia', { id: 'a', url: 'https://en.wikipedia.org/wiki/A_deleted_article', content_hash: 'h', source_revision: '1318000000' }, today);
  assertEquals(wp, { status: 'superseded', valid_to: '2026-11-12', url: 'https://en.wikipedia.org/w/index.php?title=A_deleted_article&oldid=1318000000' });
  const wd = retireUpdate('wikidata', { id: 'b', url: 'https://www.wikidata.org/wiki/Q42', content_hash: 'h', source_revision: '99' }, today);
  assertEquals(wd.url, 'https://www.wikidata.org/w/index.php?title=Q42&oldid=99');
  // no revision stored: the url still changes, so the live address is free for the page if it comes back
  const none = retireUpdate('wikipedia', { id: 'c', url: 'https://en.wikipedia.org/wiki/Gone', content_hash: 'h', source_revision: null }, today);
  assertEquals(none.status, 'superseded');
  assert(none.url.startsWith('https://en.wikipedia.org/wiki/Gone#observed='), none.url);
});

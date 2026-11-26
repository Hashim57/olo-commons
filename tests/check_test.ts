// deno test --allow-read tests/
import { assert, assertEquals } from './_assert.ts';
import { CHECK_MAX_PASSAGE_CHARS, CHECK_MAX_PASSAGES, CHECK_MAX_SENTENCES, CHECK_MAX_TEXT, CHUNK_CHARS, checkSentences, checkSummary, chunkSupplied, parseCheckRequest, scopeFor } from '../functions/olo-answer/check.ts';
import { buildReceipt, canonicalJson, receiptIntact, sealReceipt, sha256Hex } from '../functions/olo-answer/receipt.ts';
import { quoteKey } from '../functions/olo-answer/answer.ts';

const COMAIR = "A Comair commuter jet crashed on takeoff from Lexington, Kentucky yesterday, killing 49 people on board and seriously injuring the plane's first officer, James M. Polehinke. The early-morning Flight 5191 was operating as Delta Connection and was headed from Lexington's Blue Grass Airport to Atlanta's Hartsfield-Jackson International Airport. It crashed about a mile west of the airport at 6:07 a.m. Eastern Time.";

Deno.test('check: a request needs text, takes up to eight passages of real text, and says why when it cannot', () => {
  assertEquals(parseCheckRequest({ mode: 'check', text: '  The   jet crashed.  ' }), { text: 'The jet crashed.', supplied: null });
  assert('error' in parseCheckRequest({ mode: 'check' }), 'no text');
  assert('error' in parseCheckRequest({ mode: 'check', text: 'x'.repeat(CHECK_MAX_TEXT + 1) }), 'too long');
  assert('error' in parseCheckRequest({ mode: 'check', text: 'The jet crashed.', passages: [] }), 'an empty list is a mistake, not the Commons');
  assert('error' in parseCheckRequest({ mode: 'check', text: 'The jet crashed.', passages: 'no' }));
  assert('error' in parseCheckRequest({ mode: 'check', text: 'The jet crashed.', passages: Array(CHECK_MAX_PASSAGES + 1).fill({ text: COMAIR }) }));
  assert('error' in parseCheckRequest({ mode: 'check', text: 'The jet crashed.', passages: [{ text: 'short' }] }));
  assert('error' in parseCheckRequest({ mode: 'check', text: 'The jet crashed.', passages: [{ text: 'a'.repeat(CHECK_MAX_PASSAGE_CHARS + 1) }] }), 'a long passage is refused, never cut without saying so');
  const r = parseCheckRequest({ mode: 'check', text: 'The jet crashed.', passages: [{ text: COMAIR, url: 'https://en.wikinews.org/wiki/x', title: ' Comair ' }, COMAIR, { text: COMAIR, url: 'javascript:alert(1)' }] });
  assert(!('error' in r));
  if (!('error' in r)) {
    assertEquals(r.supplied!.map(p => [p.url ?? null, p.title ?? null]), [['https://en.wikinews.org/wiki/x', 'Comair'], [null, null], [null, null]], 'a plain string is a passage; a URL that is not http(s) is dropped');
  }
});

Deno.test('check: sentences are split as answers are, and the ones past the limit are counted, not dropped silently', () => {
  const text = 'Comair Flight 5191 crashed on takeoff from Lexington. It killed 49 people. The plane was a Canadair CRJ-100. George A. Romero was not aboard. The crash was at 6:07 a.m. Eastern Time. Officials spoke on Monday. A seventh sentence follows here.';
  const anon = checkSentences(text, false);
  assertEquals(anon.checked.length, CHECK_MAX_SENTENCES.anon);
  assertEquals(anon.unchecked, 1);
  assert(anon.checked.includes('George A. Romero was not aboard.'), 'initials do not split a sentence');
  assertEquals(checkSentences(text, true).unchecked, 0);
  assertEquals(checkSentences('The jet crashed [p1].', false).checked, ['The jet crashed.'], 'citations an AI left in are not part of the claim');
});

Deno.test('check: a long supplied passage is cut into verbatim chunks at sentence ends, and a short one keeps its own id', () => {
  const long = Array.from({ length: 12 }, (_, i) => `Sentence number ${i + 1} of the contract states a separate obligation for the supplier in plain words.`).join(' ');
  const chunks = chunkSupplied([{ text: COMAIR, title: 'Comair' }, { text: long }]);
  assertEquals(chunks[0].id, 's1');
  assertEquals(chunks[0].text, COMAIR);
  const second = chunks.filter(c => c.passage === 2);
  assert(second.length >= 2, 'the long passage is cut');
  assertEquals(second.map(c => c.id), second.map((_, j) => `s2.${j + 1}`));
  assert(second.every(c => c.text.length <= CHUNK_CHARS), 'no chunk is longer than the verifier reads');
  assert(second.every(c => /\.$/.test(c.text)), 'cut at sentence ends');
  assertEquals(second.map(c => c.text).join(' '), long, 'nothing is lost or reworded');
  assert(second.every(c => quoteKey(long).includes(quoteKey(c.text))), 'a quote found in a chunk is in the passage');
});

Deno.test('check: each sentence is checked against the chunks that share most of its words, never against none', () => {
  const chunks = chunkSupplied([{ text: 'The supplier delivers the goods within thirty days of the order.' + ' Filler words about nothing in particular here.'.repeat(1) }, { text: COMAIR }, { text: 'The buyer pays the invoice within sixty days of delivery, in euros.' }]);
  assertEquals(scopeFor('The Comair jet crashed at Lexington.', chunks, 1).map(c => c.id), ['s2']);
  assertEquals(scopeFor('The buyer pays within sixty days.', chunks, 2).map(c => c.id), ['s1', 's3'], 'kept in document order');
  assertEquals(scopeFor('Zebras graze quietly.', chunks, 2).map(c => c.id), ['s1', 's2'], 'no overlap still gives the verifier something to say not covered against');
});

Deno.test('check: the summary counts each verdict and the sentences left unchecked', () => {
  assertEquals(checkSummary([{ verdict: 'supported' }, { verdict: 'contradicted' }, { verdict: 'supported' }], 2), { supported: 2, contradicted: 1, not_covered: 0, unchecked: 2 });
});

Deno.test('check: a receipt over supplied passages keeps their SHA-256, never their text, and still seals', async () => {
  const sha = await sha256Hex(COMAIR);
  const r = await sealReceipt(buildReceipt({
    question: 'The flight was headed from Atlanta to Lexington.', answerShown: '', answeredBy: { writer: null, verifier: 'zeus:default_model', mode: 'check-supplied' },
    sentences: [{ text: 'The flight was headed from Atlanta to Lexington.', verdict: 'contradicted', checked_by: 'zeus:default_model', evidence: [{ passage: 's1', quote: "was headed from Lexington's Blue Grass Airport to Atlanta's Hartsfield-Jackson International Airport" }] }],
    passages: [{ id: 's1', supplied: 1 }], hashes: {}, supplied: { 1: { sha256: sha, title: 'Comair', url: null } }, issuedAt: '2026-11-27T10:00:00.000Z',
  }));
  assertEquals(r.atoms, []);
  assertEquals(r.supplied, [{ supplied: 1, sha256: sha, title: 'Comair', url: null }]);
  assertEquals(r.sentences[0].evidence, [{ supplied: 1, quote: "was headed from Lexington's Blue Grass Airport to Atlanta's Hartsfield-Jackson International Airport" }]);
  assert(!canonicalJson(r).includes('Polehinke'), 'the supplied text itself is not in the receipt');
  assert(await receiptIntact(r));
});

Deno.test('check: the supplied-passage fixture verify_receipt.py tests against is intact and fingerprints the request it came from', async () => {
  const r = JSON.parse(await Deno.readTextFile(new URL('./fixtures/receipt_supplied.json', import.meta.url)));
  const body = JSON.parse(await Deno.readTextFile(new URL('./fixtures/check_request.json', import.meta.url)));
  assert(await receiptIntact(r));
  const parsed = parseCheckRequest(body);
  assert(!('error' in parsed));
  if (!('error' in parsed)) for (const [i, p] of parsed.supplied!.entries()) assertEquals(r.supplied[i].sha256, await sha256Hex(p.text), `passage ${i + 1}`);
});

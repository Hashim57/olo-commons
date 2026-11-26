// deno test --allow-read tests/
import { assert, assertEquals } from './_assert.ts';
import { buildReceipt, canonicalJson, receiptIntact, RECEIPT_FORMAT, sealReceipt, sha256Hex } from '../functions/olo-answer/receipt.ts';

// Two real Wikinews atoms (CC BY 2.5) as the live Commons held them on 26 November 2026, read through olo_atom.
const PASSAGES = [
  { id: 'p1', atom: '43ab91a6-50bc-4f4d-8807-7363377e1087', title: '49 dead after Comair regional jet crashes in Kentucky', source_slug: 'wikinews', licence: 'CC BY 2.5', url: 'https://en.wikinews.org/wiki/49_dead_after_Comair_regional_jet_crashes_in_Kentucky', retrieved_at: '2026-11-24T12:18:12.022437+00:00', published_at: '2006-08-28' },
  { id: 'p2', atom: '43a940f5-b411-4d66-9c66-6e4773949d19', title: 'Dell recalls potentially incendiary laptop batteries', source_slug: 'wikinews', licence: 'CC BY 2.5', url: 'https://en.wikinews.org/wiki/Dell_recalls_potentially_incendiary_laptop_batteries', retrieved_at: '2026-11-24T12:48:10.51009+00:00', published_at: '2006-08-15' },
];
const HASHES = {
  '43ab91a6-50bc-4f4d-8807-7363377e1087': '503eda912c84168aecaf7e0d8aa181bc412f3763c4d34810ed4829612ee52107',
  '43a940f5-b411-4d66-9c66-6e4773949d19': 'cfc1aceb4bf2b7962038e2bffd85d5f5f6dd29b2562e75a70881a14d88899f27',
};
const SENTENCES = [
  { text: 'Comair Flight 5191 crashed on takeoff from Lexington, Kentucky, killing 49 people on board [p1].', verdict: 'supported', checked_by: 'zeus:default_model', citations: ['p1'],
    evidence: [{ passage: 'p1', quote: "A Comair commuter jet crashed on takeoff from Lexington, Kentucky yesterday, killing 49 people on board" }] },
  { text: 'The flight was headed from Atlanta to Lexington [p1].', verdict: 'contradicted', checked_by: 'zeus:default_model', citations: ['p1'],
    evidence: [{ passage: 'p1', quote: "was headed from Lexington's Blue Grass Airport to Atlanta's Hartsfield-Jackson International Airport" }, { passage: 'p9', quote: 'a passage that was never shown' }] },
  { text: 'Dell is recalling 4.1 million lithium batteries [p2].', verdict: 'not_covered', checked_by: null, citations: ['p2'], evidence: [] },
];
const INPUT = { question: 'What happened to Comair Flight 5191?', answerShown: SENTENCES[0].text, answeredBy: { writer: 'openai/gpt-oss-120b', verifier: 'zeus:default_model', mode: 'written' }, sentences: SENTENCES, passages: PASSAGES, hashes: HASHES, issuedAt: '2026-11-26T22:00:00.000Z' };

Deno.test('receipt: evidence is keyed to atom ids, every passage keeps its fingerprint, licence and source, and only supported sentences are shown', () => {
  const r = buildReceipt(INPUT);
  assertEquals(r.format, RECEIPT_FORMAT);
  assertEquals(r.sentences.map(s => [s.n, s.verdict, s.shown]), [[1, 'supported', true], [2, 'contradicted', false], [3, 'not_covered', false]]);
  assertEquals(r.sentences[0].evidence, [{ atom: PASSAGES[0].atom, quote: SENTENCES[0].evidence[0].quote }]);
  assertEquals(r.sentences[1].evidence.length, 1, 'evidence naming a passage the answer did not have is dropped, not invented an atom');
  assertEquals(r.atoms.map(a => [a.atom, a.content_hash, a.licence, a.source]), PASSAGES.map(p => [p.atom, (HASHES as any)[p.atom], p.licence, p.source_slug]));
  assertEquals(r.sentences[2].checked_by, null);
});

Deno.test('receipt: an atom whose fingerprint could not be read gets null, never a made-up value', () => {
  const r = buildReceipt({ ...INPUT, hashes: {} });
  assert(r.atoms.every(a => a.content_hash === null));
});

Deno.test('receipt: the seal is the SHA-256 of the canonical JSON, and any edit breaks it', async () => {
  const sealed = await sealReceipt(buildReceipt(INPUT));
  assertEquals(sealed.receipt_sha256!.length, 64);
  assert(await receiptIntact(sealed), 'a fresh receipt is intact');
  assert(!(await receiptIntact({ ...sealed, answer_shown: sealed.answer_shown + ' And more.' })), 'an edited answer is caught');
  const flipped = { ...sealed, sentences: sealed.sentences.map((s, i) => i === 1 ? { ...s, verdict: 'supported' } : s) };
  assert(!(await receiptIntact(flipped)), 'a verdict changed after the fact is caught');
  assert(!(await receiptIntact({ ...sealed, receipt_sha256: undefined } as any)), 'no seal, not intact');
  // sealing twice gives the same seal: the old one is never part of what is hashed
  assertEquals((await sealReceipt(sealed)).receipt_sha256, sealed.receipt_sha256);
});

Deno.test('receipt: canonical JSON sorts keys at every level, keeps array order and unicode, and refuses floats', async () => {
  assertEquals(canonicalJson({ b: 1, a: [{ d: null, c: 'é "x"' }, true] }), '{"a":[{"c":"é \\"x\\"","d":null},true],"b":1}');
  assertEquals(canonicalJson({ a: undefined, b: 2 }), '{"b":2}');
  let threw = false; try { canonicalJson({ x: 0.5 }); } catch { threw = true; }
  assert(threw, 'floats are refused: Python and JavaScript print some of them differently');
  assertEquals(await sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

Deno.test('receipt: the fixture scripts/verify_receipt.py tests against is this receipt, byte for byte', async () => {
  const sealed = await sealReceipt(buildReceipt(INPUT));
  const fixture = JSON.parse(await Deno.readTextFile(new URL('./fixtures/receipt.json', import.meta.url)));
  assertEquals(canonicalJson(fixture), canonicalJson(sealed), 'regenerate tests/fixtures/receipt.json if the receipt format changes on purpose');
  assert(await receiptIntact(fixture));
});

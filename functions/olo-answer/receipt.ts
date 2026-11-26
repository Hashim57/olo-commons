// The verification receipt: a record of one Olo answer that anyone can check
// later without trusting Helius Network.
//
// A receipt names every sentence Olo wrote, what the verifier said about it,
// the exact words it quoted as evidence and which atom each quote came from,
// and, for every atom the answer drew on, the SHA-256 fingerprint the Commons
// stores for its text (content_hash), its source, licence, URL and retrieval
// time. The whole record is fingerprinted too (receipt_sha256, over a canonical
// JSON form). With it, scripts/verify_receipt.py (standard library only) asks
// the public read API for each atom and confirms, independently of olo-answer:
//   - the receipt has not been edited since it was issued (receipt_sha256);
//   - each atom still has the text it had when the answer was written
//     (content_hash), or says plainly that it has changed or gone;
//   - every quoted piece of evidence is in that atom's own text;
//   - the licence and source of every passage, for citing it.
//
// What a receipt does not claim: the fingerprint makes a receipt tamper-evident
// once it has been kept or published somewhere; it is not a signature, so it
// does not by itself prove who issued it. docs/RECEIPTS.md says how to use it
// and what a signed receipt would add.
//
// Pure: no I/O, so tests/receipt_test.ts runs it without the Edge runtime.

export const RECEIPT_FORMAT = 'olo-receipt/1';
export const RECEIPT_DOC = 'https://github.com/Hashim57/olo-commons/blob/main/docs/RECEIPTS.md';

export type ReceiptSentence = { text: string; verdict: string; checked_by?: string | null; citations?: string[]; evidence?: { passage: string; quote: string }[] };
export type ReceiptPassage = { id: string; atom?: string | null; supplied?: number; title?: string | null; source_slug?: string | null; licence?: string | null; url?: string | null; retrieved_at?: string | null; published_at?: string | null };

export type Receipt = {
  format: string;
  issued_at: string;
  question: string;
  answer_shown: string;
  answered_by: { writer: string | null; verifier: string | null; mode: string };
  sentences: { n: number; text: string; verdict: string; checked_by: string | null; shown: boolean; evidence: ({ atom: string; quote: string } | { supplied: number; quote: string })[] }[];
  atoms: { atom: string; content_hash: string | null; title: string | null; source: string | null; licence: string | null; url: string | null; retrieved_at: string | null; published_at: string | null }[];
  // Check mode with the caller's own passages (check.ts): each passage's SHA-256 and what the caller said it was.
  // Absent when every passage is a Commons atom, so receipts of ordinary answers keep the same bytes.
  supplied?: { supplied: number; sha256: string; title: string | null; url: string | null }[];
  check: string;
  receipt_sha256?: string;
};

/**
 * JSON with object keys sorted at every level and no whitespace, so the same
 * record always gives the same bytes. Python's json.dumps(x, sort_keys=True,
 * separators=(',', ':'), ensure_ascii=False) writes the same text for the
 * values a receipt holds (strings, integers, booleans, null, arrays, objects);
 * scripts/verify_receipt.py relies on that, and a test pins one example.
 */
export function canonicalJson(v: unknown): string {
  if (v === null || typeof v !== 'object') {
    if (typeof v === 'number' && !Number.isInteger(v)) throw new Error('a receipt holds integers only, never floats');
    return JSON.stringify(v ?? null);
  }
  if (Array.isArray(v)) return '[' + v.map(canonicalJson).join(',') + ']';
  const o = v as Record<string, unknown>;
  return '{' + Object.keys(o).filter(k => o[k] !== undefined).sort().map(k => JSON.stringify(k) + ':' + canonicalJson(o[k])).join(',') + '}';
}

export async function sha256Hex(s: string): Promise<string> {
  const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join('');
}

/**
 * The receipt for one answer, without its fingerprint (see sealReceipt). Each
 * sentence's evidence is re-keyed from the passage label the verifier saw
 * ("p2") to the atom id, which is what outlives the response. A sentence is
 * `shown` when it is supported, the same rule shownAnswer applies. Atoms are
 * listed in passage order, once each; one with no stored fingerprint (hashes
 * maps no entry for it) gets null, and the check says so rather than guess.
 * In check mode a passage the caller supplied is keyed by its number and
 * listed under `supplied` with the SHA-256 of its text, never the text.
 */
export function buildReceipt(input: {
  question: string;
  answerShown: string;
  answeredBy: { writer: string | null; verifier: string | null; mode: string };
  sentences: ReceiptSentence[];
  passages: ReceiptPassage[];
  hashes: Record<string, string>;
  issuedAt: string;
  // check mode: passage number -> { sha256 of its text, title, url } for passages the caller supplied
  supplied?: Record<number, { sha256: string; title?: string | null; url?: string | null }>;
}): Receipt {
  const keyOf = new Map<string, { atom: string } | { supplied: number }>();
  for (const p of input.passages) {
    if (p.atom) keyOf.set(p.id, { atom: p.atom });
    else if (typeof p.supplied === 'number') keyOf.set(p.id, { supplied: p.supplied });
  }
  const atomPassages: ReceiptPassage[] = [];
  const seen = new Set<string>();
  for (const p of input.passages) if (p.atom && !seen.has(p.atom)) { seen.add(p.atom); atomPassages.push(p); }
  const suppliedNs = Object.keys(input.supplied || {}).map(Number).sort((a, b) => a - b);
  return {
    format: RECEIPT_FORMAT,
    issued_at: input.issuedAt,
    question: input.question,
    answer_shown: input.answerShown,
    answered_by: { writer: input.answeredBy.writer ?? null, verifier: input.answeredBy.verifier ?? null, mode: input.answeredBy.mode },
    sentences: input.sentences.map((s, i) => ({
      n: i + 1,
      text: s.text,
      verdict: s.verdict,
      checked_by: s.checked_by ?? null,
      shown: s.verdict === 'supported',
      evidence: (s.evidence || []).filter(e => keyOf.has(e.passage)).map(e => ({ ...keyOf.get(e.passage)!, quote: e.quote })),
    })),
    atoms: atomPassages.map(p => ({
      atom: p.atom!,
      content_hash: input.hashes[p.atom!] ?? null,
      title: p.title ?? null,
      source: p.source_slug ?? null,
      licence: p.licence ?? null,
      url: p.url ?? null,
      retrieved_at: p.retrieved_at ?? null,
      published_at: p.published_at ?? null,
    })),
    ...(suppliedNs.length ? { supplied: suppliedNs.map(n => ({ supplied: n, sha256: input.supplied![n].sha256, title: input.supplied![n].title ?? null, url: input.supplied![n].url ?? null })) } : {}),
    check: RECEIPT_DOC,
  };
}

/** The receipt with receipt_sha256 added: the SHA-256 of the canonical JSON of everything else. */
export async function sealReceipt(r: Receipt): Promise<Receipt> {
  const { receipt_sha256: _drop, ...rest } = r;
  return { ...rest, receipt_sha256: await sha256Hex(canonicalJson(rest)) };
}

/** True when a receipt's fingerprint matches its contents (what verify_receipt.py checks first). */
export async function receiptIntact(r: Receipt): Promise<boolean> {
  if (!r || typeof r.receipt_sha256 !== 'string') return false;
  const { receipt_sha256, ...rest } = r;
  return receipt_sha256 === await sha256Hex(canonicalJson(rest));
}

// The check mode of olo-answer: send any text, get each sentence back with a
// verdict, the quoted evidence and a receipt. The same checking Olo applies to
// its own answers (Zeus, the quote check, the figure check), offered for other
// people's drafts and for the output of other AI systems.
//
//   POST /functions/v1/olo-answer
//   { "mode": "check", "text": "<text to check>" }                         checked against the Commons
//   { "mode": "check", "text": "...", "passages": [ { "text": "...", "url": "...", "title": "..." } ] }
//                                                                          checked against your own sources
//
// With passages, each sentence is checked against the supplied text only (the
// caller's own retrieved context, a contract, a paper), cut into chunks the
// verifier reads well; nothing supplied is stored. Without passages, each
// sentence is checked against the Commons passages retrieved for it.
//
// Pure helpers only (no I/O), so tests/check_test.ts covers them.

import { contentWords, splitSentences, type Passage } from './answer.ts';

export const CHECK_MAX_TEXT = 4000;          // characters of text to check in one call
export const CHECK_MAX_SENTENCES = { anon: 6, keyed: 20 };
export const CHECK_MAX_PASSAGES = 8;         // supplied passages per call
export const CHECK_MAX_PASSAGE_CHARS = 20000; // characters per supplied passage (longer ones are refused, not cut silently)
export const CHUNK_CHARS = 900;              // the passage length the verifier is trained on (labelPassages' maxChars)
export const SCOPE_PER_SENTENCE = 3;         // chunks shown to the verifier for one sentence

export type SuppliedPassage = { text: string; url?: string; title?: string; source?: string };
export type CheckRequest = { text: string; supplied: SuppliedPassage[] | null };

/** A check request read from a POST body, or the reason it cannot be. */
export function parseCheckRequest(body: any): CheckRequest | { error: string } {
  const text = String(body?.text ?? '').replace(/\s+/g, ' ').trim();
  if (text.length < 2) return { error: 'text is required (2 to 4000 characters)' };
  if (text.length > CHECK_MAX_TEXT) return { error: `text is ${text.length} characters; the limit is ${CHECK_MAX_TEXT} a call` };
  if (body?.passages == null) return { text, supplied: null };
  if (!Array.isArray(body.passages)) return { error: 'passages must be a list of { text, url?, title? }' };
  if (!body.passages.length) return { error: 'passages is empty; leave it out to check against the Commons' };
  if (body.passages.length > CHECK_MAX_PASSAGES) return { error: `at most ${CHECK_MAX_PASSAGES} passages a call` };
  const supplied: SuppliedPassage[] = [];
  for (const [i, p] of body.passages.entries()) {
    const t = String((typeof p === 'string' ? p : p?.text) ?? '').replace(/\s+/g, ' ').trim();
    if (t.length < 20) return { error: `passage ${i + 1} has no text (20 characters at least)` };
    if (t.length > CHECK_MAX_PASSAGE_CHARS) return { error: `passage ${i + 1} is ${t.length} characters; the limit is ${CHECK_MAX_PASSAGE_CHARS}` };
    const url = typeof p?.url === 'string' && /^https?:\/\//i.test(p.url) ? p.url.slice(0, 500) : undefined;
    const title = typeof p?.title === 'string' ? p.title.replace(/\s+/g, ' ').trim().slice(0, 200) : undefined;
    supplied.push({ text: t, ...(url ? { url } : {}), ...(title ? { title } : {}) });
  }
  return { text, supplied };
}

/** The sentences to check, at most the limit for the caller; the rest are reported as not checked, never dropped silently. */
export function checkSentences(text: string, keyed: boolean): { checked: string[]; unchecked: number } {
  const all = splitSentences(text).map(s => s.text.replace(/\s*(\[p\d+\])+\s*$/g, '').trim()).filter(s => s.length >= 2);
  const max = keyed ? CHECK_MAX_SENTENCES.keyed : CHECK_MAX_SENTENCES.anon;
  return { checked: all.slice(0, max), unchecked: Math.max(0, all.length - max) };
}

/**
 * A supplied passage cut into chunks of about CHUNK_CHARS at sentence ends where it can be, so the
 * verifier reads text of the length it was trained on. Chunk ids are "s<passage>.<chunk>" ("s2.3");
 * a passage that fits in one chunk keeps "s<passage>". Every chunk is a verbatim slice of the passage
 * (whitespace collapsed), so a quote found in a chunk is in the passage.
 */
export function chunkSupplied(supplied: SuppliedPassage[]): (Passage & { passage: number })[] {
  const out: (Passage & { passage: number })[] = [];
  supplied.forEach((p, i) => {
    const n = i + 1;
    const parts: string[] = [];
    let rest = p.text;
    while (rest.length > CHUNK_CHARS) {
      const window = rest.slice(0, CHUNK_CHARS);
      const cut = Math.max(window.lastIndexOf('. '), window.lastIndexOf('? '), window.lastIndexOf('! '));
      const at = cut > CHUNK_CHARS / 3 ? cut + 1 : (window.lastIndexOf(' ') > CHUNK_CHARS / 3 ? window.lastIndexOf(' ') : CHUNK_CHARS);
      parts.push(rest.slice(0, at).trim());
      rest = rest.slice(at).trim();
    }
    if (rest) parts.push(rest);
    parts.forEach((t, j) => out.push({ id: parts.length === 1 ? `s${n}` : `s${n}.${j + 1}`, source: p.source || 'supplied', url: p.url || '', ...(p.title ? { title: p.title } : {}), text: t, passage: n }));
  });
  return out;
}

/**
 * The chunks one sentence is checked against: the SCOPE_PER_SENTENCE that share the most content words
 * with it (ties keep document order), and never none: with no overlap at all the first chunks go, so the
 * verifier can still say "not covered" with the caller's text in front of it.
 */
export function scopeFor<P extends Passage>(sentence: string, chunks: P[], n = SCOPE_PER_SENTENCE): P[] {
  const want = new Set(contentWords(sentence));
  const scored = chunks.map((c, i) => {
    const have = new Set(contentWords(c.text));
    let s = 0; for (const w of want) if (have.has(w)) s++;
    return { c, i, s };
  });
  return scored.sort((a, b) => b.s - a.s || a.i - b.i).slice(0, n).sort((a, b) => a.i - b.i).map(x => x.c);
}

/** The summary line of a check: how many sentences each verdict got, and how many were left unchecked by the limit. */
export function checkSummary(verdicts: { verdict: string }[], unchecked: number) {
  const s = { supported: 0, contradicted: 0, not_covered: 0, unchecked };
  for (const v of verdicts) if (v.verdict in s) (s as any)[v.verdict]++;
  return s;
}

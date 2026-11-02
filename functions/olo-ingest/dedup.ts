// Cross-source deduplication: pure functions, no I/O, tested with `deno test tests/`.
// index.ts does the lookups and the writes; see docs/TRUST.md "Duplicates".
//
// The main real case is one paper reaching the Commons from arXiv, PubMed and
// OpenAlex. Storing it three times would serve the same abstract three times and
// make the graph look thicker than it is. Dropping the second copy would lose the
// second source's provenance and the agreement signal TRUST.md counts toward
// "verified". So a duplicate is not inserted as a new atom; it is recorded as a
// sighting of the existing atom (source, url, licence, identifiers, reason), and
// sightings from other sources count toward corroboration in olo_rescore_atom
// (sql/009) exactly as a strongly similar atom from another source did before.
//
// What counts as a duplicate, strongest evidence first:
//   same_doi   the same DOI (case, doi.org URL form, "doi:" prefix and URL
//              encoding do not matter), with no conflicting PMID
//   same_pmid  the same PubMed id, with no conflicting DOI
//   same_text  the same title and body once case, accents, punctuation, HTML
//              entities and whitespace are normalised away
//   near_text  word 3-gram shingle Jaccard of the bodies >= NEAR_TEXT and title
//              word overlap >= TITLE_MIN, both texts long enough to judge
// Only atoms from ANOTHER source are ever treated as duplicates: within one
// source the url and content hash already refuse exact copies, and two pages of
// one source with near-identical text (Wikidata homonyms, arXiv versions) are
// different records that the re-check and supersede path handles. Superseded
// atoms are never a target, and two records whose DOIs (or PMIDs) differ are
// never merged on text alone, so a preprint and its journal version stay apart.

import { clean } from './text.ts';

/** Body shingle Jaccard needed to call two texts near-duplicates. */
export const NEAR_TEXT = 0.9;
/** Title word overlap (Jaccard) needed alongside NEAR_TEXT. */
export const TITLE_MIN = 0.8;
/** Fewer body words than this and only an exact normalised match counts. */
export const MIN_WORDS = 25;
/** Fewer body words than this and not even an exact normalised match counts. */
export const MIN_EXACT_WORDS = 5;
/** Embedding cosine at which index.ts fetches a neighbour to compare text with. Recall only: the decision is textual. */
export const NEAR_EMBED = 0.95;
const SHINGLE = 3;

export type DedupRecord = {
  source_id: string; url: string; title: string;
  summary?: string | null; content?: string | null;
  doi?: string | null; pmid?: string | null;
};
export type DedupExisting = DedupRecord & { id: string; status?: string | null };
export type DedupReason = 'same_doi' | 'same_pmid' | 'same_text' | 'near_text';
export type Decision =
  | { action: 'insert' }
  | { action: 'duplicate'; of: string; reason: DedupReason; score: number };

/** A DOI in any common written form -> bare lower-case DOI, or null. */
export function normDoi(s: unknown): string | null {
  let t = String(s ?? '').trim();
  if (!t) return null;
  try { t = decodeURIComponent(t); } catch (_) { /* keep as written */ }
  const m = t.match(/10\.\d{4,9}\/[^\s"<>]+/i);
  return m ? m[0].replace(/[.,;)\]]+$/, '').toLowerCase() : null;
}

/** A PubMed id ("PMID: 123", " 123 ", 123) -> digits without leading zeros, or null. */
export function normPmid(s: unknown): string | null {
  const t = String(s ?? '').trim().replace(/^pmid:?\s*/i, '');
  if (!/^\d{1,10}$/.test(t)) return null;
  const n = t.replace(/^0+/, '');
  return n || null;
}

/** Plain, comparable text: tags stripped, entities decoded, accents folded, lower case, punctuation as spaces. */
export function normaliseText(s: unknown): string {
  return clean(s)
    .normalize('NFKD').replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

const words = (s: string) => (s ? s.split(' ') : []);

/** The body that is compared: the longest text the record carries. */
export function bodyOf(r: { summary?: string | null; content?: string | null }): string {
  const a = r.content || '', b = r.summary || '';
  return a.length >= b.length ? a : b;
}

/** The key whose hash is stored as olo_atoms.norm_hash (sql/009), so an exact normalised match is one indexed lookup. */
export function normKey(title: string, body: string): string {
  return normaliseText(title) + '\n' + normaliseText(body);
}

function shingles(ws: string[], k = SHINGLE): Set<string> {
  const out = new Set<string>();
  if (ws.length < k) { if (ws.length) out.add(ws.join(' ')); return out; }
  for (let i = 0; i + k <= ws.length; i++) out.add(ws.slice(i, i + k).join(' '));
  return out;
}

function jaccard(a: Set<string>, b: Set<string>): number {
  if (!a.size && !b.size) return 0;
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  return inter / (a.size + b.size - inter);
}

/** Word 3-gram shingle Jaccard of two texts after normalisation, 0..1. */
export function textSimilarity(a: string, b: string): number {
  return jaccard(shingles(words(normaliseText(a))), shingles(words(normaliseText(b))));
}

/** Word-set Jaccard of two titles after normalisation, 0..1. */
export function titleSimilarity(a: string, b: string): number {
  return jaccard(new Set(words(normaliseText(a))), new Set(words(normaliseText(b))));
}

const differ = (x: string | null, y: string | null) => x !== null && y !== null && x !== y;

/**
 * Is `cand` the same atom as one already stored? `existing` should be ordered oldest first
 * (the first match wins, so the earliest copy stays canonical). Returns insert, or the id to
 * record the candidate against, why, and a score (1 for identifiers and exact text).
 */
export function decide(cand: DedupRecord, existing: DedupExisting[]): Decision {
  const cDoi = normDoi(cand.doi), cPmid = normPmid(cand.pmid);
  const pool = existing.filter(e => e.source_id !== cand.source_id && e.status !== 'superseded');

  for (const e of pool) {
    const eDoi = normDoi(e.doi), ePmid = normPmid(e.pmid);
    if (cDoi && eDoi === cDoi && !differ(cPmid, ePmid)) return { action: 'duplicate', of: e.id, reason: 'same_doi', score: 1 };
  }
  for (const e of pool) {
    const eDoi = normDoi(e.doi), ePmid = normPmid(e.pmid);
    if (cPmid && ePmid === cPmid && !differ(cDoi, eDoi)) return { action: 'duplicate', of: e.id, reason: 'same_pmid', score: 1 };
  }

  const cTitle = normaliseText(cand.title), cBody = normaliseText(bodyOf(cand));
  const cWords = words(cBody);
  if (cWords.length < MIN_EXACT_WORDS) return { action: 'insert' };
  const cSh = shingles(cWords);
  let best: Decision = { action: 'insert' };
  for (const e of pool) {
    // Different identifiers mean different records, however alike the text reads.
    if (differ(cDoi, normDoi(e.doi)) || differ(cPmid, normPmid(e.pmid))) continue;
    const eTitle = normaliseText(e.title), eBody = normaliseText(bodyOf(e));
    if (eTitle === cTitle && eBody === cBody) return { action: 'duplicate', of: e.id, reason: 'same_text', score: 1 };
    const eWords = words(eBody);
    if (cWords.length < MIN_WORDS || eWords.length < MIN_WORDS) continue;
    const t = jaccard(new Set(words(cTitle)), new Set(words(eTitle)));
    if (t < TITLE_MIN) continue;
    const s = jaccard(cSh, shingles(eWords));
    if (s >= NEAR_TEXT && (best.action === 'insert' || s > best.score)) best = { action: 'duplicate', of: e.id, reason: 'near_text', score: Math.round(s * 1000) / 1000 };
  }
  return best;
}

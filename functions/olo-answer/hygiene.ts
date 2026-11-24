// Citation hygiene for olo-answer: pure functions, tested without the network.
//
// Zeus checks meaning. These checks catch what independent audits found most often
// even when a citation is present: figures and dates that are not in the source
// (BBC 2025: 19 percent of answers), quotes that are not exact (13 percent), and
// links that do not resolve (Tow Center 2025: 154 of Grok-3's 200 links). Each
// check is strict and cheap, and a failure downgrades the sentence rather than
// silently passing it.

import type { Label, Passage } from './answer.ts';

/** Numbers worth checking: two or more digits, or a decimal or percent. Single digits are too often spelt out in prose. */
const NUMBER = /(?<![\w.])(\d{1,3}(?:[,\s]\d{3})+|\d+\.\d+|\d{2,})(\s?%)?/g;

/** Normalise a numeric token so "1,200,000" and "1200000" compare equal. */
export function normaliseNumber(tok: string): string {
  return tok.replace(/[,\s]/g, '').replace(/%$/, '');
}

/** The checkable figures in a sentence. */
export function figures(text: string): string[] {
  const out = new Set<string>();
  for (const m of String(text || '').matchAll(NUMBER)) out.add(normaliseNumber(m[1]));
  return [...out];
}

/**
 * Every figure in the sentence must appear in the passages it rests on. Returns the figures that do not.
 * A number written in the passage with thin spaces or commas still matches; a figure that only appears
 * inside a longer number does not (1971 is not in 19712).
 */
export function missingFigures(sentence: string, scope: Passage[]): string[] {
  const hay = scope.map(p => p.text).join('\n');
  const present = new Set(figures(hay));
  return figures(sentence).filter(f => !present.has(f));
}

/** Downgrade a supported verdict whose sentence carries a figure the sources do not. */
export function applyFigureCheck<V extends { verdict: Label; rationale: string }>(v: V, sentence: string, scope: Passage[]): V & { figures_checked: boolean; figures_missing: string[] } {
  const missing = missingFigures(sentence, scope);
  if (v.verdict === 'supported' && missing.length) {
    return { ...v, verdict: 'not_covered', rationale: `The figure ${missing.join(', ')} does not appear in the cited passage${scope.length === 1 ? '' : 's'}. (${v.rationale})`, figures_checked: true, figures_missing: missing };
  }
  return { ...v, figures_checked: true, figures_missing: missing };
}

/**
 * Freshness and independence of the sources an answer rests on, for the line under every answer:
 * how many independent publishers, the newest and oldest publication dates, and when the Commons last
 * re-read the newest one. Dates are ISO strings or null.
 */
export function sourceSummary(passages: { source_slug?: string; source?: string; published_at?: string | null; observed_at?: string | null; credibility?: number | null; status?: string | null }[]) {
  const slugs = new Set(passages.map(p => String(p.source_slug || p.source || '')).filter(Boolean));
  const dates = passages.map(p => p.published_at).filter((d): d is string => typeof d === 'string' && /^\d{4}-\d{2}-\d{2}/.test(d)).sort();
  const observed = passages.map(p => p.observed_at).filter((d): d is string => typeof d === 'string').sort();
  const creds = passages.map(p => p.credibility).filter((c): c is number => typeof c === 'number');
  const verified = passages.filter(p => p.status === 'verified').length;
  return {
    passages: passages.length,
    independent_sources: slugs.size,
    newest_published: dates.length ? dates[dates.length - 1] : null,
    oldest_published: dates.length ? dates[0] : null,
    last_observed: observed.length ? observed[observed.length - 1] : null,
    median_credibility: creds.length ? creds.slice().sort((a, b) => a - b)[Math.floor(creds.length / 2)] : null,
    verified_passages: verified,
  };
}

/** True when the question is about something that changes: it deserves a freshness caution on old sources. */
export function timeSensitive(q: string): boolean {
  return /\b(latest|current|currently|now|today|this (year|month|week)|recent|recently|new|newest|price|cost|who is the|how many .* (are|is) there|202\d|203\d)\b/i.test(q);
}

/**
 * The answer as shown by default: only supported sentences. The rest is still returned, behind "show unverified".
 * When nothing is supported the shown answer says so instead of showing a plausible unverified paragraph.
 */
export function shownAnswer(sentences: { text: string; verdict: Label }[]): { text: string; shown: number; hidden: number; abstained: boolean } {
  const kept = sentences.filter(s => s.verdict === 'supported');
  const hidden = sentences.length - kept.length;
  if (!kept.length) return { text: COULD_NOT_VERIFY, shown: 0, hidden, abstained: true };
  return { text: kept.map(s => s.text).join(' '), shown: kept.length, hidden, abstained: false };
}

export const COULD_NOT_VERIFY = 'Olo could not verify an answer to this from the sources it has. The unverified draft is available, but not shown by default.';

/** The arguments of olo_answer_record (sql/022): counts only, never text. */
export type AnswerTally = {
  p_covered: boolean; p_abstained: boolean; p_extractive: boolean;
  p_supported: number; p_contradicted: number; p_not_covered: number;
  p_zeus: number; p_fallback: number; p_unchecked: number; p_zeus_supported: number;
};

/**
 * What one answer adds to the day's tally (issue #76, part 4): how many sentences were supported,
 * contradicted or not covered after the figure check, how many of them Zeus checked (checked_by
 * "zeus:<model>"), the fallback verifier checked ("llm-fallback") or nobody checked (null, and every
 * quoted sentence of an extractive answer), and how many of Zeus's own sentences it supported.
 * Pure: the caller sends the result to the database and ignores a failure.
 */
export function answerTally(sentences: { verdict: Label; checked_by?: string | null }[], covered: boolean, abstained: boolean, extractive = false): AnswerTally {
  const t: AnswerTally = { p_covered: covered, p_abstained: abstained, p_extractive: extractive, p_supported: 0, p_contradicted: 0, p_not_covered: 0, p_zeus: 0, p_fallback: 0, p_unchecked: 0, p_zeus_supported: 0 };
  for (const s of sentences) {
    if (s.verdict === 'supported') t.p_supported++;
    else if (s.verdict === 'contradicted') t.p_contradicted++;
    else t.p_not_covered++;
    const by = extractive ? null : s.checked_by || null;
    if (by && by.startsWith('zeus:')) { t.p_zeus++; if (s.verdict === 'supported') t.p_zeus_supported++; }
    else if (by === 'llm-fallback') t.p_fallback++;
    else t.p_unchecked++;
  }
  return t;
}

/**
 * Check that a url still answers. HEAD first; some hosts refuse HEAD, so a 405 or 403 is retried as a
 * one-byte GET. Redirects count as fine (DOIs always redirect). Never throws; a timeout is "unknown".
 */
export async function linkOk(url: string, timeoutMs = 4000, fetcher: typeof fetch = fetch): Promise<boolean | null> {
  const opts = (method: string) => ({ method, redirect: 'follow' as const, signal: AbortSignal.timeout(timeoutMs), headers: { 'User-Agent': 'OloCommons/1.0 (+https://heliusnetwork.app/olo; link check)', ...(method === 'GET' ? { Range: 'bytes=0-0' } : {}) } });
  try {
    const h = await fetcher(url, opts('HEAD'));
    if (h.status < 400) return true;
    if (h.status === 405 || h.status === 403 || h.status === 501) {
      const g = await fetcher(url, opts('GET'));
      return g.status < 400;
    }
    return false;
  } catch { return null; }
}

/** Check the distinct urls of the cited passages in parallel, bounded in number and time. */
export async function checkLinks(urls: string[], max = 6, fetcher: typeof fetch = fetch): Promise<Record<string, boolean | null>> {
  const distinct = [...new Set(urls.filter(u => /^https?:\/\//.test(u)))].slice(0, max);
  const results = await Promise.all(distinct.map(u => linkOk(u, 4000, fetcher)));
  return Object.fromEntries(distinct.map((u, i) => [u, results[i]]));
}

/** The arguments of olo_review_candidate (sql/024): one sentence the verifier doubted, with what it was checked against. */
export type ReviewCandidate = {
  p_claim: string; p_verdict: 'contradicted' | 'not_covered';
  p_passages: { atom?: string; url?: string; quote?: string }[]; p_checked_by: string | null;
};

/**
 * The sentences of one answer that a person should look at (issue #76, part 4): those a served Zeus
 * adapter (checked_by "zeus:<model>") called contradicted or not covered, and whose verdict stood through
 * the figure check. A sentence the fallback verifier or nobody checked is left out: the point is to find
 * Zeus's mistakes and the Commons' wrong answers, and a fallback verdict says nothing about either. Each
 * candidate carries the passages the sentence was checked against (the cited ones, or all of them when
 * it cited none), as atom ids and urls, with Zeus's own quote where it gave one, so the review and
 * zeus/feedback_to_gold.py can rebuild the example from the real text. At most `max` a response, the
 * contradicted ones first (a contradiction is the rarer and the more telling verdict), none longer than
 * the table allows (600 characters) or shorter than a sentence, each sentence once.
 * Pure: the caller sends each candidate to the database and ignores a failure.
 */
export function reviewCandidates(
  sentences: { text: string; citations?: string[]; verdict: Label; checked_by?: string | null; evidence?: { passage: string; quote: string }[] }[],
  provenance: { id: string; atom?: string | null; url?: string | null }[],
  max = 3,
): ReviewCandidate[] {
  const byId = new Map(provenance.map(p => [p.id, p]));
  const seen = new Set<string>();
  const out: ReviewCandidate[] = [];
  const doubted = sentences.filter(s => (s.verdict === 'contradicted' || s.verdict === 'not_covered') && !!s.checked_by && s.checked_by.startsWith('zeus:'));
  doubted.sort((a, b) => (a.verdict === 'contradicted' ? 0 : 1) - (b.verdict === 'contradicted' ? 0 : 1));
  for (const s of doubted) {
    const claim = String(s.text || '').replace(/\s+/g, ' ').trim();
    if (claim.length < 3 || claim.length > 600 || seen.has(claim)) continue;
    seen.add(claim);
    const quotes = new Map((s.evidence || []).filter(e => e && e.passage && e.quote).map(e => [e.passage, String(e.quote).slice(0, 600)]));
    const cited = (s.citations || []).filter(id => byId.has(id));
    const ids = cited.length ? cited : provenance.map(p => p.id);
    const passages = ids.slice(0, 12).map(id => {
      const p = byId.get(id)!;
      const entry: { atom?: string; url?: string; quote?: string } = {};
      if (p.atom) entry.atom = String(p.atom);
      if (p.url) entry.url = String(p.url);
      if (quotes.has(id)) entry.quote = quotes.get(id);
      return entry;
    }).filter(p => p.atom || p.url);
    out.push({ p_claim: claim, p_verdict: s.verdict as 'contradicted' | 'not_covered', p_passages: passages, p_checked_by: s.checked_by || null });
    if (out.length >= max) break;
  }
  return out;
}

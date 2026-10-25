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

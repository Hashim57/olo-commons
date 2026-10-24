// integrations/olo-web/commons.ts
//
// Drop-in for the helius-olo.io server (olo-web): ask Olo Commons for a checked
// answer and turn it into the stream events the olo-web client already renders
// (sources, verification claims with supported / contradicted / unsupported,
// answer_complete). No dependencies; runs on Node 18+, Deno and Netlify
// Functions. The Commons call is a public read API: no key is needed, and the
// question is never stored by it.
//
// Typical use inside the /api/chat/stream handler, before (or instead of) the
// model call:
//
//   import { askCommons, commonsEvents } from './commons';
//   const a = await askCommons(content, { k: 8, signal });
//   if (a) for (const ev of commonsEvents(a, { conversationId })) write(JSON.stringify(ev) + '\n');
//   if (!a || !a.covered) { ...fall through to the usual model answer... }
//
// Every event here carries exactly the fields the client reads (see the bundle:
// type start/delta/sources/status/verification/notice/followups/answer_complete).

export type Verdict = 'supported' | 'contradicted' | 'not_covered';

export interface CommonsPassage {
  id: string; atom: string; title: string; summary?: string | null; url: string; source: string; source_slug: string;
  licence: string; published_at?: string | null; retrieved_at: string; similarity?: number | null; match?: string; citation?: string;
}
export interface CommonsSentence {
  text: string; citations: string[]; verdict: Verdict;
  evidence: { passage: string; quote: string }[]; rationale: string; evidence_checked: boolean;
}
export interface CommonsAnswer {
  q: string; answer: string; covered: boolean; sentences: CommonsSentence[];
  summary: { supported: number; contradicted: number; not_covered: number };
  passages: CommonsPassage[]; verifier: string | null; model: string | null; attribution?: string;
}

/** What the olo-web client renders. verdict "unsupported" is its word for "not covered". */
export interface OloWebSource { index: number; url: string; title: string; snippet?: string; publisher?: string; licence?: string; retrievedAt?: string; }
export interface OloWebClaim { claim: string; verdict: 'supported' | 'contradicted' | 'unsupported'; rationale?: string; excerpt?: string; citedBy: number[]; recalled: false; }
export interface OloWebVerification { claims: OloWebClaim[]; verifier: string; checkedAt: string; }

export const DEFAULT_ENDPOINT = 'https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-answer';

export interface AskOptions { k?: number; endpoint?: string; apiKey?: string; signal?: AbortSignal; timeoutMs?: number; fetchFn?: typeof fetch; }

/**
 * Ask the Commons. Returns null (never throws) when the Commons is unreachable,
 * rate limited or not configured, so the caller can fall back to its own model.
 */
export async function askCommons(question: string, o: AskOptions = {}): Promise<CommonsAnswer | null> {
  const q = String(question || '').replace(/\s+/g, ' ').trim().slice(0, 400);
  if (q.length < 2) return null;
  const f = o.fetchFn || fetch;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), o.timeoutMs ?? 60_000);
  const onAbort = () => ctrl.abort();
  o.signal?.addEventListener('abort', onAbort);
  try {
    const r = await f(o.endpoint || DEFAULT_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(o.apiKey ? { 'x-olo-key': o.apiKey } : {}) },
      body: JSON.stringify({ q, k: Math.max(2, Math.min(o.k ?? 8, 12)) }),
      signal: ctrl.signal,
    });
    if (!r.ok) return null;
    const j = await r.json();
    if (!j || typeof j !== 'object' || !Array.isArray(j.passages) || !Array.isArray(j.sentences)) return null;
    return j as CommonsAnswer;
  } catch (_) {
    return null;
  } finally {
    clearTimeout(t);
    o.signal?.removeEventListener('abort', onAbort);
  }
}

/** Passages become numbered sources (1-based by default, matching how the client cites). */
export function toSources(a: CommonsAnswer, firstIndex = 1): OloWebSource[] {
  return a.passages.map((p, i) => ({
    index: firstIndex + i, url: p.url, title: p.title || p.source,
    snippet: p.summary ? String(p.summary).slice(0, 300) : undefined,
    publisher: p.source, licence: p.licence, retrievedAt: p.retrieved_at,
  }));
}

/** Sentences become claims; p1..pn citations become source indexes. */
export function toVerification(a: CommonsAnswer, firstIndex = 1): OloWebVerification {
  const indexOf = new Map(a.passages.map((p, i) => [p.id, firstIndex + i]));
  const claims: OloWebClaim[] = a.sentences.map(s => {
    const cited = s.citations.map(c => indexOf.get(c)).filter((x): x is number => typeof x === 'number');
    const fromEvidence = (s.evidence || []).map(e => indexOf.get(e.passage)).filter((x): x is number => typeof x === 'number');
    const citedBy = [...new Set([...cited, ...fromEvidence])].sort((x, y) => x - y);
    return {
      claim: s.text,
      verdict: s.verdict === 'supported' ? 'supported' : s.verdict === 'contradicted' ? 'contradicted' : 'unsupported',
      rationale: s.rationale || undefined,
      excerpt: s.evidence && s.evidence.length ? s.evidence[0].quote : undefined,
      citedBy, recalled: false,
    };
  });
  return { claims, verifier: a.verifier || 'none', checkedAt: new Date().toISOString() };
}

/** Human-readable line for the UI, honest about which verifier ran. */
export function verifierLabel(a: CommonsAnswer): string {
  if (!a.verifier) return 'No verifier ran';
  if (a.verifier.startsWith('zeus')) return 'Checked by Zeus against Olo Commons passages';
  return 'Checked with the Zeus prompt by the drafting model (Zeus not connected); passages from Olo Commons';
}

export interface EventOptions { conversationId?: number; firstIndex?: number; followups?: string[]; }

/**
 * The newline-delimited JSON events the olo-web client understands, in the
 * order it expects: status, sources, text deltas (one per sentence, so the
 * answer appears progressively), verification, notice, answer_complete is left
 * to the caller (it owns conversation and message ids).
 */
export function commonsEvents(a: CommonsAnswer, o: EventOptions = {}): Record<string, unknown>[] {
  const first = o.firstIndex ?? 1;
  const ev: Record<string, unknown>[] = [];
  ev.push({ type: 'status', stage: 'retrieving', detail: `${a.passages.length} passages from Olo Commons` });
  if (a.passages.length) ev.push({ type: 'sources', sources: toSources(a, first) });
  if (!a.covered || !a.sentences.length) {
    ev.push({ type: 'notice', message: 'Olo Commons does not cover this yet; it has noted the topic and will read sources on it.' });
    return ev;
  }
  ev.push({ type: 'status', stage: 'checking', detail: verifierLabel(a) });
  const indexOf = new Map(a.passages.map((p, i) => [p.id, first + i]));
  a.sentences.forEach((s, i) => {
    const refs = s.citations.map(c => indexOf.get(c)).filter(x => typeof x === 'number').map(n => `[${n}]`).join('');
    ev.push({ type: 'delta', text: (i ? ' ' : '') + s.text + (refs ? ' ' + refs : '') });
  });
  ev.push({ type: 'verification', verification: toVerification(a, first) });
  if (o.followups && o.followups.length) ev.push({ type: 'followups', questions: o.followups });
  return ev;
}

/** The answer as one string with [n] citations, for storing as the message content. */
export function answerText(a: CommonsAnswer, firstIndex = 1): string {
  if (!a.covered || !a.sentences.length) return 'Olo Commons does not cover this yet.';
  const indexOf = new Map(a.passages.map((p, i) => [p.id, firstIndex + i]));
  return a.sentences.map(s => {
    const refs = s.citations.map(c => indexOf.get(c)).filter(x => typeof x === 'number').map(n => `[${n}]`).join('');
    return s.text + (refs ? ' ' + refs : '');
  }).join(' ');
}

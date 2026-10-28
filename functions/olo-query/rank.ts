// Result ranking for olo-query. Pure functions, no I/O, so `deno test tests/`
// covers them without starting the Edge Function.
//
// Hybrid search runs two retrievers: meaning search (olo_match, cosine over
// gte-small embeddings) and keyword search (olo_search_text, Postgres full
// text). Until now the merge was "all semantic hits first, then any keyword hit
// not already present". With gte-small the cosine scores of unrelated atoms
// cluster close together (0.79 to 0.84 for the same question), so a keyword hit
// that names the exact thing asked about could sit behind a dozen vaguely
// related abstracts. Reciprocal rank fusion fixes that without tuning a
// threshold: each list contributes 1 / (C + position) and an atom found by both
// retrievers adds both, so exact matches that also mean the right thing rise to
// the top, and either retriever alone still gives a sensible order.

export type Hit = { id: string; similarity?: number | null; [key: string]: unknown };
export type Match = 'both' | 'semantic' | 'keyword';
export type Fused = Hit & { match: Match; score: number };

/** The usual RRF constant: large enough that position 1 does not dominate position 2 outright. */
export const RRF_C = 60;

/**
 * Merge two ranked lists by reciprocal rank fusion. Each list is in its own
 * best-first order. The result is best-first, at most `k` long, one entry per id.
 * Field values come from the semantic record when an atom is in both lists (it
 * carries `content` and `similarity`), with any field missing there filled from
 * the keyword record. Ties are broken by similarity, then by the earlier
 * semantic position, so the output is deterministic.
 */
export function fuse(semantic: Hit[], keyword: Hit[], k: number, c = RRF_C): Fused[] {
  const by = new Map<string, { hit: Hit; score: number; inSem: boolean; inKey: boolean; order: number }>();
  const add = (list: Hit[], which: 'sem' | 'key') => {
    list.forEach((hit, i) => {
      if (!hit || typeof hit.id !== 'string') return;
      const w = 1 / (c + i + 1);
      const cur = by.get(hit.id);
      if (!cur) { by.set(hit.id, { hit: { ...hit }, score: w, inSem: which === 'sem', inKey: which === 'key', order: by.size }); return; }
      // the same list can list an id twice; count it once
      if ((which === 'sem' && cur.inSem) || (which === 'key' && cur.inKey)) return;
      cur.score += w;
      if (which === 'sem') { cur.inSem = true; cur.hit = { ...cur.hit, ...hit }; }
      else { cur.inKey = true; for (const [f, v] of Object.entries(hit)) if (cur.hit[f] === undefined || cur.hit[f] === null) cur.hit[f] = v; }
    });
  };
  add(semantic, 'sem');
  add(keyword, 'key');
  const sim = (h: Hit) => (typeof h.similarity === 'number' ? h.similarity : -1);
  return Array.from(by.values())
    .sort((a, b) => b.score - a.score || sim(b.hit) - sim(a.hit) || a.order - b.order)
    .slice(0, Math.max(0, k))
    .map(({ hit, score, inSem, inKey }) => ({ ...hit, match: inSem && inKey ? 'both' : inSem ? 'semantic' : 'keyword', score: Math.round(score * 1e6) / 1e6 }));
}

/** Build the one-line citation every result carries. Missing parts are left out rather than printed as "undefined". */
export function citation(r: { title?: unknown; source?: unknown; licence?: unknown; url?: unknown }): string {
  const title = String(r.title ?? '').trim() || 'Untitled';
  const inside = [r.source, r.licence].map(x => String(x ?? '').trim()).filter(Boolean).join(', ');
  return `${title}${inside ? ` (${inside})` : ''}.${r.url ? ' ' + String(r.url) : ''}`;
}

/**
 * A looser keyword query for when the strict one finds nothing. olo_search_text
 * uses websearch_to_tsquery, which ANDs every word, so "when was project
 * gutenberg founded" needs an atom that contains "found" as well as the name.
 * This keeps the content words (letters or digits, 3+ characters, not in a
 * small stop list) and joins them with "or", which websearch_to_tsquery
 * understands. Returns '' when fewer than two content words remain, so a
 * single word is never retried (the strict query already covered it).
 */
const STOP = new Set(['the', 'and', 'for', 'are', 'was', 'were', 'what', 'when', 'where', 'who', 'why', 'how', 'does', 'did', 'this', 'that', 'with', 'from', 'into', 'about', 'which', 'there', 'their', 'have', 'has', 'had', 'been', 'being', 'can', 'could', 'would', 'should', 'made', 'make', 'many', 'much', 'some', 'any', 'all', 'not', 'but', 'you', 'your', 'its', 'our', 'one', 'two']);
export function looseQuery(q: string): string {
  const words = q.toLowerCase().match(/[\p{L}\p{N}]{3,}/gu) || [];
  const keep = [...new Set(words.filter(w => !STOP.has(w)))];
  return keep.length >= 2 ? keep.join(' or ') : '';
}

// ---------------------------------------------------------------------------
// Reranking for multi-word questions.
//
// Fusion alone only knows positions. For a question like "how do coral reefs
// recover after bleaching" that leaves three gaps: the gte-small cosine order
// is nearly flat, so an abstract about coral in general can sit above the one
// about recovery; the loose keyword retry (looseQuery, words ORed) is ordered
// by ts_rank, which lets one frequent word ("coral" five times) beat an atom
// that names every word once; and mirrors of the same record take several of
// the k places. rank() fuses as before, then rescores the whole candidate pool
// with cheap lexical signals taken from the title and summary (the same text
// the keyword index covers) and demotes near duplicates:
//
//   coverage    share of the distinct query terms the atom contains, each term
//               weighted by how rare it is in the pool and counted once (so
//               repeating one word earns nothing), a title hit worth more than
//               a summary hit
//   proximity   neighbouring query terms that stand next to each other (or
//               close) in the atom, a cheap phrase match
//   fusion      the reciprocal rank fusion score, normalised to the best one,
//               so the meaning retriever still decides when words do not
//   credibility a small nudge from the atom's 0..100 credibility (50 if unknown)
//
// Everything is pure and linear in the pool size (at most about 60 atoms).
// ---------------------------------------------------------------------------

/** Words that carry no topic in a question. A superset of STOP, including short ones. */
const RANK_STOP = new Set([...STOP, 'is', 'a', 'an', 'of', 'in', 'on', 'to', 'at', 'by', 'as', 'be', 'it', 'or', 'do', 'i', 'we', 'me', 'my', 'so', 'if', 'no', 'up', 'us', 'he', 'she', 'they', 'them', 'his', 'her', 'than', 'then', 'also', 'such', 'these', 'those', 'will', 'may', 'might', 'tell', 'explain', 'describe', 'happen', 'happens', 'way', 'ways']);

/** Blend of the signals in rank(); they sum to 1. */
export const RANK_WEIGHTS = { fusion: 0.4, coverage: 0.45, proximity: 0.1, credibility: 0.05 };
/** A query term found only in the summary counts this much of a title hit. */
export const BODY_HIT = 0.6;

const SUFFIXES: [string, string][] = [['ations', ''], ['ation', ''], ['ings', ''], ['ing', ''], ['ies', 'y'], ['ied', 'y'], ['ed', ''], ['ly', '']];

/**
 * A light English stemmer: strips one common inflection so "founded",
 * "founding" and "found" meet, "reefs" meets "reef", "cities" meets "city",
 * and "caused", "causes" and "cause" all become "caus" (a final e goes too).
 * Words of three letters or fewer and anything with a digit are left alone.
 * Not Porter; termMatches() adds a short prefix rule for the rest.
 */
export function stem(w: string): string {
  if (w.length <= 3 || /\d/.test(w)) return w;
  for (const [suf, rep] of SUFFIXES) {
    if (w.endsWith(suf) && w.length - suf.length + rep.length >= (rep ? 3 : 4)) return w.slice(0, w.length - suf.length) + rep;
  }
  let s = w;
  if (/(ss|sh|ch|x)es$/.test(s) && s.length >= 5) s = s.slice(0, -2);
  else if (s.endsWith('s') && !/(ss|us|is)$/.test(s)) s = s.slice(0, -1);
  if (s.endsWith('e') && s.length > 4) s = s.slice(0, -1);
  return s;
}

/** Lowercased, stemmed content words in order (stopwords and one-letter words removed). */
export function terms(text: unknown): string[] {
  const words = String(text ?? '').toLowerCase().match(/[\p{L}\p{N}]+/gu) || [];
  return words.filter(w => w.length >= 2 && !RANK_STOP.has(w)).map(stem);
}

/** The distinct query terms in the order they were asked. */
export function queryTerms(q: string): string[] {
  return [...new Set(terms(q))];
}

/**
 * Whether a document term satisfies a query term: equal stems, or (for stems
 * of five letters or more) one is a prefix of the other within two letters,
 * so "recover" meets "recovery" and "vaccin" meets "vaccine".
 */
export function termMatches(queryTerm: string, docTerm: string): boolean {
  if (queryTerm === docTerm) return true;
  const [a, b] = queryTerm.length <= docTerm.length ? [queryTerm, docTerm] : [docTerm, queryTerm];
  return a.length >= 5 && b.length - a.length <= 2 && b.startsWith(a);
}

type Doc = { title: string[]; body: string[] };
const docOf = (h: Hit): Doc => ({ title: terms(h.title), body: terms(h.summary) });
const has = (list: string[], t: string) => list.some(d => termMatches(t, d));

/** How strongly a document contains a term: 1 in the title, BODY_HIT in the summary only, 0 otherwise. */
export function hitStrength(doc: Doc, t: string): number {
  return has(doc.title, t) ? 1 : has(doc.body, t) ? BODY_HIT : 0;
}

/**
 * Inverse document frequency of each term over the candidate pool, smoothed so
 * a term every atom has still weighs a little: ln(1 + N / (1 + df)).
 */
export function poolIdf(qterms: string[], docs: Doc[]): number[] {
  const n = docs.length;
  return qterms.map(t => Math.log(1 + n / (1 + docs.filter(d => has(d.title, t) || has(d.body, t)).length)));
}

/** Weighted share of distinct query terms the document holds, 0..1. Each term counts once however often it appears. */
export function coverage(doc: Doc, qterms: string[], idf: number[]): number {
  const total = idf.reduce((s, w) => s + w, 0);
  if (!qterms.length || total <= 0) return 0;
  return qterms.reduce((s, t, i) => s + idf[i] * hitStrength(doc, t), 0) / total;
}

/**
 * Phrase and proximity: for each pair of neighbouring query terms, 1 when they
 * stand next to each other in the asked order in the title or the summary,
 * 0.5 when they are within three words of each other in either order, else 0.
 * The mean over pairs, 0..1; 0 for a one-term question.
 */
export function proximity(doc: Doc, qterms: string[]): number {
  if (qterms.length < 2) return 0;
  const pos = (field: string[], t: string) => field.flatMap((d, i) => (termMatches(t, d) ? [i] : []));
  let sum = 0;
  for (let i = 0; i + 1 < qterms.length; i++) {
    let best = 0;
    for (const field of [doc.title, doc.body]) {
      const pa = pos(field, qterms[i]), pb = pos(field, qterms[i + 1]);
      for (const x of pa) for (const y of pb) {
        if (y - x === 1) best = 1;
        else if (Math.abs(y - x) <= 3 && x !== y) best = Math.max(best, 0.5);
      }
    }
    sum += best;
  }
  return sum / (qterms.length - 1);
}

/** Share of words two lists have in common (Jaccard), 1 when both are empty. */
function jaccard(a: string[], b: string[]): number {
  const A = new Set(a), B = new Set(b);
  if (!A.size && !B.size) return 1;
  let both = 0;
  for (const x of A) if (B.has(x)) both++;
  return both / (A.size + B.size - both);
}

/**
 * Move near duplicates behind everything else, keeping the first (best) copy
 * in place. Two atoms are near duplicates when they share a url, or when their
 * titles have the same words and their summaries overlap by at least 60
 * percent (a mirror, a re-ingest under a new id, a second revision). The order
 * within each group is kept, so duplicates still fill the list when nothing
 * else is left.
 */
export function demoteDuplicates<T extends Hit>(list: T[]): T[] {
  const kept: { t: T; title: string; body: string[]; url: string }[] = [], dup: T[] = [];
  for (const t of list) {
    const title = terms(t.title).join(' '), body = terms(t.summary), url = String(t.url ?? '').trim();
    const same = kept.some(k => (url && k.url === url) || (title && k.title === title && jaccard(k.body, body) >= 0.6));
    if (same) dup.push(t); else kept.push({ t, title, body, url });
  }
  return [...kept.map(k => k.t), ...dup];
}

/**
 * The full ranking used by olo-query and olo-answer: fuse both retrievers over
 * their whole lists, rescore every candidate with the blend in RANK_WEIGHTS,
 * demote near duplicates and keep the best `k`. `score` on each result is the
 * blended score (0..1); `match` says which retrievers found it, as with fuse().
 * A question with no content words keeps the fusion order (duplicates still
 * demoted). Ties keep the fusion order, so the result is deterministic.
 */
export function rank(q: string, semantic: Hit[], keyword: Hit[], k: number, w = RANK_WEIGHTS): Fused[] {
  const pool = fuse(semantic, keyword, Infinity);
  const qterms = queryTerms(q);
  if (!pool.length) return [];
  const docs = pool.map(docOf);
  const idf = poolIdf(qterms, docs);
  const top = Math.max(...pool.map(p => p.score)) || 1;
  const scored = pool.map((p, i) => {
    const cred = typeof p.credibility === 'number' ? Math.min(100, Math.max(0, p.credibility)) : 50;
    const s = qterms.length
      ? w.fusion * (p.score / top) + w.coverage * coverage(docs[i], qterms, idf) + w.proximity * proximity(docs[i], qterms) + w.credibility * (cred / 100)
      : p.score / top;
    return { p, s, i };
  });
  scored.sort((a, b) => b.s - a.s || a.i - b.i);
  return demoteDuplicates(scored.map(({ p, s }) => ({ ...p, score: Math.round(s * 1e6) / 1e6 }))).slice(0, Math.max(0, k));
}

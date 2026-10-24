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

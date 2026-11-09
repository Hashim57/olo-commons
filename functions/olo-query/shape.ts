// The shape of one search result in the olo-query response. Pure, no I/O, so
// `deno test tests/` covers it without the network. index.ts does the search.
//
// Since sql/002 the two search RPCs (olo_match, olo_search_text) return each
// atom's trust and time fields, and olo-answer has passed them on with every
// passage, but olo-query dropped them when it shaped its results: a caller of
// the read API could not tell a verified atom from a candidate, or see when a
// fact was last observed, without a second call to olo_atom per result. They
// are added here beside the fields that were already returned, so an existing
// caller sees nothing change and a new one can show the trust line.

import { citation } from './rank.ts';

const STATUSES = ['candidate', 'verified', 'disputed', 'superseded', 'retracted'];

/** A whole number from 0 to 100, or null when the value is missing or not a number. */
function score(v: unknown): number | null {
  return typeof v === 'number' && isFinite(v) ? Math.min(100, Math.max(0, Math.round(v))) : null;
}

/** A non-empty string, or null. */
function text(v: unknown): string | null {
  return typeof v === 'string' && v.trim() ? v : null;
}

/**
 * One ranked hit -> the public result. The first block is the shape the API has
 * always returned; the second is docs/TRUST.md: `status` (candidate, verified
 * or disputed; retracted and superseded atoms are never returned by the search),
 * `credibility` (0 to 100), `corroboration` (how many other independent sources
 * agree), `valid_from` and `valid_to` (when the fact holds), `observed_at`
 * (when the source was last seen to say this), `source_revision` and
 * `source_kind`. Each is null when the database has not been migrated to
 * sql/002 or the value is unknown, never a guess.
 */
export function resultOf(r: any) {
  return {
    id: r.id, title: r.title, summary: r.summary, content: r.content || null, url: r.url, source: r.source, source_slug: r.source_slug, licence: r.licence,
    published_at: r.published_at || null, retrieved_at: r.retrieved_at, similarity: typeof r.similarity === 'number' ? r.similarity : null, match: r.match, citation: citation(r),
    status: STATUSES.includes(r.status) ? r.status as string : null,
    credibility: score(r.credibility),
    corroboration: typeof r.corroboration === 'number' && isFinite(r.corroboration) ? Math.max(0, Math.round(r.corroboration)) : null,
    valid_from: text(r.valid_from), valid_to: text(r.valid_to), observed_at: text(r.observed_at),
    source_revision: text(r.source_revision), source_kind: text(r.source_kind),
  };
}

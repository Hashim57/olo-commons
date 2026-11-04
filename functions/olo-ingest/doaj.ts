// DOAJ (Directory of Open Access Journals) article search -> Commons candidates.
// Pure functions, no I/O, so they can be unit tested with `deno test tests/`
// without the network.
//
// DOAJ lists only peer-reviewed, fully open-access journals, and indexes their
// articles with abstracts. The public search API needs no key:
// https://doaj.org/api/search/articles/{query}?page=&pageSize= (pageSize at most
// 100, and page * pageSize at most 1000), returning `{ total, page, pageSize,
// results: [{ id, bibjson: { title, abstract, author, year, month, identifier,
// link, journal, keywords } }] }`. Docs: https://doaj.org/api/docs
// DOAJ asks for no more than 2 requests a second; one call a run is far below it.
//
// DOAJ's own metadata is CC BY-SA 4.0; the abstract stays under the open-access
// licence of the article, which DOAJ requires every listed journal to state.

import { clean } from './text.ts';
import { bareDoi } from './sources.ts';

export type DoajCandidate = { external_id?: string; url: string; title: string; summary?: string; content?: string; authors?: string[]; published_at?: string; licence?: string; lang?: string; doi?: string };

export const DOAJ_API = 'https://doaj.org/api';
export const DOAJ_SITE = 'https://doaj.org';
export const DOAJ_LICENCE = "DOAJ metadata CC BY-SA 4.0; abstract under the article's open-access licence";

/**
 * Map one article record to a candidate, or null when it should be skipped: no
 * id, no title, or an abstract too short to say anything. The URL is the DOI when
 * the article has one (the retraction check matches on it), otherwise DOAJ's own
 * article page, which is stable for the record's id.
 */
export function doajCandidate(rec: any): DoajCandidate | null {
  if (!rec || typeof rec !== 'object') return null;
  const id = String(rec.id || '');
  const b = rec.bibjson || {};
  if (!/^[a-f0-9]{16,64}$/i.test(id)) return null;
  const title = clean(b.title).slice(0, 300);
  const abs = clean(b.abstract);
  if (!title || abs.length < 150) return null;
  const ids: any[] = Array.isArray(b.identifier) ? b.identifier : [];
  const doi = bareDoi(ids.find((x) => String(x?.type || '').toLowerCase() === 'doi')?.id);
  const authors = (Array.isArray(b.author) ? b.author : []).map((a: any) => clean(a?.name)).filter(Boolean).slice(0, 8);
  const journal = clean(b.journal?.title);
  const publisher = clean(b.journal?.publisher);
  const kw = (Array.isArray(b.keywords) ? b.keywords : []).map((k: any) => clean(String(k))).filter(Boolean).slice(0, 8);
  const year = String(b.year || ''), month = String(b.month || '');
  const mm = /^\d{1,2}$/.test(month) && Number(month) >= 1 && Number(month) <= 12 ? month.padStart(2, '0') : '01';
  const langs: string[] = (Array.isArray(b.journal?.language) ? b.journal.language : []).map((l: any) => String(l).toLowerCase());
  return {
    external_id: id,
    url: doi ? `https://doi.org/${doi}` : `${DOAJ_SITE}/article/${id}`,
    title,
    summary: abs.slice(0, 600),
    content: abs + (journal ? ` Published in ${journal}${publisher ? ` (${publisher})` : ''}.` : '') + (kw.length ? ` Keywords: ${kw.join('; ')}.` : ''),
    authors: authors.length ? authors : undefined,
    published_at: /^\d{4}$/.test(year) && Number(year) <= new Date().getUTCFullYear() ? `${year}-${mm}-01` : undefined,
    licence: DOAJ_LICENCE,
    // Only when the journal publishes in one language; a bilingual journal's abstract is usually English.
    lang: langs.length === 1 && /^[a-z]{2}$/.test(langs[0]) ? langs[0] : undefined,
    doi,
  };
}

/** Map a search response (`{ results: [...] }`) and keep at most n. */
export function doajCandidates(response: any, n: number): DoajCandidate[] {
  const rows: any[] = Array.isArray(response?.results) ? response.results : [];
  const out: DoajCandidate[] = [];
  for (const r of rows) { const c = doajCandidate(r); if (c) out.push(c); if (out.length >= n) break; }
  return out;
}

// Topics to search, one picked at random per run, across the subjects DOAJ covers.
export const DOAJ_TOPICS = [
  'climate change', 'public health', 'education', 'agriculture', 'water', 'renewable energy', 'linguistics',
  'history', 'economics', 'ecology', 'nutrition', 'mathematics', 'machine learning', 'materials', 'oceanography',
  'archaeology', 'psychology', 'urban planning', 'infectious disease', 'philosophy', 'veterinary', 'geology',
  'sociology', 'law', 'astronomy', 'pharmacology', 'biodiversity', 'music',
];

/** The search URL for one page; the API refuses page * pageSize above 1000, so the page is clamped. */
export function doajSearchUrl(api: string, query: string, pageSize: number, page: number): string {
  const base = (api || DOAJ_API).replace(/\/+$/, '');
  const size = Math.max(1, Math.min(pageSize, 100));
  const p = Math.max(1, Math.min(page, Math.floor(1000 / size)));
  return `${base}/search/articles/${encodeURIComponent(query || '*')}?page=${p}&pageSize=${size}`;
}

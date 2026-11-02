// Europeana Search API -> Commons candidates. Pure functions, no I/O, so they
// can be unit tested with `deno test tests/` without the network.
//
// Europeana aggregates records from European museums, libraries and archives.
// Search API: https://api.europeana.eu/record/v2/search.json, with a key in the
// `wskey` parameter (EUROPEANA_KEY secret; Europeana's public demo key api2demo
// otherwise). `reusability=open` asks only for records under PDM, CC0, CC BY or
// CC BY-SA; the rights URL is checked again here, per record, so a record under a
// non-commercial, no-derivatives or in-copyright statement is never kept.
// Docs: https://europeana.atlassian.net/wiki/spaces/EF/pages/2385739812/Search+API+Documentation
//
// The basic pagination stops at start + rows = 1000, so a run picks a random
// topic and a random window inside it rather than one deep offset.

import { clean } from './text.ts';

export type EuropeanaCandidate = { external_id?: string; url: string; title: string; summary?: string; content?: string; authors?: string[]; published_at?: string; licence?: string; lang?: string };

export const EUROPEANA_API = 'https://api.europeana.eu/record/v2';
export const EUROPEANA_SITE = 'https://www.europeana.eu';
export const EUROPEANA_DEMO_KEY = 'api2demo';

// Rights statement URLs that allow reuse with at most attribution or share-alike,
// matched with the scheme, "www." and any trailing slash removed.
const OPEN_RIGHTS: Array<[RegExp, (m: RegExpMatchArray) => string]> = [
  [/^creativecommons\.org\/publicdomain\/mark\/1\.0$/, () => 'Public Domain Mark 1.0'],
  [/^creativecommons\.org\/publicdomain\/zero\/1\.0$/, () => 'CC0 1.0'],
  [/^creativecommons\.org\/licenses\/by\/(\d\.\d)$/, (m) => `CC BY ${m[1]}`],
  [/^creativecommons\.org\/licenses\/by-sa\/(\d\.\d)$/, (m) => `CC BY-SA ${m[1]}`],
];

function normaliseUrl(u: string): string {
  return u.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/^www\./, '').replace(/\/+$/, '');
}

/** The licence to store for a Europeana rights URL, or null when the record may not be passed on. */
export function europeanaLicence(rights: unknown): string | null {
  const raw = Array.isArray(rights) ? rights[0] : rights;
  if (typeof raw !== 'string' || !raw) return null;
  const n = normaliseUrl(raw);
  for (const [re, name] of OPEN_RIGHTS) { const m = n.match(re); if (m) return name(m); }
  return null;
}

const first = (v: unknown): string => Array.isArray(v) ? String(v[0] ?? '') : (typeof v === 'string' ? v : '');

/**
 * Map one search item (profile=rich) to a candidate, or null when it should be
 * skipped: no id, no title, a description too short to say anything, or rights
 * that are not open. The URL is built from the record id, never from `guid`,
 * which carries the API key in its tracking parameters.
 */
export function europeanaCandidate(item: any): EuropeanaCandidate | null {
  if (!item || typeof item !== 'object') return null;
  const id = String(item.id || '');
  if (!/^\/[A-Za-z0-9_]+\/[A-Za-z0-9_.\-]+$/.test(id)) return null;
  const licence = europeanaLicence(item.rights); if (!licence) return null;
  const title = clean(first(item.title)).slice(0, 200);
  // dcDescription holds the descriptions in the record's own languages; some records give only the language-aware map.
  const rawDescs = item.dcDescription ?? Object.values(item.dcDescriptionLangAware || {}).flat();
  const descs: string[] = (Array.isArray(rawDescs) ? rawDescs : [rawDescs]).map((d: unknown) => clean(String(d ?? ''))).filter(Boolean);
  const text = Array.from(new Set(descs)).join(' ');
  if (!title || text.length < 100) return null;
  const provider = clean(first(item.dataProvider));
  const creators = (Array.isArray(item.dcCreator) ? item.dcCreator : []).map((c: unknown) => clean(String(c ?? ''))).filter((c: string) => c && !/^https?:/.test(c)).slice(0, 8);
  const year = first(item.year);
  const lang = first(item.language).toLowerCase();
  return {
    external_id: id.slice(1),
    url: `${EUROPEANA_SITE}/item${id}`,
    title,
    summary: text.slice(0, 600),
    content: text + (provider ? ` Held by ${provider}.` : ''),
    authors: creators.length ? creators : undefined,
    published_at: /^\d{4}$/.test(year) && Number(year) <= new Date().getUTCFullYear() ? `${year}-01-01` : undefined,
    licence,
    lang: /^[a-z]{2}$/.test(lang) ? lang : undefined,
  };
}

/** Map a search response (`{ items: [...] }`) and keep at most n. */
export function europeanaCandidates(response: any, n: number): EuropeanaCandidate[] {
  const items: any[] = Array.isArray(response?.items) ? response.items : [];
  const out: EuropeanaCandidate[] = [];
  for (const i of items) { const c = europeanaCandidate(i); if (c) out.push(c); if (out.length >= n) break; }
  return out;
}

// Topics to search, one picked at random per run, so the Commons gets a spread
// of collections rather than the same top results every time.
export const EUROPEANA_TOPICS = [
  'painting', 'manuscript', 'map', 'photograph', 'sculpture', 'archaeology', 'music', 'architecture', 'textile',
  'botany', 'zoology', 'coin', 'letter', 'poster', 'ceramics', 'cathedral', 'castle', 'portrait', 'ship',
  'railway', 'astronomy', 'medicine', 'folk costume', 'printing', 'bridge', 'industry', 'agriculture', 'theatre',
];

/** The search URL for one window: `start` is 1-based and start + rows stays within the 1000-record limit. */
export function europeanaSearchUrl(api: string, key: string, query: string, rows: number, start: number): string {
  const base = (api || EUROPEANA_API).replace(/\/+$/, '');
  const r = Math.max(1, Math.min(rows, 100));
  const s = Math.max(1, Math.min(start, 1000 - r));
  return `${base}/search.json?wskey=${encodeURIComponent(key || EUROPEANA_DEMO_KEY)}&query=${encodeURIComponent(query || '*')}&reusability=open&profile=rich&rows=${r}&start=${s}`;
}

/** An error message with the wskey value replaced, so a failed call never writes the key into the run note. */
export function redactKey(message: string): string {
  return String(message).replace(/([?&]wskey=)[^&\s]*/gi, '$1***');
}

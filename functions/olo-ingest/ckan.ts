// CKAN package_search results -> Commons candidates. Pure functions, no I/O, so
// they can be unit tested with `deno test tests/` without the network.
//
// CKAN is the open-data catalogue software behind data.gov, data.gov.uk,
// data.europa.eu and many city and national portals, so one mapper serves all
// of them. Only dataset descriptions are taken (title, notes, publisher,
// licence), never the data files themselves.

import { clean } from './text.ts';

export type CkanCandidate = { external_id?: string; url: string; title: string; summary?: string; content?: string; authors?: string[]; published_at?: string; licence?: string; lang?: string };

// Licence ids that allow redistribution with at most attribution or share-alike.
// Anything else (missing, 'notspecified', 'other-closed', custom terms) is dropped,
// because the Commons only keeps what it may pass on.
export const OPEN_LICENCES: Record<string, string> = {
  'us-pd': 'Public domain (U.S. Government Work)',
  'other-pd': 'Public domain',
  'cc-zero': 'CC0 1.0',
  'cc0-1.0': 'CC0 1.0',
  'odc-pddl': 'ODC Public Domain Dedication and Licence',
  'cc-by': 'CC BY 4.0',
  'cc-by-4.0': 'CC BY 4.0',
  'cc-by-sa': 'CC BY-SA 4.0',
  'cc-by-sa-4.0': 'CC BY-SA 4.0',
  'odc-by': 'ODC Attribution Licence',
  'odc-odbl': 'ODC Open Database Licence',
  'uk-ogl': 'Open Government Licence v3.0',
  'ogl-uk-3.0': 'Open Government Licence v3.0',
};

/** The licence string to store for a CKAN package, or null when it is not open enough to keep. */
export function ckanLicence(pkg: any): string | null {
  const id = String(pkg?.license_id ?? '').trim().toLowerCase();
  return OPEN_LICENCES[id] ?? null;
}

/**
 * Map one CKAN package to a candidate, or null when it should be skipped:
 * no title, notes too short to say anything, a licence that is not open, or a
 * name that cannot make a stable https URL.
 */
export function ckanCandidate(pkg: any, site: string): CkanCandidate | null {
  if (!pkg || typeof pkg !== 'object') return null;
  const licence = ckanLicence(pkg); if (!licence) return null;
  const title = clean(pkg.title).slice(0, 200);
  const notes = clean(pkg.notes);
  const name = String(pkg.name ?? '');
  if (!title || notes.length < 120 || !/^[a-z0-9_-]{2,200}$/.test(name)) return null;
  const base = site.replace(/\/+$/, '');
  if (!/^https:\/\//.test(base)) return null;
  const publisher = clean(pkg.organization?.title || pkg.author || '');
  const tags = Array.isArray(pkg.tags) ? pkg.tags.map((t: any) => clean(t?.display_name || t?.name)).filter(Boolean).slice(0, 8) : [];
  const issued = String(pkg.metadata_created || pkg.issued || '');
  return {
    external_id: String(pkg.id || name),
    url: `${base}/dataset/${name}`,
    title,
    summary: (publisher ? `Dataset published by ${publisher}. ` : 'Dataset. ') + notes.slice(0, 520),
    content: notes + (tags.length ? ` Keywords: ${tags.join('; ')}.` : ''),
    authors: publisher ? [publisher] : undefined,
    published_at: /^\d{4}-\d{2}-\d{2}/.test(issued) ? issued.slice(0, 10) : undefined,
    licence,
    lang: 'en',
  };
}

/** Map a whole package_search response (`{ result: { results: [...] } }`) and keep at most n. */
export function ckanCandidates(response: any, site: string, n: number): CkanCandidate[] {
  const rows: any[] = response?.result?.results || [];
  const out: CkanCandidate[] = [];
  for (const p of rows) { const c = ckanCandidate(p, site); if (c) out.push(c); if (out.length >= n) break; }
  return out;
}

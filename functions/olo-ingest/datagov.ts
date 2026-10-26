// Data.gov catalogue API v4 -> Commons candidates. Pure functions, no I/O, so
// they can be unit tested with `deno test tests/` without the network.
//
// In 2026 catalog.data.gov stopped being a CKAN portal: every /api/3/action/*
// call (and catalog-old.data.gov, and the api.gsa.gov v3 gateway) now ends in a
// 404, which is why the data_gov source never added an atom. The replacement is
// https://api.gsa.gov/technology/datagov/v4/search, an OpenSearch API that needs
// an api.data.gov key (X-Api-Key; DEMO_KEY allows 30 requests an hour per IP,
// enough for one call every 15 minutes) and returns DCAT-US metadata.
// Docs: https://resources.data.gov/catalog-api/
//
// The search has no licence filter, so the licence is checked here, per result.

import { clean } from './text.ts';

export type DataGovCandidate = { external_id?: string; url: string; title: string; summary?: string; content?: string; authors?: string[]; published_at?: string; licence?: string; lang?: string };

export const DATAGOV_API = 'https://api.gsa.gov/technology/datagov/v4';
export const DATAGOV_SITE = 'https://catalog.data.gov';

// Licence URLs (DCAT-US `license`) that allow redistribution with at most
// attribution or share-alike. Matched on the URL with the scheme, "www." and any
// trailing slash removed, so http/https and small spelling differences agree.
const OPEN_LICENCE_URLS: Array<[RegExp, string]> = [
  [/^creativecommons\.org\/publicdomain\/zero\/1\.0/, 'CC0 1.0'],
  [/^creativecommons\.org\/publicdomain\/mark\/1\.0/, 'Public domain'],
  [/^creativecommons\.org\/licenses\/by\/(4\.0|3\.0)/, 'CC BY'],
  [/^creativecommons\.org\/licenses\/by-sa\/(4\.0|3\.0)/, 'CC BY-SA'],
  [/^opendatacommons\.org\/licenses\/pddl/, 'ODC Public Domain Dedication and Licence'],
  [/^opendatacommons\.org\/licenses\/by/, 'ODC Attribution Licence'],
  [/^opendatacommons\.org\/licenses\/odbl/, 'ODC Open Database Licence'],
  [/^usa\.gov\/(government-works|publicdomain|government-copyright)/, 'Public domain (U.S. Government Work)'],
  [/^usa\.gov\/publicdomain\/label\/1\.0/, 'Public domain (U.S. Government Work)'],
  [/^nationalarchives\.gov\.uk\/doc\/open-government-licence/, 'Open Government Licence'],
];

function normaliseUrl(u: string): string {
  return u.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/^www\./, '').replace(/\/+$/, '');
}

/**
 * The licence string to store, or null when the dataset may not be passed on.
 * A listed open licence URL is kept. With no licence at all, a dataset from a
 * federal agency is a U.S. Government Work, which has no copyright in the United
 * States (17 U.S.C. 105), so it is kept as public domain; anything else without a
 * licence, or with an unknown or custom licence, is dropped.
 */
export function dataGovLicence(row: any): string | null {
  const dcat = row?.dcat || {};
  const raw = typeof dcat.license === 'string' ? dcat.license : '';
  if (raw) {
    const n = normaliseUrl(raw);
    for (const [re, name] of OPEN_LICENCE_URLS) if (re.test(n)) return name;
    return null;
  }
  const orgType = String(row?.organization?.organization_type || '').toLowerCase();
  if (orgType === 'federal government') return 'Public domain (U.S. Government Work, 17 U.S.C. 105)';
  return null;
}

/**
 * Map one v4 search result to a candidate, or null when it should be skipped:
 * not public, no title, a description too short to say anything, a licence that
 * is not open, or no slug to make a stable catalogue URL.
 */
export function dataGovCandidate(row: any): DataGovCandidate | null {
  if (!row || typeof row !== 'object') return null;
  const dcat = row.dcat || {};
  const access = String(dcat.accessLevel || 'public').toLowerCase();
  if (access !== 'public') return null;
  const licence = dataGovLicence(row); if (!licence) return null;
  const title = clean(row.title || dcat.title).slice(0, 200);
  const notes = clean(row.description || dcat.description);
  const slug = String(row.slug || '');
  if (!title || notes.length < 120 || !/^[a-z0-9_-]{2,200}$/i.test(slug)) return null;
  const publisher = clean(row.publisher || dcat.publisher?.name || row.organization?.name || '');
  const kw = Array.isArray(row.keyword) ? row.keyword : (Array.isArray(dcat.keyword) ? dcat.keyword : []);
  const tags = kw.map((t: any) => clean(String(t))).filter(Boolean).slice(0, 8);
  const issued = String(dcat.issued || dcat.modified || '');
  return {
    external_id: String(row.identifier || dcat.identifier || slug),
    url: `${DATAGOV_SITE}/dataset/${slug}`,
    title,
    summary: (publisher ? `Dataset published by ${publisher}. ` : 'Dataset. ') + notes.slice(0, 520),
    content: notes + (tags.length ? ` Keywords: ${tags.join('; ')}.` : ''),
    authors: publisher ? [publisher] : undefined,
    published_at: /^\d{4}-\d{2}-\d{2}/.test(issued) ? issued.slice(0, 10) : undefined,
    licence,
    lang: 'en',
  };
}

/** Map a v4 search response (`{ results: [...], after }`) and keep at most n. */
export function dataGovCandidates(response: any, n: number): DataGovCandidate[] {
  const rows: any[] = Array.isArray(response?.results) ? response.results : [];
  const out: DataGovCandidate[] = [];
  for (const r of rows) { const c = dataGovCandidate(r); if (c) out.push(c); if (out.length >= n) break; }
  return out;
}

// Topics to search, one picked at random per run, so the Commons gets a spread of
// public datasets rather than the same first page every time (the v4 search has
// cursors but no random offset).
export const DATAGOV_TOPICS = [
  'climate', 'water quality', 'air quality', 'energy', 'agriculture', 'health', 'education', 'transportation',
  'census', 'labor', 'housing', 'ocean', 'wildfire', 'earthquake', 'public safety', 'economy', 'budget',
  'biodiversity', 'forest', 'drought', 'flood', 'vaccination', 'broadband', 'small business', 'veterans',
  'nutrition', 'pollution', 'solar', 'geology', 'satellite', 'drinking water', 'hospitals', 'crime', 'weather',
];

/** The search URL for one run: a random topic, federal and other public publishers alike. */
export function dataGovSearchUrl(api: string, topic: string, perPage: number): string {
  const base = (api || DATAGOV_API).replace(/\/+$/, '');
  return `${base}/search?q=${encodeURIComponent(topic)}&per_page=${Math.max(1, Math.min(perPage, 50))}&sort=relevance`;
}

/** The registry may still hold the dead CKAN base; anything that is not a v4 base is replaced. */
export function dataGovApiBase(registered: string | null | undefined): string {
  const r = String(registered || '').trim();
  return /\/datagov\/v4\/?$/.test(r) ? r.replace(/\/+$/, '') : DATAGOV_API;
}

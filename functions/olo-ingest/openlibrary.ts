// Open Library search API -> Commons candidates. Pure functions, no I/O, so they
// can be unit tested with `deno test tests/` without the network.
//
// Licence. Open Library says its catalogue "was created by the generous donations
// of libraries who dedicated their data into the public domain" and asks that every
// contribution be given under CC0 1.0 (https://openlibrary.org/help/faq/using;
// Creative Commons case study: https://wiki.creativecommons.org/wiki/Case_Studies/Open_Library).
// That covers the catalogue facts: titles, author names, subjects, dates, edition
// counts. It does not reliably cover free text. Work descriptions are often pasted
// from publisher blurbs, jacket copy or Wikipedia, which an editor cannot dedicate
// to the public domain however the site labels it, and `first_sentence` is a quote
// from the book itself, often still in copyright. So this mapper reads catalogue
// fields only, never `description`, `first_sentence` or covers, and writes its own
// plain sentence from those facts. What the Commons stores is then CC0 data.
//
// Search API: https://openlibrary.org/dev/docs/api/search (one request per run,
// `fields` set explicitly as the maintainers ask since January 2025, and
// `sort=random.hourly` with a random page so repeated runs see different works).

import { clean } from './text.ts';
import type { Candidate } from './sources.ts';

export const OPENLIBRARY_API = 'https://openlibrary.org';
export const OPENLIBRARY_LICENCE = 'CC0 1.0 (Open Library catalogue data)';
export const OPENLIBRARY_FIELDS = 'key,title,author_name,first_publish_year,subject,language,edition_count';

// Subjects that describe the copy or a reading list, not what the book is about.
const NOISE = /^(accessible book|protected daisy|in library|lending library|open library staff picks|internet archive wishlist|overdrive|large type books|fiction, general|reading level.*|juvenile works|new york times bestseller|award winners?)$/i;

/** Up to 10 subjects that say what the work is about: cleaned, deduplicated, no tags such as `nyt:` or `collectionID:`. */
export function openLibrarySubjects(raw: unknown): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const s of Array.isArray(raw) ? raw : []) {
    const t = clean(String(s)).replace(/[.;,]+$/, '');
    if (!t || t.length > 80 || t.includes(':') || NOISE.test(t)) continue;
    const k = t.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k); out.push(t);
    if (out.length >= 10) break;
  }
  return out;
}

function joinNames(names: string[]): string {
  if (names.length <= 1) return names[0] || '';
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

/**
 * Map one search.json doc to a candidate, or null when it should be skipped: not a
 * work, no title, no author, or fewer than two topical subjects (too little to say).
 * The text is written here from catalogue facts only, never copied from a description.
 */
export function openLibraryCandidate(doc: any): Candidate | null {
  if (!doc || typeof doc !== 'object') return null;
  const key = String(doc.key || '');
  if (!/^\/works\/OL\d+W$/.test(key)) return null;
  const title = clean(doc.title).slice(0, 200);
  const authors = (Array.isArray(doc.author_name) ? doc.author_name : []).map((a: any) => clean(String(a))).filter(Boolean).slice(0, 6);
  const subjects = openLibrarySubjects(doc.subject);
  if (!title || !authors.length || subjects.length < 2) return null;
  const year = Number(doc.first_publish_year);
  const hasYear = Number.isInteger(year) && year > 0 && year <= new Date().getUTCFullYear();
  const editions = Number(doc.edition_count);
  const langs = Array.isArray(doc.language) ? doc.language.length : 0;
  const lead = `${title} is a book by ${joinNames(authors)}${hasYear ? `, first published in ${year}` : ''}.`;
  const about = ` Subjects: ${subjects.join('; ')}.`;
  const extra = Number.isInteger(editions) && editions > 0
    ? ` Open Library catalogues ${editions} edition${editions === 1 ? '' : 's'}${langs > 1 ? ` in ${langs} languages` : ''}.`
    : '';
  return {
    external_id: key.slice('/works/'.length),
    url: `https://openlibrary.org${key}`,
    title,
    summary: (lead + about).slice(0, 600),
    content: lead + about + extra,
    authors,
    // Only a year is known; a made-up day would claim more precision than the catalogue has.
    published_at: undefined,
    licence: OPENLIBRARY_LICENCE,
    // The atom text is the English sentence written above, whatever the book's language.
    lang: 'en',
  };
}

/** Map a search.json response (`{ docs: [...] }`) and keep at most n. */
export function openLibraryCandidates(response: any, n: number): Candidate[] {
  const docs: any[] = Array.isArray(response?.docs) ? response.docs : [];
  const out: Candidate[] = [];
  for (const d of docs) { const c = openLibraryCandidate(d); if (c) out.push(c); if (out.length >= n) break; }
  return out;
}

// Subjects to walk, one picked at random per run.
export const OPENLIBRARY_SUBJECTS = [
  'history', 'science', 'biology', 'chemistry', 'physics', 'mathematics', 'astronomy', 'medicine', 'philosophy',
  'economics', 'political science', 'sociology', 'psychology', 'anthropology', 'archaeology', 'geography',
  'linguistics', 'music', 'art', 'architecture', 'engineering', 'agriculture', 'ecology', 'geology',
  'religion', 'law', 'education', 'poetry', 'drama', 'biography', 'travel', 'natural history',
];

/** The API base from the registry when it is an https URL, otherwise the default. */
export function openLibraryApiBase(registered: string | null | undefined): string {
  const r = String(registered || '').trim().replace(/\/+$/, '');
  return /^https:\/\/[a-z0-9.-]+$/i.test(r) ? r : OPENLIBRARY_API;
}

/** Search URL for a subject walk: random hourly order, a page from 1 to 5, explicit fields. */
export function openLibrarySubjectUrl(api: string, subject: string, limit: number, page: number): string {
  const q = `subject:"${subject.replace(/"/g, '')}"`;
  return `${openLibraryApiBase(api)}/search.json?q=${encodeURIComponent(q)}&fields=${OPENLIBRARY_FIELDS}&sort=random.hourly&limit=${Math.max(1, Math.min(limit, 50))}&page=${Math.max(1, Math.min(Math.floor(page), 5))}`;
}

/** Search URL for gap filling: the topic words, best matches first. */
export function openLibrarySearchUrl(api: string, topic: string, limit: number): string {
  return `${openLibraryApiBase(api)}/search.json?q=${encodeURIComponent(clean(topic).slice(0, 200))}&fields=${OPENLIBRARY_FIELDS}&limit=${Math.max(1, Math.min(limit, 50))}`;
}

// Wikimedia Commons (MediaWiki API, File namespace) -> Commons candidates. Pure
// functions, no I/O, so `deno test tests/` covers them without the network.
//
// What an atom is. The caption a person wrote for a freely licensed file, with the
// file's title, author, date and licence, and the file page as its stable URL. The
// image itself is not stored; the atom links to it.
//
// Licences, two of them, both recorded:
// - The description text is wiki text on the file page, published by Wikimedia
//   under CC BY-SA 4.0 (https://commons.wikimedia.org/wiki/Commons:Licensing,
//   https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use). That is the text the
//   Commons stores, so the atom's licence starts with it.
// - The file's own licence comes from extmetadata.LicenseShortName. Commons only
//   hosts free files, but "free" there includes GFDL-only and a few odd licences;
//   this connector keeps a file only when its licence is CC0, public domain, CC BY
//   or CC BY-SA (any version), so a reuser following the link meets a licence the
//   Commons already deals with everywhere else.
//
// API: https://www.mediawiki.org/wiki/API:Imageinfo with iiprop=extmetadata
// (https://www.mediawiki.org/wiki/Extension:CommonsMetadata). The walk reads
// Category:Quality_images from a random point in time, because a uniformly random
// file is usually a camera filename with no caption; quality images are reviewed
// and nearly always described.

import { clean } from './text.ts';
import type { Candidate } from './sources.ts';

export const COMMONS_API = 'https://commons.wikimedia.org/w/api.php';
export const COMMONS_TEXT_LICENCE = 'CC BY-SA 4.0';
export const COMMONS_WALK_CATEGORY = 'Category:Quality_images';
const META_FIELDS = 'ImageDescription|ObjectName|Artist|LicenseShortName|DateTimeOriginal';

/** The extmetadata value as plain text ('' when absent). The values are HTML; clean() strips it. */
function meta(m: any, key: string): string {
  const v = m?.[key]?.value;
  return v == null ? '' : clean(String(v));
}

/**
 * The file licence in a canonical short form when it is one this connector keeps
 * (CC0, public domain, CC BY, CC BY-SA), otherwise null. NC and ND never reach
 * Commons, but GFDL-only, FAL and similar do, and those are dropped.
 */
export function commonsFileLicence(short: string): string | null {
  const s = clean(short).replace(/\s+/g, ' ').trim();
  if (!s) return null;
  if (/^cc[ -]?0\b|^cc zero\b/i.test(s)) return 'CC0 1.0';
  if (/^(public domain|pd\b|pd-)/i.test(s)) return 'Public domain';
  const m = s.match(/^cc[ -]by(-sa)?(?:[ -]([1-4]\.0|2\.5))?(?:[ -]([a-z]{2}))?$/i);
  if (m) return `CC BY${m[1] ? '-SA' : ''}${m[2] ? ' ' + m[2] : ''}`;
  return null;
}

/** "File:Some_name of a thing.jpg" -> "Some name of a thing" (the fallback title when ObjectName is missing). */
export function commonsTitleFromFile(title: string): string {
  return clean(String(title || '').replace(/^File:/i, '').replace(/\.[a-z0-9]{2,5}$/i, '').replace(/_/g, ' '));
}

// Captions that say nothing about the subject: upload boilerplate and camera names.
const BOILERPLATE = /^(own work|self[- ]made|uploaded (with|by|using)|transferred from|photo(graph)? (taken )?by|img[_ -]?\d|dsc[_ -]?\d|p\d{6,}|\d{8}[_ -])/i;

/**
 * Map one page of a prop=imageinfo response to a candidate, or null when it should
 * be skipped: not a file page, no image info, a licence outside CC0/PD/CC BY/CC BY-SA,
 * or a caption shorter than 60 characters or made of upload boilerplate.
 */
export function commonsCandidate(page: any): Candidate | null {
  if (!page || page.ns !== 6 || typeof page.title !== 'string' || page.missing !== undefined) return null;
  const info = Array.isArray(page.imageinfo) ? page.imageinfo[0] : null;
  const m = info?.extmetadata;
  if (!info || !m) return null;
  const fileLicence = commonsFileLicence(meta(m, 'LicenseShortName'));
  if (!fileLicence) return null;
  const desc = meta(m, 'ImageDescription').slice(0, 1500);
  if (desc.length < 60 || BOILERPLATE.test(desc)) return null;
  const title = (meta(m, 'ObjectName') || commonsTitleFromFile(page.title)).slice(0, 200);
  if (!title) return null;
  const artist = meta(m, 'Artist').slice(0, 120);
  const authors = artist && !/^unknown/i.test(artist) ? [artist] : undefined;
  const dateRaw = meta(m, 'DateTimeOriginal');
  const d = dateRaw.match(/^(\d{4})-(\d{2})-(\d{2})/);
  const published_at = d && +d[1] > 1800 && +d[1] <= new Date().getUTCFullYear() ? `${d[1]}-${d[2]}-${d[3]}` : undefined;
  const pageUrl = typeof info.descriptionurl === 'string' && /^https:\/\/commons\.wikimedia\.org\/wiki\//.test(info.descriptionurl)
    ? info.descriptionurl
    : `https://commons.wikimedia.org/wiki/${encodeURIComponent(page.title.replace(/ /g, '_')).replace(/%3A/g, ':')}`;
  const summary = /[.!?]$/.test(desc) ? desc : `${desc}.`;
  const tail = [authors ? `By ${authors[0]}` : '', published_at ? `taken ${published_at}` : '', `file licence ${fileLicence}`].filter(Boolean).join(', ');
  return {
    external_id: String(page.pageid ?? page.title),
    url: pageUrl,
    title,
    summary: summary.slice(0, 600),
    content: `${title}. ${summary} (${tail}.)`,
    authors,
    published_at,
    licence: `${COMMONS_TEXT_LICENCE} (description); file: ${fileLicence}`,
    // extmetadata is asked for in English; a file described only in another language
    // comes back in that language, so the mapper keeps those out rather than mislabel them.
    lang: 'en',
  };
}

/** True when the caption reads as English: mostly ASCII letters and at least two common English words. */
export function looksEnglish(s: string): boolean {
  const letters = (s.match(/\p{L}/gu) || []).length;
  if (!letters) return false;
  const ascii = (s.match(/[A-Za-z]/g) || []).length;
  if (ascii / letters < 0.9) return false;
  const words = new Set(s.toLowerCase().match(/[a-z]+/g) || []);
  let hits = 0;
  for (const w of ['the', 'of', 'and', 'in', 'a', 'on', 'at', 'with', 'from', 'view', 'is', 'to', 'by']) if (words.has(w)) hits++;
  return hits >= 2;
}

/** Map a query response (`{ query: { pages: {...} | [...] } }`) and keep at most n English candidates. */
export function commonsCandidates(response: any, n: number): Candidate[] {
  const raw = response?.query?.pages;
  const pages: any[] = Array.isArray(raw) ? raw : raw && typeof raw === 'object' ? Object.values(raw) : [];
  const out: Candidate[] = [];
  for (const p of pages) {
    const c = commonsCandidate(p);
    if (c && looksEnglish(c.summary || '')) out.push(c);
    if (out.length >= n) break;
  }
  return out;
}

/** The API endpoint from the registry when it is an https URL ending in api.php, otherwise the default. */
export function commonsApiBase(registered: string | null | undefined): string {
  const r = String(registered || '').trim();
  return /^https:\/\/[a-z0-9.-]+\/w\/api\.php$/i.test(r) ? r : COMMONS_API;
}

// The imageinfo part every request shares: page URL and the metadata fields, in English, formatversion 2.
const IMAGEINFO = `prop=imageinfo&iiprop=url|extmetadata&iiextmetadatafilter=${encodeURIComponent(META_FIELDS)}&iiextmetadatalanguage=en&format=json&formatversion=2&maxlag=5`;

/**
 * The walk: files in Category:Quality_images added after a given moment, oldest
 * first, so a random start gives a different window every run.
 */
export function commonsWalkUrl(api: string, start: Date, limit: number): string {
  const l = Math.max(1, Math.min(limit, 50));
  return `${commonsApiBase(api)}?action=query&generator=categorymembers&gcmtitle=${encodeURIComponent(COMMONS_WALK_CATEGORY)}&gcmtype=file&gcmsort=timestamp&gcmdir=newer&gcmstart=${start.toISOString().replace(/\.\d{3}Z$/, 'Z')}&gcmlimit=${l}&${IMAGEINFO}`;
}

/** A random start between 2008 (when quality images began to be reviewed in bulk) and a month ago. */
export function commonsWalkStart(rand: () => number = Math.random, now = Date.now()): Date {
  const from = Date.UTC(2008, 0, 1), to = now - 30 * 86400_000;
  return new Date(from + Math.floor(rand() * Math.max(1, to - from)));
}

/** Gap filling: full-text search over file pages for the topic words. */
export function commonsSearchUrl(api: string, topic: string, limit: number): string {
  const l = Math.max(1, Math.min(limit, 50));
  return `${commonsApiBase(api)}?action=query&generator=search&gsrnamespace=6&gsrsearch=${encodeURIComponent(clean(topic).slice(0, 200))}&gsrlimit=${l}&${IMAGEINFO}`;
}

// Europe PMC articles REST search -> Commons candidates. Pure functions, no I/O,
// so they can be unit tested with `deno test tests/` without the network.
//
// Licence. Europe PMC's open-access subset carries a licence per article, and the
// search API returns it as `license` (for example "cc by", "cc by-nc-nd") with
// `resultType=core`; `lite` results leave it out. The Commons only takes content
// that can be passed on with at most attribution or share-alike, so the query asks
// for OPEN_ACCESS:y and LICENSE "cc by", "cc0" or "cc by-sa", and this mapper
// checks the licence of every result again and drops anything else, including
// every NC or ND variant and any result with no licence at all.
// Docs: https://europepmc.org/RestfulWebService and https://europepmc.org/searchsyntax
//
// Preprints (SRC:PPR) are left out so the source can sit with PubMed at trust 90;
// retracted papers and retraction notices are dropped here, and DOI and PMID are
// kept so the weekly retraction check can catch the ones retracted later.

import { clean } from './text.ts';
import { bareDoi, type Candidate } from './sources.ts';

export const EUROPEPMC_API = 'https://www.ebi.ac.uk/europepmc/webservices/rest';

/**
 * The licence string to store, or null when it is not CC0, CC BY or CC BY-SA.
 * Europe PMC writes "cc by", "cc0", "cc by-sa"; versions, hyphens and case are
 * tolerated ("CC-BY 4.0", "CC BY-SA 3.0"). NC and ND variants and anything unknown
 * return null.
 */
export function europePmcLicence(raw: unknown): string | null {
  const n = String(raw ?? '').toLowerCase().replace(/[-_]/g, ' ').replace(/\binternational\b/g, ' ').replace(/\s+/g, ' ').trim()
    .replace(/^(cc0|cc zero)\b.*$/, 'cc0').replace(/\s+\d+(\.\d+)?$/, '');
  if (n === 'cc0') return 'CC0 1.0';
  if (n === 'cc by') return 'CC BY';
  if (n === 'cc by sa') return 'CC BY-SA';
  return null;
}

// ISO 639-2 (as Europe PMC writes `language`) to ISO 639-1 (as the Commons stores `lang`).
const LANG: Record<string, string> = { eng: 'en', spa: 'es', fre: 'fr', fra: 'fr', ger: 'de', deu: 'de', por: 'pt', ita: 'it', dut: 'nl', nld: 'nl', chi: 'zh', zho: 'zh', jpn: 'ja', rus: 'ru', pol: 'pl', tur: 'tr', kor: 'ko' };

/** ISO 639-1 code for a Europe PMC language, 'en' when none is given, null when it is one we cannot name. */
export function europePmcLang(raw: unknown): string | null {
  const s = String(raw ?? '').trim().toLowerCase();
  if (!s) return 'en';
  return LANG[s] || null;
}

function isRetracted(r: any): boolean {
  const types: string[] = [].concat(r?.pubTypeList?.pubType || []).map((t: any) => String(t).toLowerCase());
  if (types.some(t => t.includes('retracted publication') || t.includes('retraction of publication'))) return true;
  const cc: any[] = [].concat(r?.commentCorrectionList?.commentCorrection || []);
  return cc.some(c => /retraction (in|of)/i.test(String(c?.type || '')));
}

function authorsOf(r: any): string[] {
  const list: any[] = [].concat(r?.authorList?.author || []);
  let names = list.map(a => clean(a?.fullName || [a?.firstName, a?.lastName].filter(Boolean).join(' ') || a?.collectiveName || '')).filter(Boolean);
  if (!names.length && r?.authorString) names = String(r.authorString).replace(/\.\s*$/, '').split(/,\s*/).map(clean).filter(Boolean);
  return names.slice(0, 20);
}

/**
 * Map one core search result to a candidate, or null when it should be skipped:
 * not open access, a licence that is not CC0, CC BY or CC BY-SA, a preprint, a
 * retraction, no PMCID, no title, an abstract too short to say anything, or a
 * language we cannot name.
 */
export function europePmcCandidate(r: any): Candidate | null {
  if (!r || typeof r !== 'object') return null;
  if (String(r.isOpenAccess || '').toUpperCase() !== 'Y') return null;
  const licence = europePmcLicence(r.license); if (!licence) return null;
  const src = String(r.source || '').toUpperCase();
  if (src === 'PPR' || isRetracted(r)) return null;
  const pmcid = String(r.pmcid || '').toUpperCase();
  if (!/^PMC\d{1,10}$/.test(pmcid)) return null;
  const pmid = /^\d{1,10}$/.test(String(r.pmid || '')) ? String(r.pmid) : undefined;
  const lang = europePmcLang(r.language); if (!lang) return null;
  const title = clean(r.title).replace(/\.$/, '').slice(0, 200);
  const abstract = clean(r.abstractText);
  if (!title || abstract.length < 200) return null;
  const journal = clean(r.journalInfo?.journal?.title || r.journalTitle || '');
  const date = String(r.firstPublicationDate || r.electronicPublicationDate || '');
  const authors = authorsOf(r);
  return {
    external_id: pmcid,
    // Europe PMC's own article page: MED/<pmid> when the paper is in PubMed, else PMC/<pmcid>.
    url: pmid ? `https://europepmc.org/article/MED/${pmid}` : `https://europepmc.org/article/PMC/${pmcid}`,
    title,
    summary: abstract.slice(0, 600),
    content: `${title}. ${abstract}${journal ? ` Published in ${journal}.` : ''}`,
    authors: authors.length ? authors : undefined,
    published_at: /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : undefined,
    licence,
    lang,
    doi: bareDoi(r.doi),
    pmid,
  };
}

/** Map a core search response (`{ resultList: { result: [...] } }`) and keep at most n. */
export function europePmcCandidates(response: any, n: number): Candidate[] {
  const rows: any[] = Array.isArray(response?.resultList?.result) ? response.resultList.result : [];
  const out: Candidate[] = [];
  for (const r of rows) { const c = europePmcCandidate(r); if (c) out.push(c); if (out.length >= n) break; }
  return out;
}

// The filter every query carries, so the server already returns only reusable papers.
export const EUROPEPMC_FILTER = 'OPEN_ACCESS:y AND (LICENSE:"cc by" OR LICENSE:"cc0" OR LICENSE:"cc by-sa") AND NOT SRC:PPR';

// Topics to walk, one picked at random per run, with a random publication year.
export const EUROPEPMC_TOPICS = [
  'public health', 'epidemiology', 'nutrition', 'exercise', 'sleep', 'vaccination', 'antimicrobial resistance',
  'malaria', 'tuberculosis', 'cancer screening', 'cardiovascular disease', 'diabetes', 'mental health', 'ageing',
  'genomics', 'microbiome', 'immunology', 'neuroscience', 'ecology', 'climate change and health', 'air pollution',
  'maternal health', 'child development', 'infectious disease', 'pharmacology', 'evolution', 'plant biology',
];

/** The API base from the registry when it is an https URL, otherwise the default. */
export function europePmcApiBase(registered: string | null | undefined): string {
  const r = String(registered || '').trim().replace(/\/+$/, '');
  return /^https:\/\/[a-z0-9.-]+(\/[a-z0-9._/-]*)?$/i.test(r) ? r : EUROPEPMC_API;
}

function searchUrl(api: string, query: string, pageSize: number): string {
  return `${europePmcApiBase(api)}/search?query=${encodeURIComponent(query)}&resultType=core&format=json&pageSize=${Math.max(1, Math.min(pageSize, 100))}&cursorMark=*`;
}

/** Search URL for the random walk: one topic, one publication year, the licence filter. */
export function europePmcWalkUrl(api: string, topic: string, year: number, pageSize: number): string {
  const y = Math.floor(year);
  return searchUrl(api, `"${topic.replace(/"/g, '')}" AND ${EUROPEPMC_FILTER} AND FIRST_PDATE:[${y}-01-01 TO ${y}-12-31]`, pageSize);
}

/** Search URL for gap filling: the topic words, the licence filter, any year. */
export function europePmcSearchUrl(api: string, topic: string, pageSize: number): string {
  const words = clean(topic).replace(/["():\[\]{}^~*?\\]/g, ' ').replace(/\b(AND|OR|NOT)\b/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
  return searchUrl(api, `(${words || 'health'}) AND ${EUROPEPMC_FILTER}`, pageSize);
}

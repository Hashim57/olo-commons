// Pure mappers from each source's API shape to Commons candidates, plus the
// search URLs the gap filler uses. No I/O here, so `deno test tests/` covers
// them without the network. index.ts does the fetching.

import { clean, delatex, joinParts } from './text.ts';
import { openLicence } from './licence.ts';

export type Candidate = {
  external_id?: string; url: string; title: string; summary?: string; content?: string; authors?: string[]; published_at?: string; licence?: string; lang?: string;
  /** Which revision of the source this text came from (Wikipedia revision id, Wikidata lastrevid, DOI version), for re-checks. */
  source_revision?: string;
  /** Identifiers the retraction check matches on. */
  doi?: string; pmid?: string;
};

/** A DOI in its bare form (10.xxxx/...), lower case, from a URL or a plain string; undefined when it is not one. */
export function bareDoi(s: unknown): string | undefined {
  const m = String(s ?? '').trim().match(/10\.\d{4,9}\/[^\s"<>]+/i);
  return m ? m[0].replace(/[.,;)]+$/, '').toLowerCase() : undefined;
}

/** A Wikipedia REST page summary (random or by title) -> candidate, or null when it is not a real article. */
export function wikiCandidate(p: any, lang: string): Candidate | null {
  if (!p || p.type !== 'standard' || !p.extract || p.extract.length < 200) return null;
  return { external_id: String(p.pageid), url: p.content_urls?.desktop?.page || `https://${lang}.wikipedia.org/wiki/${encodeURIComponent(p.title)}`, title: p.title, summary: clean(p.description ? p.description + '. ' + p.extract : p.extract).slice(0, 600), content: clean(p.extract), published_at: p.timestamp ? p.timestamp.slice(0, 10) : undefined, licence: 'CC BY-SA 4.0', lang,
    source_revision: p.revision ? String(p.revision) : undefined };
}

/** Titles from a Wikipedia list=search response. */
export function wikiSearchTitles(r: any): string[] {
  return ((r?.query?.search || []) as any[]).map(x => String(x.title || '')).filter(Boolean);
}

/**
 * Wikidata wbgetentities response -> candidates for the given ids (entities with a label, a description and some notability).
 * Since 2024 many items keep their name only as the language-independent "mul" label (Q42 has no "en" label any more),
 * so "mul" is the fallback when there is no English label.
 */
export function wikidataCandidates(e: any, ids: string[], n: number): Candidate[] {
  const out: Candidate[] = [];
  for (const id of ids) {
    const ent = e?.entities?.[id]; const label = ent?.labels?.en?.value || ent?.labels?.mul?.value, desc = ent?.descriptions?.en?.value;
    if (!label || !desc || wikidataHousekeeping(label, desc)) continue;
    const links = Object.keys(ent.sitelinks || {}).length;
    if (links < 3) continue;
    out.push({ external_id: id, url: `https://www.wikidata.org/wiki/${id}`, title: label, summary: `${label}: ${desc}.`, content: `${label}. ${desc}. Described in ${links} Wikimedia projects.`, licence: 'CC0 1.0', source_revision: ent.lastrevid ? String(ent.lastrevid) : undefined });
    if (out.length >= n) break;
  }
  return out;
}

/**
 * True for a Wikidata item that describes a Wikimedia page rather than a thing
 * in the world: a category, a template, a disambiguation page, a list article,
 * a project or help page. They sit in the main namespace, so the random walk
 * returns them freely (39 of the 174 wikidata atoms in the 2026-11-03 snapshot
 * were categories, taxonomy templates and disambiguation pages), and they have
 * enough sitelinks to pass the notability check. Nothing about them is a fact
 * to verify a claim against, so they are not atoms.
 */
export function wikidataHousekeeping(label: string, desc: string): boolean {
  if (/^(Category|Template|Module|Wikipedia|Portal|Help|MediaWiki|File|Draft|Book|Wikidata|Property|Lexeme):/i.test(label)) return true;
  return /^Wikimedia (category|disambiguation page|list article|template|project page|internal item|module|navigational template|KML file|set index article|permanent duplicate item|human name disambiguation page)\b|^(taxonomy|navigational|infobox|stub|citation) template$/i.test(desc.trim());
}

/**
 * How many items one wikidata run looks at. wbgetentities takes at most 50 ids per
 * call, and the random walk used to ask for only 20. Most random items fail the
 * notability check (fewer than 3 sitelinks: scholarly articles, taxa, streets), and
 * since the housekeeping filter also drops categories and templates, a batch of 20
 * often kept nothing: 99 wikidata atoms on 2 Nov, 19 on 3 Nov in the snapshot.
 * Asking for the full 50 costs no extra request and keeps the source fed.
 */
export const WIKIDATA_BATCH = 50;

/** list=random over the main namespace, a full batch of ids whatever n is (n only caps what is kept). */
export function wikidataRandomUrl(): string {
  return `https://www.wikidata.org/w/api.php?action=query&list=random&rnnamespace=0&rnlimit=${WIKIDATA_BATCH}&format=json`;
}

/** wbgetentities for up to WIKIDATA_BATCH ids (labels, descriptions, sitelinks, revision). Only Q ids are passed on. */
export function wikidataEntitiesUrl(ids: string[]): string {
  const q = ids.filter(id => /^Q\d+$/.test(id)).slice(0, WIKIDATA_BATCH);
  return `https://www.wikidata.org/w/api.php?action=wbgetentities&ids=${q.join('|')}&props=info|labels|descriptions|sitelinks&languages=en|mul&format=json`;
}

/** Ids from a wbsearchentities response. */
export function wikidataSearchIds(r: any): string[] {
  return ((r?.search || []) as any[]).map(x => String(x.id || '')).filter(id => /^Q\d+$/.test(id));
}

/**
 * The search the Internet Archive connector runs: texts with a description and a
 * licence URL. Until 2026-11-10 the query asked for any text with a description
 * and the mapper stored "Public domain / as stated by the Archive" for the 88
 * percent of items that carry no licence URL at all, which was a guess: the
 * Archive also lends in-copyright library scans, and 83 percent of what the
 * source gave the Commons was uploader junk that the quality gate in text.ts
 * later had to learn to refuse (issue #50). The Archive's own CC and public
 * domain marks live in `licenseurl`, so asking for it up front gives the atom
 * its real licence and keeps most of that junk from ever reaching the gate.
 * Four times the budget is requested because the mapper then refuses the items
 * whose licence is not open (NC, ND, custom).
 */
export function archiveSearchUrl(n: number, page: number): string {
  return `https://archive.org/advancedsearch.php?q=mediatype%3Atexts+AND+description%3A*+AND+licenseurl%3A*&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=description&fl%5B%5D=creator&fl%5B%5D=date&fl%5B%5D=licenseurl&rows=${Math.min(n * 4, 40)}&page=${page}&output=json`;
}

/**
 * Internet Archive advancedsearch docs -> candidates: an identifier, a title, a
 * description of at least 100 characters and a licence URL that is PDM, CC0,
 * the retired CC public domain dedication, CC BY or CC BY-SA (licence.ts). An
 * item without a licence URL, or under any other licence, is not an atom.
 */
export function archiveCandidates(docs: any[]): Candidate[] {
  const desc = (d: any) => joinParts(d.description);
  const out: Candidate[] = [];
  for (const d of docs || []) {
    if (!d || typeof d.identifier !== 'string' || !d.identifier || !d.title || desc(d).length < 100) continue;
    const licence = openLicence(d.licenseurl);
    if (!licence) continue;
    out.push({ external_id: d.identifier, url: `https://archive.org/details/${d.identifier}`, title: clean(d.title).slice(0, 200), summary: desc(d).slice(0, 600), content: desc(d), authors: d.creator ? [].concat(d.creator).map(clean) : undefined, published_at: /^\d{4}-\d{2}-\d{2}/.test(String(d.date || '')) ? String(d.date).slice(0, 10) : undefined, licence });
  }
  return out;
}

/** arXiv Atom feed -> candidates (titles and abstracts run through delatex). */
export function arxivCandidates(xml: string): Candidate[] {
  const out: Candidate[] = [];
  for (const m of String(xml || '').matchAll(/<entry>([\s\S]*?)<\/entry>/g)) {
    const e = m[1]; const id = (e.match(/<id>(.*?)<\/id>/) || [])[1]; const title = clean(delatex((e.match(/<title>([\s\S]*?)<\/title>/) || [])[1])); const abs = clean(delatex((e.match(/<summary>([\s\S]*?)<\/summary>/) || [])[1]));
    const authors = Array.from(e.matchAll(/<name>(.*?)<\/name>/g)).map(x => clean(x[1])); const pub = (e.match(/<published>(.*?)<\/published>/) || [])[1];
    const doi = bareDoi((e.match(/<arxiv:doi[^>]*>(.*?)<\/arxiv:doi>/) || [])[1]);
    if (!id || !title || abs.length < 100) continue;
    const ver = (id.match(/v(\d+)$/) || [])[1];
    out.push({ external_id: id.replace('http://arxiv.org/abs/', ''), url: id.replace('http://', 'https://'), title, summary: abs.slice(0, 600), content: abs, authors, published_at: pub ? pub.slice(0, 10) : undefined, licence: 'arXiv.org perpetual non-exclusive licence (abstract)', source_revision: ver ? `v${ver}` : undefined, doi });
  }
  return out;
}

/** Project Gutenberg (gutendex) books -> candidates. */
export function gutenbergCandidates(books: any[]): Candidate[] {
  return (books || []).filter((b: any) => b && b.title && (b.summaries?.length || b.subjects?.length)).map((b: any) => ({ external_id: String(b.id), url: `https://www.gutenberg.org/ebooks/${b.id}`, title: clean(b.title).slice(0, 200), summary: clean(b.summaries?.[0] || `${b.title}. Subjects: ${(b.subjects || []).slice(0, 6).join('; ')}`).slice(0, 600), content: clean(b.summaries?.[0] || '') + ' Subjects: ' + (b.subjects || []).join('; '), authors: (b.authors || []).map((a: any) => a.name), published_at: undefined, licence: 'Public domain' }));
}

/** PubMed efetch XML -> candidates (abstract of at least 150 characters). */
export function pubmedCandidates(xml: string): Candidate[] {
  const out: Candidate[] = [];
  for (const m of String(xml || '').matchAll(/<PubmedArticle>([\s\S]*?)<\/PubmedArticle>/g)) {
    const a = m[1]; const pmid = (a.match(/<PMID[^>]*>(\d+)<\/PMID>/) || [])[1]; const title = clean((a.match(/<ArticleTitle>([\s\S]*?)<\/ArticleTitle>/) || [])[1]);
    const abs = clean(Array.from(a.matchAll(/<AbstractText[^>]*>([\s\S]*?)<\/AbstractText>/g)).map(x => x[1]).join(' ')); const year = (a.match(/<PubDate>[\s\S]*?<Year>(\d{4})<\/Year>/) || [])[1];
    // One <Author> element at a time, so an author without a ForeName (or a CollectiveName) is not paired with the next author's ForeName.
    const authors = Array.from(a.matchAll(/<Author\b[^>]*>([\s\S]*?)<\/Author>/g)).map(x => {
      const last = (x[1].match(/<LastName>(.*?)<\/LastName>/) || [])[1]; const fore = (x[1].match(/<ForeName>(.*?)<\/ForeName>/) || [])[1];
      return last ? clean(fore ? fore + ' ' + last : last) : '';
    }).filter(Boolean).slice(0, 8);
    // The article's own ArticleIdList (the first one in PubmedData), never the DOI of a paper in its ReferenceList.
    const ownIds = (a.match(/<PubmedData>[\s\S]*?<ArticleIdList>([\s\S]*?)<\/ArticleIdList>/) || [])[1] || '';
    const doi = bareDoi((ownIds.match(/<ArticleId IdType="doi">(.*?)<\/ArticleId>/) || [])[1]);
    if (!pmid || !title || abs.length < 150) continue;
    out.push({ external_id: pmid, url: `https://pubmed.ncbi.nlm.nih.gov/${pmid}/`, title, summary: abs.slice(0, 600), content: abs, authors, published_at: year ? `${year}-01-01` : undefined, licence: 'Abstract as published; citation data public domain (NLM)', pmid, doi });
  }
  return out;
}

/** Ids from a PubMed esearch JSON response. */
export function pubmedSearchIds(s: any): string[] {
  return ((s?.esearchresult?.idlist || []) as any[]).map(String).filter(id => /^\d+$/.test(id));
}

/** Month names Wikinews uses in its dateline ("Sunday, October 25, 2026"). */
const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];

/** The dateline at the start of a Wikinews article -> YYYY-MM-DD, or undefined. */
export function wikinewsDate(text: string): string | undefined {
  const m = String(text || '').slice(0, 120).match(/(?:[A-Z][a-z]+day,\s*)?([A-Z][a-z]+)\s+(\d{1,2}),\s+(\d{4})/);
  if (!m) return undefined;
  const mon = MONTHS.indexOf(m[1].toLowerCase());
  if (mon < 0) return undefined;
  return `${m[3]}-${String(mon + 1).padStart(2, '0')}-${m[2].padStart(2, '0')}`;
}

/** Wikinews (MediaWiki API, prop=extracts|info|revisions) pages -> candidates. The dateline is the fact's date. */
export function wikinewsCandidates(r: any, n: number): Candidate[] {
  const out: Candidate[] = [];
  for (const p of Object.values((r?.query?.pages || {}) as Record<string, any>)) {
    const text = clean(p?.extract || '');
    if (!p?.title || text.length < 200 || /^(Wikinews|Category|Template|Portal):/.test(p.title)) continue;
    const date = wikinewsDate(text) || (p.touched ? String(p.touched).slice(0, 10) : undefined);
    const body = text.replace(/^(?:[A-Z][a-z]+day,\s*)?[A-Z][a-z]+\s+\d{1,2},\s+\d{4}\s*/, '');
    out.push({ external_id: String(p.pageid), url: p.fullurl || `https://en.wikinews.org/wiki/${encodeURIComponent(String(p.title).replace(/ /g, '_'))}`, title: clean(p.title).slice(0, 200), summary: body.slice(0, 600), content: body, published_at: date, licence: 'CC BY 2.5', lang: 'en',
      source_revision: p.lastrevid ? String(p.lastrevid) : undefined });
    if (out.length >= n) break;
  }
  return out;
}

/** OpenAlex stores abstracts as an inverted index {word: [positions]}; put the words back in order. */
export function openalexAbstract(inv: any): string {
  if (!inv || typeof inv !== 'object') return '';
  const words: string[] = [];
  for (const [w, positions] of Object.entries(inv as Record<string, number[]>)) for (const i of positions || []) words[i] = w;
  return clean(words.filter(Boolean).join(' '));
}

/** OpenAlex works -> candidates: open-access, not retracted, with an abstract; DOI kept for the retraction check. */
export function openalexCandidates(works: any[], n: number): Candidate[] {
  const out: Candidate[] = [];
  for (const w of works || []) {
    if (!w || !w.title || w.is_retracted) continue;
    const abs = openalexAbstract(w.abstract_inverted_index);
    if (abs.length < 150) continue;
    const id = String(w.id || '').replace('https://openalex.org/', '');
    const doi = bareDoi(w.doi);
    // An http:// landing page falls through to the DOI or the OpenAlex page instead of dropping the work.
    const landing = String(w.primary_location?.landing_page_url || '');
    const url = /^https:\/\//.test(landing) ? landing : (doi ? `https://doi.org/${doi}` : (id ? `https://openalex.org/${id}` : ''));
    if (!/^https:\/\//.test(url)) continue;
    const venue = w.primary_location?.source?.display_name;
    const lic = w.primary_location?.license || w.open_access?.oa_status;
    out.push({ external_id: id || undefined, url, title: clean(w.title).slice(0, 300), summary: abs.slice(0, 600), content: abs + (venue ? ` Published in ${clean(venue)}.` : ''),
      authors: (w.authorships || []).slice(0, 8).map((a: any) => clean(a?.author?.display_name)).filter(Boolean), published_at: /^\d{4}-\d{2}-\d{2}$/.test(String(w.publication_date || '')) ? w.publication_date : undefined,
      licence: 'CC0 1.0 (metadata); abstract as published' + (lic && /^cc-/i.test(String(lic)) ? ` (${String(lic).toUpperCase()})` : ''), doi });
    if (out.length >= n) break;
  }
  return out;
}

/**
 * Search URLs for a gap topic (a few lower-case words). One per source that
 * has a public search API; sources without one (gutenberg, archive_org, CKAN)
 * are skipped by the gap filler. The words are joined the way each API likes.
 * `key` is sent only where the API takes one in the query (OpenAlex `api_key`).
 */
export function searchUrl(slug: string, topic: string, n: number, key = ''): string | null {
  const words = topic.split(/\s+/).filter(Boolean);
  if (!words.length) return null;
  const q = encodeURIComponent(words.join(' '));
  switch (slug) {
    case 'wikipedia': return `https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=${q}&srlimit=${n}&format=json`;
    case 'wikipedia_es': return `https://es.wikipedia.org/w/api.php?action=query&list=search&srsearch=${q}&srlimit=${n}&format=json`;
    case 'wikidata': return `https://www.wikidata.org/w/api.php?action=wbsearchentities&search=${q}&language=en&limit=${n}&format=json`;
    case 'wikinews': return `https://en.wikinews.org/w/api.php?action=query&generator=search&gsrsearch=${q}&gsrnamespace=0&gsrlimit=${n}&prop=extracts|info&exintro=1&explaintext=1&exlimit=${n}&inprop=url&format=json`;
    case 'openalex': return `https://api.openalex.org/works?search=${q}&filter=has_abstract:true,is_retracted:false&per-page=${n}&select=id,doi,title,abstract_inverted_index,authorships,publication_date,primary_location,is_retracted,open_access&mailto=hello@heliusnetwork.com${key ? `&api_key=${encodeURIComponent(key)}` : ''}`;
    case 'arxiv': return `https://export.arxiv.org/api/query?search_query=${words.map(w => 'all:' + encodeURIComponent(w)).join('+AND+')}&max_results=${n}`;
    case 'pubmed': return `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=${words.map(w => encodeURIComponent(w)).join('+AND+')}&retmax=${n}&sort=relevance&retmode=json`;
    default: return null;
  }
}

/* ---------- how fast a source answers, and how often it may be asked ---------- */

/** The time a connector call gets by default, and the longer one for the two APIs that answer slowly. */
export const DEFAULT_TIMEOUT_MS = 8000;
export const SLOW_TIMEOUT_MS = 20000;

/**
 * How long a call to this source may take. gutendex is volunteer-run and slow on deep pages (issue #17), and
 * arXiv's export API often takes longer than 8 s to answer a sorted query: on 13 November 2026 it timed out in
 * 5 of 12 runs while every other source answered. Both get 20 s; the rest keep 8 s so a dead source cannot eat the run.
 */
export function fetchTimeoutMs(slug: string): number {
  return slug === 'arxiv' || slug === 'gutenberg' ? SLOW_TIMEOUT_MS : DEFAULT_TIMEOUT_MS;
}

/** arXiv's terms of use ask for at least three seconds between calls to its API. */
export const ARXIV_GAP_MS = 3000;

/**
 * Milliseconds to wait before calling a paced API again, given when it was last called (undefined: never) and the
 * time now. A run can reach arXiv twice (the gap search, then the random walk) within a second, which its API answers
 * with 429 (seen 13 November 2026); waiting out the gap costs at most three seconds of a forty-second run.
 */
export function waitBefore(lastCallAt: number | undefined, now: number, gapMs = ARXIV_GAP_MS): number {
  if (lastCallAt === undefined || !Number.isFinite(lastCallAt)) return 0;
  return Math.max(0, Math.min(gapMs, gapMs - (now - lastCallAt)));
}

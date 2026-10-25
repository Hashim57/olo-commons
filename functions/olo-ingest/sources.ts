// Pure mappers from each source's API shape to Commons candidates, plus the
// search URLs the gap filler uses. No I/O here, so `deno test tests/` covers
// them without the network. index.ts does the fetching.

import { clean, delatex } from './text.ts';

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

/** Wikidata wbgetentities response -> candidates for the given ids (entities with a label, a description and some notability). */
export function wikidataCandidates(e: any, ids: string[], n: number): Candidate[] {
  const out: Candidate[] = [];
  for (const id of ids) {
    const ent = e?.entities?.[id]; const label = ent?.labels?.en?.value, desc = ent?.descriptions?.en?.value;
    if (!label || !desc) continue;
    const links = Object.keys(ent.sitelinks || {}).length;
    if (links < 3) continue;
    out.push({ external_id: id, url: `https://www.wikidata.org/wiki/${id}`, title: label, summary: `${label}: ${desc}.`, content: `${label}. ${desc}. Described in ${links} Wikimedia projects.`, licence: 'CC0 1.0', source_revision: ent.lastrevid ? String(ent.lastrevid) : undefined });
    if (out.length >= n) break;
  }
  return out;
}

/** Ids from a wbsearchentities response. */
export function wikidataSearchIds(r: any): string[] {
  return ((r?.search || []) as any[]).map(x => String(x.id || '')).filter(id => /^Q\d+$/.test(id));
}

/** Internet Archive advancedsearch docs -> candidates. */
export function archiveCandidates(docs: any[]): Candidate[] {
  return (docs || []).filter((d: any) => d && d.title && d.description).map((d: any) => ({ external_id: d.identifier, url: `https://archive.org/details/${d.identifier}`, title: clean(d.title).slice(0, 200), summary: clean(Array.isArray(d.description) ? d.description.join(' ') : d.description).slice(0, 600), content: clean(Array.isArray(d.description) ? d.description.join(' ') : d.description), authors: d.creator ? [].concat(d.creator).map(clean) : undefined, published_at: /^\d{4}-\d{2}-\d{2}/.test(String(d.date || '')) ? String(d.date).slice(0, 10) : undefined, licence: d.licenseurl ? `See ${d.licenseurl}` : 'Public domain / as stated by the Archive' }));
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
    const authors = Array.from(a.matchAll(/<Author[^>]*>[\s\S]*?<LastName>(.*?)<\/LastName>[\s\S]*?<ForeName>(.*?)<\/ForeName>/g)).slice(0, 8).map(x => clean(x[2] + ' ' + x[1]));
    const doi = bareDoi((a.match(/<ArticleId IdType="doi">(.*?)<\/ArticleId>/) || [])[1]);
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
    const url = w.primary_location?.landing_page_url || (doi ? `https://doi.org/${doi}` : (id ? `https://openalex.org/${id}` : ''));
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
 */
export function searchUrl(slug: string, topic: string, n: number): string | null {
  const words = topic.split(/\s+/).filter(Boolean);
  if (!words.length) return null;
  const q = encodeURIComponent(words.join(' '));
  switch (slug) {
    case 'wikipedia': return `https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=${q}&srlimit=${n}&format=json`;
    case 'wikipedia_es': return `https://es.wikipedia.org/w/api.php?action=query&list=search&srsearch=${q}&srlimit=${n}&format=json`;
    case 'wikidata': return `https://www.wikidata.org/w/api.php?action=wbsearchentities&search=${q}&language=en&limit=${n}&format=json`;
    case 'wikinews': return `https://en.wikinews.org/w/api.php?action=query&generator=search&gsrsearch=${q}&gsrnamespace=0&gsrlimit=${n}&prop=extracts|info&exintro=1&explaintext=1&exlimit=${n}&inprop=url&format=json`;
    case 'openalex': return `https://api.openalex.org/works?search=${q}&filter=has_abstract:true,is_retracted:false&per-page=${n}&select=id,doi,title,abstract_inverted_index,authorships,publication_date,primary_location,is_retracted,open_access&mailto=hello@heliusnetwork.com`;
    case 'arxiv': return `https://export.arxiv.org/api/query?search_query=${words.map(w => 'all:' + encodeURIComponent(w)).join('+AND+')}&max_results=${n}`;
    case 'pubmed': return `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=${words.map(w => encodeURIComponent(w)).join('+AND+')}&retmax=${n}&sort=relevance&retmode=json`;
    default: return null;
  }
}

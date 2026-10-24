// Pure mappers from each source's API shape to Commons candidates, plus the
// search URLs the gap filler uses. No I/O here, so `deno test tests/` covers
// them without the network. index.ts does the fetching.

import { clean, delatex } from './text.ts';

export type Candidate = { external_id?: string; url: string; title: string; summary?: string; content?: string; authors?: string[]; published_at?: string; licence?: string; lang?: string };

/** A Wikipedia REST page summary (random or by title) -> candidate, or null when it is not a real article. */
export function wikiCandidate(p: any, lang: string): Candidate | null {
  if (!p || p.type !== 'standard' || !p.extract || p.extract.length < 200) return null;
  return { external_id: String(p.pageid), url: p.content_urls?.desktop?.page || `https://${lang}.wikipedia.org/wiki/${encodeURIComponent(p.title)}`, title: p.title, summary: clean(p.description ? p.description + '. ' + p.extract : p.extract).slice(0, 600), content: clean(p.extract), published_at: p.timestamp ? p.timestamp.slice(0, 10) : undefined, licence: 'CC BY-SA 4.0', lang };
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
    out.push({ external_id: id, url: `https://www.wikidata.org/wiki/${id}`, title: label, summary: `${label}: ${desc}.`, content: `${label}. ${desc}. Described in ${links} Wikimedia projects.`, licence: 'CC0 1.0' });
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
    if (!id || !title || abs.length < 100) continue;
    out.push({ external_id: id.replace('http://arxiv.org/abs/', ''), url: id.replace('http://', 'https://'), title, summary: abs.slice(0, 600), content: abs, authors, published_at: pub ? pub.slice(0, 10) : undefined, licence: 'arXiv.org perpetual non-exclusive licence (abstract)' });
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
    if (!pmid || !title || abs.length < 150) continue;
    out.push({ external_id: pmid, url: `https://pubmed.ncbi.nlm.nih.gov/${pmid}/`, title, summary: abs.slice(0, 600), content: abs, authors, published_at: year ? `${year}-01-01` : undefined, licence: 'Abstract as published; citation data public domain (NLM)' });
  }
  return out;
}

/** Ids from a PubMed esearch JSON response. */
export function pubmedSearchIds(s: any): string[] {
  return ((s?.esearchresult?.idlist || []) as any[]).map(String).filter(id => /^\d+$/.test(id));
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
    case 'arxiv': return `https://export.arxiv.org/api/query?search_query=${words.map(w => 'all:' + encodeURIComponent(w)).join('+AND+')}&max_results=${n}`;
    case 'pubmed': return `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=${words.map(w => encodeURIComponent(w)).join('+AND+')}&retmax=${n}&sort=relevance&retmode=json`;
    default: return null;
  }
}

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
export function wikidataCandidates(e: any, ids: string[], n: number, facts: Record<string, string[]> = {}): Candidate[] {
  const out: Candidate[] = [];
  for (const id of ids) {
    const ent = e?.entities?.[id]; const label = ent?.labels?.en?.value || ent?.labels?.mul?.value;
    // a description that ends in a full stop ("a subsidiary of Alphabet Inc.") would otherwise be written with two
    const desc = String(ent?.descriptions?.en?.value || '').replace(/\.$/, '');
    if (!label || !desc || wikidataHousekeeping(label, desc)) continue;
    const links = Object.keys(ent.sitelinks || {}).length;
    if (links < 3) continue;
    const f = wikidataFactsSentence(facts[id] || []);
    out.push({ external_id: id, url: `https://www.wikidata.org/wiki/${id}`, title: label, summary: `${label}: ${desc}.${f ? ' ' + f : ''}`, content: `${label}. ${desc}.${f ? ' ' + f : ''} Described in ${links} Wikimedia projects.`, licence: 'CC0 1.0', source_revision: ent.lastrevid ? String(ent.lastrevid) : undefined });
    if (out.length >= n) break;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Wikidata facts. Until 23 November 2026 a Wikidata atom was its label and its
// one-line description ("Yuri Zheleznov: Russian footballer."), which is what
// the search index and the embedding saw, and the claims an answer could be
// checked against (born when, where, citizen of what) stayed on Wikidata. The
// item's statements are CC0 like the rest, so the connector now reads a fixed
// set of them (WIKIDATA_FACT_PROPERTIES, the properties a claim about a
// person, a place, a work, an organisation, an event or a taxon is most often
// about) and writes them into the summary and the content as one sentence of
// "property value" clauses joined by semicolons: "Instance of human; country
// of citizenship Russia; date of birth 15 November 2002; occupation
// association football player." Semicolons, not "Label: value" fields, so the
// catalogue rule in text.ts never reads the atom as a record. Two more calls
// per batch (the claims of the kept items, then the labels of the items their
// values point at), both bounded by WIKIDATA_BATCH. Deprecated statements are
// skipped, preferred ones win over normal ones (the current population, not
// every census), at most WIKIDATA_FACT_VALUES values per property and
// WIKIDATA_FACT_MAX properties per item. A re-check compares revision ids
// first (recheck.ts), so items whose revision has not moved are not rewritten
// in the new shape; an item that did change gets its facts when the new text
// is stored.
// ---------------------------------------------------------------------------

/** Properties read into the facts sentence, in the order they are written, with the English property label. */
export const WIKIDATA_FACT_PROPERTIES: [string, string][] = [
  ['P31', 'instance of'], ['P279', 'subclass of'], ['P225', 'taxon name'], ['P105', 'taxon rank'], ['P171', 'parent taxon'],
  ['P17', 'country'], ['P30', 'continent'], ['P131', 'located in'], ['P36', 'capital'], ['P1376', 'capital of'], ['P206', 'on body of water'],
  ['P1082', 'population'], ['P2046', 'area'], ['P2044', 'elevation above sea level'], ['P625', 'coordinates'],
  ['P27', 'country of citizenship'], ['P569', 'date of birth'], ['P19', 'place of birth'], ['P570', 'date of death'], ['P20', 'place of death'],
  ['P106', 'occupation'], ['P39', 'position held'], ['P69', 'educated at'], ['P108', 'employer'], ['P54', 'member of sports team'], ['P166', 'award received'], ['P800', 'notable work'],
  ['P571', 'inception'], ['P576', 'dissolved'], ['P112', 'founded by'], ['P159', 'headquarters'], ['P463', 'member of'], ['P749', 'parent organization'],
  ['P50', 'author'], ['P57', 'director'], ['P86', 'composer'], ['P170', 'creator'], ['P577', 'publication date'], ['P495', 'country of origin'], ['P136', 'genre'], ['P407', 'language of work'], ['P123', 'publisher'],
  ['P580', 'start time'], ['P582', 'end time'], ['P585', 'point in time'], ['P276', 'location'], ['P710', 'participant'], ['P1120', 'number of deaths'],
];
/** At most this many values are written for one property ("member of sports team" can have thirty). */
export const WIKIDATA_FACT_VALUES = 3;
/** At most this many properties are written for one item. */
export const WIKIDATA_FACT_MAX = 12;

/** wbgetentities for the claims of up to WIKIDATA_BATCH items. */
export function wikidataClaimsUrl(ids: string[]): string {
  const q = ids.filter(id => /^Q\d+$/.test(id)).slice(0, WIKIDATA_BATCH);
  return `https://www.wikidata.org/w/api.php?action=wbgetentities&ids=${q.join('|')}&props=claims&format=json`;
}

/** wbgetentities for the labels of up to WIKIDATA_BATCH items (the values the facts point at). */
export function wikidataLabelsUrl(ids: string[]): string {
  const q = ids.filter(id => /^Q\d+$/.test(id)).slice(0, WIKIDATA_BATCH);
  return `https://www.wikidata.org/w/api.php?action=wbgetentities&ids=${q.join('|')}&props=labels&languages=en|mul&format=json`;
}

/** The labels in a wbgetentities response, by id: English first, else the language-independent "mul" label. */
export function wikidataLabels(e: any): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [id, ent] of Object.entries((e?.entities || {}) as Record<string, any>)) {
    const v = ent?.labels?.en?.value || ent?.labels?.mul?.value;
    if (typeof v === 'string' && v.trim()) out[id] = v.trim();
  }
  return out;
}

/** The statements of one property worth reading: preferred ones when there are any, else the normal ones; never deprecated. */
function liveStatements(claims: any, prop: string): any[] {
  const all = (Array.isArray(claims?.[prop]) ? claims[prop] : []).filter((s: any) => s?.mainsnak?.snaktype === 'value' && s.rank !== 'deprecated');
  const preferred = all.filter((s: any) => s.rank === 'preferred');
  return preferred.length ? preferred : all;
}

/** The item ids a fact sentence for these items would need labels for (values and units of the chosen statements), in order, without repeats. */
export function wikidataValueIds(e: any, ids: string[]): string[] {
  const out: string[] = [], seen = new Set<string>();
  for (const id of ids) {
    const claims = e?.entities?.[id]?.claims;
    if (!claims) continue;
    for (const [prop] of WIKIDATA_FACT_PROPERTIES) {
      for (const s of liveStatements(claims, prop).slice(0, WIKIDATA_FACT_VALUES)) {
        const dv = s.mainsnak.datavalue;
        const want: string[] = [];
        if (dv?.type === 'wikibase-entityid' && typeof dv.value?.id === 'string') want.push(dv.value.id);
        if (dv?.type === 'quantity' && typeof dv.value?.unit === 'string') { const m = dv.value.unit.match(/\/(Q\d+)$/); if (m) want.push(m[1]); }
        for (const w of want) if (/^Q\d+$/.test(w) && !seen.has(w)) { seen.add(w); out.push(w); }
      }
    }
  }
  return out;
}

const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const ordinal = (n: number) => n + (n % 100 >= 11 && n % 100 <= 13 ? 'th' : ['th', 'st', 'nd', 'rd'][n % 10] || 'th');

/**
 * A Wikidata time value as a reader writes it, at the precision the statement
 * claims and no finer: "15 November 2002" (day), "November 2002" (month),
 * "2002" (year), "2000s" (decade), "19th century"; years before the common era
 * end in "BCE". Coarser precisions, and anything unreadable, give ''.
 */
export function wikidataTime(v: any): string {
  const m = String(v?.time || '').match(/^([+-])(\d{1,16})-(\d\d)-(\d\d)T/);
  if (!m) return '';
  const p = Number(v?.precision), bce = m[1] === '-', y = Number(m[2]), mo = Number(m[3]), d = Number(m[4]);
  if (!y && p >= 8) return '';
  const year = bce ? `${y} BCE` : String(y);
  if (p >= 11 && d >= 1 && mo >= 1 && mo <= 12) return `${d} ${MONTH_NAMES[mo - 1]} ${year}`;
  if (p === 10 && mo >= 1 && mo <= 12) return `${MONTH_NAMES[mo - 1]} ${year}`;
  if (p === 9 || p === 11 || p === 10) return year;
  if (p === 8) return `${Math.floor(y / 10) * 10}s${bce ? ' BCE' : ''}`;
  if (p === 7) return `${ordinal(Math.ceil(y / 100))} century${bce ? ' BCE' : ''}`;
  return '';
}

/**
 * A Wikidata quantity as a reader writes it: "12,345" (a count, unit "1"),
 * "1,234.57 square kilometre" (the unit's label). A quantity whose unit has no
 * known label gives '', since "elevation above sea level 8,848.86" without its
 * metre would mislead.
 */
export function wikidataQuantity(v: any, labels: Record<string, string>): string {
  const n = Number(String(v?.amount ?? '').replace(/^\+/, ''));
  if (!isFinite(n)) return '';
  const text = Number.isInteger(n) ? n.toLocaleString('en-US') : n.toLocaleString('en-US', { maximumFractionDigits: 2 });
  const unit = String(v?.unit || '1');
  if (unit === '1') return text;
  const m = unit.match(/\/(Q\d+)$/);
  const label = m ? labels[m[1]] : '';
  return label ? `${text} ${label}` : '';
}

/** A coordinate as "66.2709 N, 47.1710 E". */
export function wikidataCoordinate(v: any): string {
  const lat = Number(v?.latitude), lon = Number(v?.longitude);
  if (!isFinite(lat) || !isFinite(lon)) return '';
  return `${Math.abs(lat).toFixed(4)} ${lat < 0 ? 'S' : 'N'}, ${Math.abs(lon).toFixed(4)} ${lon < 0 ? 'W' : 'E'}`;
}

/**
 * The facts of one item as "property value" clauses, in WIKIDATA_FACT_PROPERTIES
 * order, from its claims and the labels of the items they point at. A value
 * whose label is unknown is left out (never a bare Q id); a quantity carries
 * its "point in time" qualifier as "in 2021" when it has one, so "population
 * 12,345 in 2021" says which count it is. Strings are read only for the taxon
 * name. Empty when the item has no claim worth writing.
 */
export function wikidataFacts(ent: any, labels: Record<string, string>): string[] {
  const claims = ent?.claims;
  if (!claims) return [];
  const facts: string[] = [];
  for (const [prop, name] of WIKIDATA_FACT_PROPERTIES) {
    if (facts.length >= WIKIDATA_FACT_MAX) break;
    const values: string[] = [];
    for (const s of liveStatements(claims, prop)) {
      if (values.length >= WIKIDATA_FACT_VALUES) break;
      const dv = s.mainsnak.datavalue; let text = '';
      if (dv?.type === 'wikibase-entityid') text = labels[dv.value?.id] || '';
      else if (dv?.type === 'time') text = wikidataTime(dv.value);
      else if (dv?.type === 'quantity') {
        text = wikidataQuantity(dv.value, labels);
        const when = ((Array.isArray(s.qualifiers?.P585) ? s.qualifiers.P585 : []) as any[]).filter(q => q?.snaktype === 'value').map(q => wikidataTime(q.datavalue?.value)).filter(Boolean)[0];
        if (text && when) text += ` in ${when}`;
      }
      else if (dv?.type === 'globecoordinate') text = wikidataCoordinate(dv.value);
      else if (dv?.type === 'string' && prop === 'P225') text = clean(dv.value);
      if (text && !values.includes(text)) values.push(text);
    }
    if (values.length) facts.push(`${name} ${values.length > 1 ? values.slice(0, -1).join(', ') + ' and ' + values[values.length - 1] : values[0]}`);
  }
  return facts;
}

/** The facts as one sentence, the first letter capitalised, clauses joined by semicolons: '' when there are none. */
export function wikidataFactsSentence(facts: string[]): string {
  const f = facts.map(x => clean(x)).filter(Boolean);
  if (!f.length) return '';
  const s = f.join('; ');
  return s[0].toUpperCase() + s.slice(1) + '.';
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
 * Items of the Indian High Court judgments mirror (COURT_MIRROR_RE) are not
 * either: they are scanned court orders naming private people (text.ts,
 * isCourtRecord, which also refuses the ones whose identifier is different),
 * uploaded under CC BY 4.0, so the licence gate lets them through.
 */
export const COURT_MIRROR_RE = /^india\.highcourt\.judgement\./;

export function archiveCandidates(docs: any[]): Candidate[] {
  const desc = (d: any) => joinParts(d.description);
  const out: Candidate[] = [];
  for (const d of docs || []) {
    if (!d || typeof d.identifier !== 'string' || !d.identifier || !d.title || desc(d).length < 100) continue;
    if (COURT_MIRROR_RE.test(d.identifier)) continue;
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

/**
 * A Gutenberg title as a reader would write it. gutendex copies the catalogue's MARC 245 field, and for about
 * one book in fourteen the subtitle marker comes with it: "The unknown seven : $b A detective story",
 * "Peter Pan : $b [Peter and Wendy]", "Liebe ist ewig : $b Roman" (49 of 665 stored titles on 17 November 2026).
 * The marker becomes a colon; any other subfield code left in the title ($a, $c, $n, $p) goes. Gutenberg only:
 * an arXiv title's "$p$" is mathematics.
 */
export function marcTitle(title: unknown): string {
  return clean(title).replace(/\s*:\s*\$b\s+/g, ': ').replace(/\s*\$[a-z]\s+/g, ' ').replace(/\s+/g, ' ').trim();
}

/** Project Gutenberg (gutendex) books -> candidates. */
export function gutenbergCandidates(books: any[]): Candidate[] {
  return (books || []).filter((b: any) => b && b.title && (b.summaries?.length || b.subjects?.length)).map((b: any) => { const title = marcTitle(b.title); return { external_id: String(b.id), url: `https://www.gutenberg.org/ebooks/${b.id}`, title: title.slice(0, 200), summary: clean(b.summaries?.[0] || `${title}. Subjects: ${(b.subjects || []).slice(0, 6).join('; ')}`).slice(0, 600), content: clean(b.summaries?.[0] || '') + ' Subjects: ' + (b.subjects || []).join('; '), authors: (b.authors || []).map((a: any) => a.name), published_at: undefined, licence: 'Public domain' }; });
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

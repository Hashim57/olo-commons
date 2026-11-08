// Text cleaning shared by the connectors. Pure functions, no I/O, so they can be
// unit tested with `deno test tests/` without starting the Edge Function.

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '-', mdash: '-', hellip: '...', rsquo: "'", lsquo: "'", rdquo: '"', ldquo: '"' };

/** Strip tags, decode the common HTML entities, collapse whitespace. Never returns HTML. */
export function clean(s: unknown): string {
  return String(s ?? '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#(\d+);/g, (_, n) => { const c = Number(n); return c > 31 && c < 0x10ffff ? String.fromCodePoint(c) : ' '; })
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => { const c = parseInt(h, 16); return c > 31 && c < 0x10ffff ? String.fromCodePoint(c) : ' '; })
    .replace(/&([a-z]+);/gi, (m, name) => ENTITIES[name.toLowerCase()] ?? m)
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Join a field that may be a string or a list of strings into one cleaned
 * string, dropping parts that repeat an earlier part. The Internet Archive
 * often returns the same description twice (Delpher newspaper records carry
 * it once per metadata copy), which doubled the text of most archive_org
 * atoms. A single string that is one block written twice in a row is
 * collapsed the same way.
 */
export function joinParts(v: unknown): string {
  const parts = (Array.isArray(v) ? v : [v]).map(clean).filter(Boolean);
  const seen = new Set<string>();
  const kept: string[] = [];
  for (const p of parts) { const k = p.toLowerCase(); if (!seen.has(k)) { seen.add(k); kept.push(p); } }
  const s = kept.join(' ');
  const h = Math.floor((s.length - 1) / 2);
  if (s.length > 40 && s[h] === ' ' && s.slice(0, h) === s.slice(h + 1)) return s.slice(0, h);
  return s;
}

/** Words of two or more letters in any script, lower case; digits and punctuation are not words. */
export function words(s: unknown): string[] {
  return (String(s ?? '').toLowerCase().match(/[\p{L}\p{M}]{2,}/gu) || []);
}

/** How many distinct words a text has (the measure isStub uses). */
export function distinctWords(s: unknown): number {
  return new Set(words(s)).size;
}

export const STUB_MIN_DISTINCT = 6;     // fewer different words than this is a label, not a description
export const STUB_REPEAT_DISTINCT = 12; // below this many different words, a text made mostly of repeats is a stub...
export const STUB_REPEAT_RATIO = 0.4;   // ...when fewer than this share of its words are distinct
export const STUB_MIN_REST = 40;        // characters the body must still have once the title and the authors are taken out
export const STUB_LINK_REST = 160;      // characters a body holding a link, an email address or a domain must have once those are taken out

/** Links, email addresses and bare domains (ketabpedia.com, www.example.org), the parts of a body that point elsewhere. */
export const LINK_RE = /https?:\/\/\S+|www\.\S+|[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|\b[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.(?:com|org|net|info|ir|io|co|edu|gov|me|tk|ru|de|uk)\b(?:\/\S*)?/g;

/**
 * True when a body is a pointer, not a description: it holds a link, an email
 * address or a domain, and once those are taken out (and a text written twice
 * is read once) fewer than STUB_LINK_REST characters are left. Uploaders to
 * the Internet Archive often put a notice in the description field instead of
 * describing the item ("for details please visit ketabpedia.com", the same
 * line with a contact email, "Raw Scan images of a Canister of the Sim
 * Collection: https://..."). On the 2026-11-05 snapshot 55 archive_org atoms
 * were of that kind (one notice was stored 21 times under different items),
 * some carried third-party email addresses, and no atom of any other source
 * matched the rule.
 */
export function isLinkNotice(body: unknown): boolean {
  const b = clean(body);
  if (!b.match(LINK_RE)) return false;
  let rest = b.replace(LINK_RE, ' ').replace(/\s+/g, ' ').trim();
  const h = Math.floor((rest.length - 1) / 2);
  if (rest.length > 20 && rest[h] === ' ' && rest.slice(0, h) === rest.slice(h + 1)) rest = rest.slice(0, h);
  return rest.length < STUB_LINK_REST;
}

export const CATALOGUE_MIN_LABELS = 3;    // a body with fewer "Label: value" fields than this is read as prose
export const CATALOGUE_MAX_WORDS_PER_LABEL = 5; // ...and one with more words than this per field is prose with headings (a structured abstract)

/** "Label: " fields: a capitalised word, up to three more words, a colon and a space ("Title: ", "Plaats van uitgave: ", "Gazette Type: "). */
export const LABEL_RE = /(?:^|\s)(?:[A-Z][\w'’.-]*(?: (?:[a-z]+|[A-Z][\w'’.-]*)){0,3}): (?=\S)/g;

/** A text written twice in a row ("X X"), read once; anything else unchanged. */
export function oncely(s: string): string {
  const h = Math.floor((s.length - 1) / 2);
  return s.length > 40 && s[h] === ' ' && s.slice(0, h) === s.slice(h + 1) ? s.slice(0, h) : s;
}

/**
 * True when a body is a catalogue record, not a description: a list of
 * "Label: value" fields with almost no words between the labels. The Internet
 * Archive holds library and government metadata records whose description
 * field is the record itself: Delpher newspaper issues ("Title: Algemeen
 * Handelsblad Datum: 22-05-1861 Editie: Dag Plaats van uitgave: Amsterdam
 * Uitgever: ... Nummer: 44") and Indian gazettes ("Gazette Type: Extraordinary
 * Date: 2022-05-26 Department: Home Election Department Subject: ..."). On the
 * 2026-11-07 snapshot 365 of the 999 archive_org atoms were of that kind, about
 * 14 more arriving a day, and no atom of any other source matched: a record
 * has at most 5 words per field (Delpher about 4.3), while the closest real
 * text, an abstract written as a list of citations, has 6.6, and a structured
 * abstract ("OBJECTIVE: ... METHODS: ...") has 19 or more. The claim such a
 * record would support ("the paper was published in Amsterdam") is in the
 * title and the date already; the body adds nothing a reader could check.
 */
export function isCatalogueRecord(body: unknown): boolean {
  const b = oncely(clean(body));
  const labels = (b.match(LABEL_RE) || []).length;
  if (labels < CATALOGUE_MIN_LABELS) return false;
  return words(b).length / labels <= CATALOGUE_MAX_WORDS_PER_LABEL;
}

export const SHELF_MIN_SEGMENTS = 5;          // a body divided into fewer parts than this is read as prose
export const SHELF_MAX_WORDS_PER_SEGMENT = 4; // ...and one with a part longer than this holds a sentence, not a shelf mark

/** Separators between the parts of a shelf mark or a path: a spaced dash of any length, a bar, a slash, a chevron or a double colon. */
export const SEGMENT_RE = /\s(?:[\u2013\u2014-]|\||\/|>|\u00bb|::)\s/;

/**
 * True when a body is a shelf mark, not a description: a path of short parts
 * joined by dashes, bars or slashes, such as the Karnataka State Archives
 * records on the Internet Archive ("Karnataka State Archives - Mysore -
 * Gazettes - Gazette-6 - HRS-Historical Record Section - R - 369 (ID 102517)",
 * written with spaced dashes). Each part is a name of at most four words and
 * there are at least five of them, so a sentence with one aside, or a dataset
 * publisher chain ("DOC/NOAA/NESDIS/NCEI > National Centers for Environmental
 * Information"), never qualifies. On the 2026-11-08 snapshot 76 archive_org
 * atoms were of that kind, about one more a day, and no atom of any other
 * source matched. Such a body says where a scan sits on a shelf, which the
 * title and the URL already say.
 */
export function isShelfMark(body: unknown): boolean {
  const segs = oncely(clean(body)).split(SEGMENT_RE).map(s => s.trim()).filter(Boolean);
  return segs.length >= SHELF_MIN_SEGMENTS && segs.every(s => words(s).length <= SHELF_MAX_WORDS_PER_SEGMENT);
}

/**
 * A library catalogue's physical description at the start of a body: pagination
 * with optional roman front matter ("ix, 203 pages", "88 p.", "1 volume
 * (unpaged)", "1 guide (191 p.)"), illustration notes and the height in
 * centimetres ("xv, 415 p. : ill. ; 24 cm"). Letters and digits are left for
 * the rules that follow, so the pattern cannot backtrack.
 */
export const PHYSICAL_RE = /^(?:[xivlc]+, )?(?:\d+ (?:p\.|pages?|v\.|volumes?|leaves)|volumes?|\d+ (?:volume|guide|portfolio) \((?:unpaged|\d+ p\.?)\))(?: of plates)?[^A-Za-z0-9]*(?:(?:ill\.?|illustrations|col\.|colou?r|maps?|ports?\.?|facsims?\.?|music|charts?|plates)[^A-Za-z0-9]*)*(?:\d+(?: x \d+)? cm\.?)?/i;

/** The catalogue's standard notes, which describe the book's apparatus and not its subject. */
export const CATALOGUE_NOTES_RE = /\bIncludes? (?:bibliographical references?|bibliography|bibliographies|index(?:es)?|discography|filmography)(?: \((?:p\.|pages?)? ?[\d, -]+\))?(?: and index(?:es)?)?\.?|\bBibliography: (?:p\.|pages?) [\d, -]+\.?/gi;

/**
 * A body with its physical description and catalogue notes taken out, so that
 * what is left is what the record says about the book itself; a body with no
 * physical description comes back unchanged. The Internet Archive's scanned
 * library books carry the MARC physical description as their description
 * ("ix, 203 pages : 24 cm Includes bibliographical references and index"),
 * which passes every other rule (six distinct words, no label, no link) and
 * says nothing a reader could check. On the 2026-11-08 snapshot 50 archive_org
 * atoms were only that, 32 more had a real summary after it (kept), and no
 * atom of any other source started with one.
 */
export function withoutPhysicalDescription(body: string): string {
  const m = body.match(PHYSICAL_RE);
  if (!m || !m[0].trim()) return body;
  return body.slice(m[0].length).replace(CATALOGUE_NOTES_RE, ' ').replace(/\s+/g, ' ').trim();
}

/**
 * True when an atom would carry no knowledge: its body is a label, one word
 * or one line repeated, a notice that points elsewhere (isLinkNotice), a
 * catalogue record (isCatalogueRecord), a shelf mark (isShelfMark), or says
 * nothing beyond the title, the authors and a physical description
 * (withoutPhysicalDescription).
 * The Internet Archive search returns many uploads whose description is the
 * identifier, a file name or a word typed twice ("new book new book", "fhfh
 * fhfh", "P P"); a third of the archive_org atoms in the Commons on 2026-11-03
 * (330 of 892 in the snapshot) were of that kind, because a length check alone
 * is passed by anything repeated often enough. The measure is taken on the
 * longer of summary and content, never on their concatenation (the summary
 * is usually the start of the content, which would read as a repeat), and it
 * is calibrated on the snapshot so that every atom of every other source
 * passes (Wikidata's one-line items included). Every connector's candidates
 * go through it, so a tag dump or a template from any source is skipped too.
 */
export function isStub(title: unknown, summary: unknown, content: unknown, authors?: unknown): boolean {
  const s = clean(summary), c = clean(content);
  const body = c.length >= s.length ? c : s;
  if (!body) return true;
  const w = words(body), distinct = new Set(w).size;
  if (distinct < STUB_MIN_DISTINCT) return true;
  if (distinct < STUB_REPEAT_DISTINCT && distinct / w.length < STUB_REPEAT_RATIO) return true;
  if (isLinkNotice(body)) return true;
  if (isCatalogueRecord(body)) return true;
  if (isShelfMark(body)) return true;
  // What the body says once the physical description, the title and the authors are taken out of it.
  let rest = ' ' + withoutPhysicalDescription(body).toLowerCase() + ' ';
  const names = [title, ...(Array.isArray(authors) ? authors : [])].map(x => clean(x).toLowerCase()).filter(x => x.length >= 3);
  for (const n of names) rest = rest.split(n).join(' ');
  return rest.replace(/\s+/g, ' ').trim().length < STUB_MIN_REST;
}

// LaTeX commands that are safe to replace by a plain-text spelling. Anything
// not listed is kept as its name without the backslash (\alpha -> alpha), which
// reads better in a summary than a stray backslash and still carries meaning.
const COMMANDS: Record<string, string> = {
  times: ' x ', cdot: ' . ', pm: ' +/- ', mp: ' -/+ ', leq: ' <= ', le: ' <= ', geq: ' >= ', ge: ' >= ', neq: ' != ', ne: ' != ',
  approx: ' ~ ', sim: ' ~ ', simeq: ' ~ ', equiv: ' == ', to: ' -> ', rightarrow: ' -> ', leftarrow: ' <- ', Rightarrow: ' => ', mapsto: ' -> ',
  infty: 'infinity', ldots: '...', cdots: '...', dots: '...', percent: '%', degree: ' degrees', circ: ' degrees', ell: 'l', prime: "'",
  quad: ' ', qquad: ' ', ' ': ' ', ',': ' ', ';': ' ', '!': '', '&': '&', '%': '%', '$': '$', '#': '#', '_': '_', '{': '{', '}': '}', '\\': ' ',
};

// Commands whose single argument should be kept as plain text and the wrapper dropped.
const UNWRAP = /\\(?:text|textit|textbf|textrm|textsc|texttt|emph|mathrm|mathbf|mathit|mathcal|mathbb|mathsf|boldsymbol|bm|hat|tilde|bar|vec|overline|underline|mbox|operatorname|label|ref|cite|url)\s*\{([^{}]*)\}/g;

/**
 * Turn the LaTeX found in arXiv titles and abstracts into readable plain text:
 * `$O(n \log n)$` -> `O(n log n)`, `\textit{in vivo}` -> `in vivo`,
 * `10^{-3}` -> `10^-3`, `\frac{a}{b}` -> `a/b`, `\alpha` -> `alpha`.
 * Idempotent: text with no LaTeX comes back unchanged apart from whitespace.
 */
export function delatex(s: unknown): string {
  let t = String(s ?? '');
  if (!/[\\$^_{}]/.test(t)) return t;
  // display and inline maths delimiters: keep the contents
  t = t.replace(/\\\[|\\\]|\\\(|\\\)/g, ' ');
  // dollar signs come in pairs around maths; an odd one is probably currency, leave it
  if (((t.match(/\$/g) || []).length % 2) === 0) t = t.replace(/\$\$?/g, '');
  t = t.replace(/\\begin\{[a-z*]+\}|\\end\{[a-z*]+\}/g, ' ');
  // \frac{a}{b} -> a/b (one level; nested fractions fall through to brace removal)
  t = t.replace(/\\(?:frac|dfrac|tfrac)\s*\{([^{}]*)\}\s*\{([^{}]*)\}/g, '$1/$2');
  t = t.replace(/\\sqrt\s*\{([^{}]*)\}/g, 'sqrt($1)');
  // unwrap formatting commands, repeated so nested ones unwrap too
  for (let i = 0; i < 3; i++) t = t.replace(UNWRAP, '$1');
  // superscripts and subscripts: 10^{-3} -> 10^-3, x_{i} -> x_i, ^\circ -> degrees
  t = t.replace(/\^\\circ/g, ' degrees').replace(/([\^_])\{([^{}]*)\}/g, '$1$2');
  // named commands, letters and symbols
  t = t.replace(/\\([a-zA-Z]+|[ ,;!&%$#_{}\\])/g, (_, name) => (name in COMMANDS ? COMMANDS[name] : name));
  // what is left of the grouping braces carries no meaning in plain text
  t = t.replace(/[{}]/g, '');
  return t.replace(/\s+/g, ' ').trim();
}

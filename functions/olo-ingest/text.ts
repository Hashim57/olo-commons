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

/**
 * True when an atom would carry no knowledge: its body is a label, one word
 * or one line repeated, or says nothing beyond the title and the authors.
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
  // What the body says once the title and the authors are taken out of it.
  let rest = ' ' + body.toLowerCase() + ' ';
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

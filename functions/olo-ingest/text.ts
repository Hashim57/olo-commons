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

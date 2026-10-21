// deno test tests/
import { assertEquals } from './_assert.ts';
import { clean, delatex } from '../functions/olo-ingest/text.ts';

Deno.test('clean strips tags, decodes entities and collapses whitespace', () => {
  assertEquals(clean('<p>Tom &amp; Jerry</p>\n\n  <b>run</b>'), 'Tom & Jerry run');
  assertEquals(clean('a &lt;b&gt; &quot;c&quot; &#39;d&#39; caf&#233; caf&#xe9; &nbsp;f'), 'a <b> "c" \'d\' caf\u00e9 caf\u00e9 f');
  assertEquals(clean(null), '');
  assertEquals(clean(undefined), '');
  assertEquals(clean(42), '42');
  assertEquals(clean('&unknown; stays'), '&unknown; stays');
});

Deno.test('clean never lets a tag through', () => {
  const out = clean('<script>alert(1)</script><img src=x onerror=alert(1)>text');
  assertEquals(/<[^>]+>/.test(out), false);
  assertEquals(out, 'alert(1) text');
});

Deno.test('delatex leaves plain text alone', () => {
  assertEquals(delatex('Coral reefs recover after bleaching.'), 'Coral reefs recover after bleaching.');
  assertEquals(delatex('Costs rose to $5 million.'), 'Costs rose to $5 million.');
  assertEquals(delatex(null), '');
});

Deno.test('delatex removes maths delimiters and keeps the contents', () => {
  assertEquals(delatex('runs in $O(n \\log n)$ time'), 'runs in O(n log n) time');
  assertEquals(delatex('where $$x = y$$ holds'), 'where x = y holds');
  assertEquals(delatex('and \\(a + b\\) and \\[c\\]'), 'and a + b and c');
});

Deno.test('delatex unwraps formatting commands and fractions', () => {
  assertEquals(delatex('measured \\textit{in vivo} and \\textbf{in vitro}'), 'measured in vivo and in vitro');
  assertEquals(delatex('$\\mathrm{CO}_2$ at $\\frac{1}{2}$ pressure'), 'CO_2 at 1/2 pressure');
  assertEquals(delatex('$\\sqrt{2}$ and $10^{-3}$ and $x_{i}$'), 'sqrt(2) and 10^-3 and x_i');
  assertEquals(delatex('\\emph{\\textbf{nested}} words'), 'nested words');
});

Deno.test('delatex spells symbols and keeps unknown command names', () => {
  assertEquals(delatex('$\\alpha \\approx 0.5$ and $T \\to \\infty$'), 'alpha ~ 0.5 and T -> infinity');
  assertEquals(delatex('$a \\leq b$, $c \\neq d$, $5 \\times 10^{6}$'), 'a <= b, c != d, 5 x 10^6');
  assertEquals(delatex('at $90^\\circ$'), 'at 90 degrees');
  assertEquals(delatex('\\begin{equation} E = mc^2 \\end{equation}'), 'E = mc^2');
  assertEquals(delatex('50\\% of \\$3 \\& more'), '50% of $3 & more');
});

Deno.test('delatex then clean gives a readable arXiv title', () => {
  const raw = 'A $\\mathcal{O}(1)$ Bound for\n  $\\ell_1$-Regularised &amp; Sparse Models';
  assertEquals(clean(delatex(raw)), 'A O(1) Bound for l_1-Regularised & Sparse Models');
});

// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { clean, delatex, distinctWords, isCatalogueRecord, isLinkNotice, isStub, joinParts, oncely, words } from '../functions/olo-ingest/text.ts';

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

Deno.test('joinParts drops repeated parts and collapses a string written twice', () => {
  const rec = 'Title: Rotterdamse courant Datum: 15-05-1802 Editie: Dag Plaats van uitgave: Rotterdam Nummer: 58';
  assertEquals(joinParts([rec, rec]), rec);
  assertEquals(joinParts(rec + ' ' + rec), rec);
  assertEquals(joinParts(['Part one.', 'Part two.']), 'Part one. Part two.');
  assertEquals(joinParts(['Same.', '<b>same.</b>', 'Other.']), 'Same. Other.');
  assertEquals(joinParts('Short ok. Short ok.'), 'Short ok. Short ok.');
  assertEquals(joinParts(undefined), '');
});

/* ---------- isStub: the quality gate every candidate passes before it is embedded ---------- */

Deno.test('isStub: one word or one line repeated is a stub, as are a label and an empty body', () => {
  // real archive_org descriptions from the 2026-11-03 snapshot
  for (const [t, s] of [['New Book', 'new book new book'], ['adult1010', 'adult1010 adult1010'], ['patronyt', 'P P'], ['allianz-travelss', 'fhfh fhfh'], ['0925', 'm m'], ['The Apple Store', ':) :)'],
    ['Hazrat Ummul Baneen', 'Author: Sayyid Saeed Akhtar Rizvi Author: Sayyid Saeed Akhtar Rizvi']]) {
    assert(isStub(t, s, s), `${t}: ${s}`);
  }
  assert(isStub('Art and Heart', 'Art and Heart. Subjects: Poetry', 'Subjects: Poetry'));
  assert(isStub('Anything', '', ''));
  assert(isStub('Anything', undefined, null));
  // a long text made of one tag repeated is still a stub, however long
  assert(isStub('Tags', 'radio drama season picks '.repeat(12), 'radio drama season picks '.repeat(12)));
});

Deno.test('isStub: a body that only repeats the title and the author is a stub', () => {
  assert(isStub('Hydropower Engineering Module 5 CE IIT Kharagpur', 'Hydropower Engineering Module 5 CE IIT Kharagpur', 'Hydropower Engineering Module 5 CE IIT Kharagpur', ['IIT Kharagpur']));
  assert(isStub('A Short Title', 'A Short Title by Jane Q. Writer', 'A Short Title by Jane Q. Writer', ['Jane Q. Writer']));
});

Deno.test('isStub: real atoms of every source pass, Wikidata one-liners included', () => {
  assert(!isStub('Ehnen', 'Ehnen: town.', 'Ehnen. town. Described in 10 Wikimedia projects.'));
  assert(!isStub('Magnus Wikman', 'Magnus Wikman: association football player.', 'Magnus Wikman. association football player. Described in 5 Wikimedia projects.'));
  const abs = 'Project Gutenberg is a volunteer effort to digitize and archive cultural works, as well as to encourage the creation and distribution of eBooks. It was founded in 1971 by American writer Michael S. Hart and is the oldest digital library.';
  assert(!isStub('Project Gutenberg', abs.slice(0, 120), abs));
  // the summary being the start of the content does not read as a repeat
  assert(!isStub('A paper', 'We study coral reef recovery after bleaching.', 'We study coral reef recovery after bleaching. Reefs with high herbivore cover recovered faster across 40 sites over six years.'));
  assert(!isStub('Mason\'s retreat', '', 'After many years in England an impoverished, upper-class American family return to an inherited estate on Chesapeake Bay.'));
  // a short Gutenberg record with real subjects
  assert(!isStub('Pride and Prejudice', 'Pride and Prejudice. Subjects: Courtship; England; Sisters; Social classes; Young women; Love stories', 'Subjects: Courtship -- Fiction; England -- Fiction; Sisters -- Fiction; Social classes -- Fiction; Young women -- Fiction; Love stories'));
});

Deno.test('words and distinctWords count letters in any script and ignore digits', () => {
  assertEquals(words('Hello, hello! 2026 x über Über'), ['hello', 'hello', 'über', 'über']);
  assertEquals(distinctWords('Hello, hello! 2026 x über Über'), 2);
  assertEquals(distinctWords('سيد سيد سيد'), 1);
  assertEquals(distinctWords(''), 0);
});

/* ---------- isLinkNotice: a description that only says where to look ---------- */

Deno.test('isLinkNotice: uploader notices from the 2026-11-05 snapshot are stubs', () => {
  // archive_org descriptions stored under many different items (contact addresses replaced by example.org)
  const notices = [
    'لمزيد من التفاصيل يرجى زيارة ketabpedia.com لمزيد من التفاصيل يرجى زيارة ketabpedia.com',
    'للاطلاع علی بیانات الکتاب يرجى زيارة ketabpedia.com للمراسلة: contact@example.org للاطلاع علی بیانات الکتاب يرجى زيارة ketabpedia.com للمراسلة: contact@example.org',
    'Raw Scan images of a Canister of the Sim Collection: https://archive.org/details/SerialsOnMicrofilmCollection Archival backup. See Sim collection: https://archive.org/details/sim_microfilm All the issues from this canister',
    'Archived blog snapshot from Wedzat (https://www.wedzat.com). Archived blog snapshot from Wedzat (https://www.wedzat.com).',
    'Backup of http://www.islc.net/~ccronan/ from 4 March 2019 Backup of http://www.islc.net/~ccronan/ from 4 March 2019',
  ];
  for (const n of notices) {
    assert(isLinkNotice(n), n);
    assert(isStub('ktp2019-item', n, n), n);
  }
});

Deno.test('isLinkNotice: a real description that cites a link is kept, and so is text with no link', () => {
  const abstract = 'We release a benchmark of 12,000 annotated claims drawn from news and encyclopaedia text, with labels for support, contradiction and missing evidence, and we report baselines from three model families. Code and data are available at https://github.com/example/claims.';
  assertEquals(isLinkNotice(abstract), false);
  assertEquals(isStub('A claim benchmark', abstract, abstract), false);
  assertEquals(isLinkNotice('Elementary algebra encompasses the basic concepts of algebra, such as variables and terms, and U.S. schools teach it.'), false);
  assertEquals(isLinkNotice(''), false);
  // numbers with a dot are not domains
  assertEquals(isLinkNotice('Dose 2.5 mg, version 1.2.3, p. 4.'), false);
});

/* ---------- isCatalogueRecord: a description that is a metadata record ---------- */

Deno.test('isCatalogueRecord: Delpher and gazette records from the 2026-11-07 snapshot are stubs', () => {
  const records = [
    // Delpher newspaper issues, the description once and (as the Archive returns it) twice
    'Title: Algemeen Handelsblad Datum: 22-05-1861 Editie: Dag Plaats van uitgave: Amsterdam Uitgever: P. den Hengst en Zoon [etc.] Verspreidingsgebied: Landelijk Nummer: 120',
    "Title: De 's Gravenhaagsche nieuwsbode Datum: 06-02-1859 Editie: Dag Plaats van uitgave: 's Gravenhage Uitgever: J.A. de la Vieter Verspreidingsgebied: Regionaal/lokaal Nummer: 220 Title: De 's Gravenhaagsche nieuwsbode Datum: 06-02-1859 Editie: Dag Plaats van uitgave: 's Gravenhage Uitgever: J.A. de la Vieter Verspreidingsgebied: Regionaal/lokaal Nummer: 220",
    'Title: Journal de la province de Limbourg Datum: 09-10-1824 Editie: Dag Plaats van uitgave: Maastricht Uitgever: L.Th. N\u0133pels Verspreidingsgebied: Regionaal/lokaal Nummer: 238',
    // Indian gazettes
    'Gazette Type: Extraordinary Date: 2022-05-26 Department: Home Election Department Subject: designates the officer, Gazette Source: URL',
    'Gazette Type: Daily Date: 2022-04-20 Department: Gazette contains multiple Departments/Organizations Subject: Gazette contains multiple Subjects Gazette Source: URL',
    'Gazette Type: Extra Ordinary Gazette Number: 611 Date: 2024-10-01 Gazette Type: Extra Ordinary Gazette Number: 611 Date: 2024-10-01',
  ];
  for (const r of records) {
    assert(isCatalogueRecord(r), r);
    assert(isStub('Algemeen Handelsblad 22-05-1861', r, r), r);
  }
});

Deno.test('isCatalogueRecord: prose with headings and real atoms of every source pass', () => {
  // a structured abstract has labels but many words between them
  const abstract = 'OBJECTIVE: To estimate the effectiveness of neuromuscular training and training load management interventions in preventing injuries in youth football. METHODS: We searched five databases to March 2025 for randomised trials. RESULTS: Twelve trials with 9,412 players were included; training programmes reduced injury incidence by a third. CONCLUSIONS: Neuromuscular training prevents injuries in youth football.';
  assertEquals(isCatalogueRecord(abstract), false);
  assertEquals(isStub('Injury prevention in youth football', abstract.slice(0, 200), abstract), false);
  // an abstract written as a list of citations (openalex, 6.6 words per label) is kept
  assertEquals(isCatalogueRecord('Bezugnehmend auf: Arnold Schering: Bach und das Symbol, insbesondere die Symbolik seines Kanons. BJ 1925, S. 40-63 Darauf bezugnehmend: Arnold Schering: Bach und das Symbol. 3. Studie: Psychologische Grundlegung des Symbolbegriffs aus Christian Wolffs Psychologia empirica. BJ 1937, S. 83-95'), false);
  // one or two labels are a normal way to start a description
  assertEquals(isCatalogueRecord('Dataset published by Wake County. Wake County farmers market locations, hours, and descriptions. Source: county GIS. Updated: weekly.'), false);
  assertEquals(isCatalogueRecord('Ehnen: town. Described in 10 Wikimedia projects.'), false);
  assertEquals(isCatalogueRecord(''), false);
  // a time of day is not a label
  assertEquals(isCatalogueRecord('At 10:20 AM, the Prime Minister revealed his cabinet; at 11:05 the list was published and at 12:30 the first ministers were sworn in by the King.'), false);
});

Deno.test('oncely reads a text written twice once and leaves anything else alone', () => {
  const once = 'Title: Arnhemsche courant Datum: 10-12-1814 Editie: Dag Nummer: 147';
  assertEquals(oncely(once + ' ' + once), once);
  assertEquals(oncely(once), once);
  assertEquals(oncely('a a'), 'a a');
  assertEquals(oncely('short short'), 'short short');
});

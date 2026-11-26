// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { ANSWER_SYSTEM, checkEvidence, checkText, labelPassages, opensWithTitle, parseVerdict, publishedLine, quoteKey, renderAnswerPrompt, renderZeusPrompt, splitSentences, summarise, zeusReads, ZEUS_SYSTEM } from '../functions/olo-answer/answer.ts';

const P = [
  { id: 'p1', source: 'wikipedia', url: 'https://x/1', text: 'Project Gutenberg was founded in 1971 by Michael Hart. It offers free books.' },
  { id: 'p2', source: 'pubmed', url: 'https://x/2', text: 'Coral reefs recover slowly after bleaching events.' },
];

Deno.test('labelPassages gives short ids in order, prefers content, drops empties', () => {
  const ps = labelPassages([
    { id: 'uuid-a', source_slug: 'wikipedia', url: 'https://x/a', title: 'A', summary: 'short', content: 'long   content\n here' },
    { id: 'uuid-b', source_slug: 'pubmed', url: 'https://x/b', summary: 'only summary' },
    { id: 'uuid-c', source_slug: 'arxiv', url: 'https://x/c' },
  ]);
  assertEquals(ps.map(p => p.id), ['p1', 'p2']);
  assertEquals(ps[0].text, 'A. long content here');  // the title leads the text (since 2026-11-18)
  assertEquals(ps[1].text, 'only summary');
  assertEquals(labelPassages([{ id: 'x', content: 'y'.repeat(2000) }])[0].text.length, 900);
});

Deno.test('prompts carry every passage with its id and source', () => {
  const a = renderAnswerPrompt('When was it founded?', P);
  assert(a.startsWith('Question: When was it founded?'));
  assert(a.includes('[p1] (wikipedia) Project Gutenberg'));
  assert(a.includes('[p2] (pubmed) Coral'));
  const z = renderZeusPrompt('Founded in 1971.', P);
  assert(z.startsWith('Claim: Founded in 1971.'));
  assert(z.includes('[p2] (pubmed)'));
  assert(ZEUS_SYSTEM.includes('"label": "supported" | "contradicted" | "not_covered"'));
});

Deno.test('splitSentences splits on sentence ends and strips citations', () => {
  const s = splitSentences('Project Gutenberg was founded in 1971. [p1] It offers free books [p1][p2]. Nothing else is known.');
  assertEquals(s.length, 3);
  assertEquals(s[0], { text: 'Project Gutenberg was founded in 1971.', citations: ['p1'] });
  assertEquals(s[1], { text: 'It offers free books.', citations: ['p1', 'p2'] });
  assertEquals(s[2], { text: 'Nothing else is known.', citations: [] });
});

Deno.test('splitSentences keeps decimals, abbreviations-ish numbers and trailing text', () => {
  const s = splitSentences('Growth was 3.5 percent in 2020 [p1]. The rate fell to 1.2 percent');
  assertEquals(s.map(x => x.text), ['Growth was 3.5 percent in 2020.', 'The rate fell to 1.2 percent']);
  assertEquals(splitSentences(''), []);
  assertEquals(splitSentences('   '), []);
  assertEquals(splitSentences('[p1] [p2]'), []);
});

Deno.test('parseVerdict accepts a JSON object inside prose and rejects junk', () => {
  const v = parseVerdict('Sure: {"label": "supported", "evidence": [{"passage": "p1", "quote": "founded in 1971"}], "rationale": "Stated."}');
  assertEquals(v?.label, 'supported');
  assertEquals(v?.evidence, [{ passage: 'p1', quote: 'founded in 1971' }]);
  assertEquals(parseVerdict('{"label": "maybe"}'), null);
  assertEquals(parseVerdict('not json'), null);
  assertEquals(parseVerdict('{"label": "not_covered"}')?.evidence, []);
  assertEquals(parseVerdict('{"label": "supported", "evidence": [{"passage": 1}]}')?.evidence, []);
});

Deno.test('checkEvidence keeps only quotes found in their passage and downgrades unshowable verdicts', () => {
  const ok = checkEvidence({ label: 'supported', evidence: [{ passage: 'p1', quote: 'founded in 1971' }, { passage: 'p1', quote: 'founded in 1972' }], rationale: 'r' }, P);
  assertEquals(ok.label, 'supported');
  assertEquals(ok.evidence, [{ passage: 'p1', quote: 'founded in 1971' }]);
  assertEquals(ok.evidence_checked, true);
  const down = checkEvidence({ label: 'contradicted', evidence: [{ passage: 'p2', quote: 'founded in 1971' }], rationale: 'r' }, P);
  assertEquals(down.label, 'not_covered');
  assertEquals(down.evidence_checked, false);
  const nc = checkEvidence({ label: 'not_covered', evidence: [{ passage: 'p1', quote: 'founded in 1971' }], rationale: 'r' }, P);
  assertEquals(nc.label, 'not_covered');
  assertEquals(nc.evidence, []);
});

Deno.test('summarise counts labels', () => {
  assertEquals(summarise([{ label: 'supported' }, { label: 'supported' }, { label: 'not_covered' }]), { supported: 2, contradicted: 0, not_covered: 1 });
});

import { extractiveAnswer, summarise as summarise2 } from '../functions/olo-answer/answer.ts';

Deno.test('extractive answer quotes the best-matching sentence of each passage, at most three', () => {
  const passages = [
    { id: 'p1', source: 'wikipedia', url: 'u1', text: 'Some unrelated opening sentence about the weather today. Project Gutenberg was founded in 1971 by Michael Hart as a digital library.' },
    { id: 'p2', source: 'gutenberg', url: 'u2', text: 'The Gutenberg collection now offers over seventy thousand free eBooks to readers everywhere.' },
    { id: 'p3', source: 'pubmed', url: 'u3', text: 'Coral reefs recover slowly after a bleaching event, according to long term surveys.' },
  ];
  const out = extractiveAnswer('when was project gutenberg founded', passages);
  assertEquals(out.length, 1);
  assertEquals(out[0].citations, ['p1']);
  assertEquals(out[0].verdict, 'supported');
  assert(passages[0].text.includes(out[0].evidence[0].quote));
  assertEquals(out[0].text, 'Project Gutenberg was founded in 1971 by Michael Hart as a digital library.');
  assertEquals(extractiveAnswer('the and of', passages), []);
  assertEquals(extractiveAnswer('coral', passages)[0].citations, ['p3']);
});

Deno.test('summarise counts verdicts given as label or verdict', () => {
  assertEquals(summarise2([{ verdict: 'supported' }, { verdict: 'not_covered' }, { label: 'contradicted' }]), { supported: 1, contradicted: 1, not_covered: 1 });
});

// Cases from the answer eval of 2026-11-18 (tests/answers/questions-v1.jsonl, run from Hashim's Mac).

Deno.test('splitSentences keeps initials and abbreviations inside their sentence (q024, q029, q046)', () => {
  const a = splitSentences("St. Mark's Masonic Lodge was built in 1898 to replace a lodge destroyed by fire. [p1] It is in Baddeck. [p1]");
  assertEquals(a.map(s => s.text), ["St. Mark's Masonic Lodge was built in 1898 to replace a lodge destroyed by fire.", 'It is in Baddeck.']);
  assertEquals(a[0].citations, ['p1']);
  const b = splitSentences('La historia fue escrita por George A. Romero en colaboración con Dario Argento. [p1]');
  assertEquals(b.length, 1);
  assertEquals(b[0].citations, ['p1']);
  const c = splitSentences('William F. Buckley was born in New York City on November 24, 1925. [p2] Dr. Smith agreed. [p2]');
  assertEquals(c.map(s => s.text), ['William F. Buckley was born in New York City on November 24, 1925.', 'Dr. Smith agreed.']);
  // an ordinary sentence end still splits, and a citation closes a sentence whatever comes before it
  assertEquals(splitSentences('The film premiered in 2014. [p1] Andrew Hulme directed it. [p1]').length, 2);
  assertEquals(splitSentences('The plan was called Plan B. [p1] Nobody liked it. [p2]').length, 2);
});

Deno.test('splitSentences reads lenticular and full-width citation brackets (q030)', () => {
  const s = splitSentences('Enjolras es el líder de «Los Amigos del ABC»【p1】. Muere durante la insurrección de junio de 1832 en París ［p1］.');
  assertEquals(s.length, 2);
  assertEquals(s[0].citations, ['p1']);
  assertEquals(s[1].citations, ['p1']);
  assertEquals(s[0].text.includes('【'), false);
});

Deno.test('a dated source starts with its publication date, others do not (q037, q042, q045)', () => {
  const ps = labelPassages([
    { id: 'a', source_slug: 'wikinews', title: 'Niue votes', summary: 'On April 30th Niue held its eleventh general election.', published_at: '2005-05-01' },
    { id: 'b', source_slug: 'wikipedia', title: 'Reino', summary: 'Reino is a comune in Campania.', published_at: '2026-09-17' },
    { id: 'c', source_slug: 'pubmed', title: 'Review', summary: 'A review of trials.', published_at: '2026-01-01' },
    { id: 'd', source_slug: 'wikinews', title: 'Undated', summary: 'A story.', published_at: null },
  ]);
  assertEquals(ps[0].text, 'Niue votes. Published 1 May 2005. On April 30th Niue held its eleventh general election.');
  assertEquals(ps[0].published, '2005-05-01');
  assertEquals(ps[1].text, 'Reino is a comune in Campania.');
  assertEquals(ps[2].text, 'Review. Published 2026. A review of trials.');  // a paper's 1 January means the year alone
  assertEquals(ps[3].text, 'Undated. A story.');
  assertEquals(publishedLine('wikinews', '2005-13-01'), '');
  assertEquals(publishedLine('wikinews', 'yesterday'), '');
  assertEquals(publishedLine('arxiv', '2026-11-06T00:00:00Z'), 'Published 6 November 2026.');
});

Deno.test('the writer is told to name each subject and to date only from the passages', () => {
  assertEquals(/Never begin with a pronoun/.test(ANSWER_SYSTEM), true);
  assertEquals(/never use a title as if it were a name/.test(ANSWER_SYSTEM), true);
  assertEquals(/begins "Published/.test(ANSWER_SYSTEM), true);
});

Deno.test('checkEvidence accepts a quote that differs only in case, quotes, dashes, spacing or a final stop (q003)', () => {
  const ps = [{ id: 'p1', source: 'wikipedia', url: '', text: 'What Do I Do with Me is the 19th studio album by Tanya Tucker, released on July 2, 1991 as her final album for Capitol Records.' }];
  const ok = checkEvidence({ label: 'supported', evidence: [{ passage: 'p1', quote: 'Released on July  2, 1991.' }], rationale: 'r' }, ps);
  assertEquals(ok.label, 'supported');
  const curly = checkEvidence({ label: 'supported', evidence: [{ passage: 'p1', quote: "The Speaker's House is a museum" }], rationale: 'r' }, [{ ...ps[0], text: 'The Speaker\u2019s House is a museum located in Trappe.' }]);
  assertEquals(curly.label, 'supported');  // a straight apostrophe matches the passage's curly one
  // other words are still refused
  assertEquals(checkEvidence({ label: 'supported', evidence: [{ passage: 'p1', quote: 'released on July 3, 1991' }], rationale: 'r' }, ps).label, 'not_covered');
  assertEquals(checkEvidence({ label: 'supported', evidence: [{ passage: 'p1', quote: '.' }], rationale: 'r' }, ps).label, 'not_covered');
  // an em dash folds to a hyphen, and a hyphen between words reads as a space (since 26 Nov 2026, q069)
  assertEquals(quoteKey('\u201cHello\u2014world\u201d.'), '"hello world"');
});

Deno.test('zeusReads sends English to Zeus and Spanish to the fallback verifier', () => {
  assertEquals(zeusReads('Tropical Storm Hanna was the eighth named storm of the 2002 Atlantic hurricane season.'), true);
  assertEquals(zeusReads('Montrigaud pasó a formar parte de la comuna nueva de Valherbasse a partir del 1 de enero de 2019.'), false);
  assertEquals(zeusReads('La Cabalgata de Reyes Magos que se celebra el 5 de enero en Alcoy se considera la más antigua de España.'), false);
  assertEquals(zeusReads('El obispo de la diócesis de Niigata es Paul Daisuke Narui.'), false);
  assertEquals(zeusReads('Kerrie Tucker, Molonglo, 1995.'), true);  // no marker words: English by default
});

// Second round, from the papers and data.gov questions of the same eval (q036 to q070).

Deno.test('a passage leads with its title, once, so Zeus reads what the writer reads (q063)', () => {
  const ps = labelPassages([
    { id: 'a', source_slug: 'arxiv', title: 'TUTTI: Parallel CKKS Bootstrapping in under 3 ms on CPU', summary: 'This paper introduces TUTTI, a new CKKS bootstrapping procedure.', published_at: '2026-11-09' },
    { id: 'b', source_slug: 'wikidata', title: 'Nazar battu', summary: 'Nazar battu. an icon used to ward off the evil eye.' },
    { id: 'c', source_slug: 'gutenberg', title: 'A Study in Scarlet', summary: '"A Study in Scarlet" by Arthur Conan Doyle is a detective novel.' },
    { id: 'd', source_slug: 'wikinews', title: 'Will it rain?', summary: 'Forecasters disagree.', published_at: '2006-03-11' },
  ]);
  assertEquals(ps[0].text, 'TUTTI: Parallel CKKS Bootstrapping in under 3 ms on CPU. Published 9 November 2026. This paper introduces TUTTI, a new CKKS bootstrapping procedure.');
  assertEquals(ps[1].text, 'Nazar battu. an icon used to ward off the evil eye.');  // already opens with its title
  assertEquals(ps[2].text.startsWith('"A Study in Scarlet" by'), true);              // quoted title counts
  assertEquals(ps[3].text.startsWith('Will it rain? Published 11 March 2006.'), true); // no stop added after "?"
  assertEquals(opensWithTitle('Review', 'A review of trials.'), false);              // a title word inside is not the title
  // the writer's label does not repeat a title the text already leads with
  assertEquals(renderAnswerPrompt('q', ps).includes('(arxiv) TUTTI'), true);
  // and an extractive answer never quotes the title or the date line as a fact
  const ex = extractiveAnswer('TUTTI CKKS bootstrapping procedure parallel CPU', ps);
  assertEquals(ex.some(e => e.text.startsWith('TUTTI: Parallel') || e.text.startsWith('Published')), false);
});

Deno.test('splitSentences keeps dotted abbreviations together (q064)', () => {
  assertEquals(splitSentences('The survey is conducted by the U.S. Census Bureau for HUD. [p1] It has run biennially since 1983. [p1]').map(s => s.text),
    ['The survey is conducted by the U.S. Census Bureau for HUD.', 'It has run biennially since 1983.']);
  assertEquals(splitSentences('The office is in Washington, D.C. and opened in 1973. [p1]').length, 1);
  // a citation after the abbreviation still closes the sentence
  assertEquals(splitSentences('It is the largest survey in the U.S. [p1] The Census Bureau runs it. [p1]').length, 2);
});

Deno.test('checks read a multiplication sign after a number as x, and leave the shown text alone (q059)', () => {
  assertEquals(checkText('Premiums reach 10\u00d7 for Amharic, and 2 \u00d7 for others.'), 'Premiums reach 10x for Amharic, and 2x for others.');
  assertEquals(checkText('3 \u00d7 4 grid'), '3x 4 grid');
  const s = splitSentences('Amharic reaches a 10\u00d7 premium in older tokenizers. [p1]');
  assertEquals(s[0].text.includes('\u00d7'), true);
  const ps = [{ id: 'p1', source: 'arxiv', url: '', text: 'Premiums reach 10x for Amharic in older tokenizers.' }];
  assertEquals(checkEvidence({ label: 'supported', evidence: [{ passage: 'p1', quote: 'Premiums reach 10\u00d7 for Amharic' }], rationale: 'r' }, ps).label, 'supported');
});

Deno.test('checkText: a non-breaking or typographic hyphen reads as a hyphen, so "co\u2011pilot" is the passage\'s "co-pilot"', () => {
  assertEquals(checkText('leaving only the co\u2011pilot as a survivor'), 'leaving only the co-pilot as a survivor');
  assertEquals(checkText('a well\u2010known case'), 'a well-known case');
  assert(quoteKey('co\u2011pilot') === quoteKey('co-pilot'));
});

Deno.test('quoteKey: a hyphen between words reads as a space, so "ward off" is found in "ward-off"; numbers keep theirs', () => {
  assertEquals(quoteKey('to ward-off the evil eye'), quoteKey('to ward off the evil eye'));
  assert(quoteKey('Nazar battu: an icon used in North India and Pakistan to ward-off the evil eye.').includes(quoteKey('used in North India and Pakistan to ward off the evil eye')));
  assertEquals(quoteKey('annually from 1973-1981'), 'annually from 1973-1981', 'a range of years is not words');
  assert(!quoteKey('the well known case').includes(quoteKey('a well-known case')), 'other words are still other words');
});

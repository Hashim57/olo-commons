// deno test tests/
import { assert, assertEquals } from './_assert.ts';
import { checkEvidence, labelPassages, parseVerdict, renderAnswerPrompt, renderZeusPrompt, splitSentences, summarise, ZEUS_SYSTEM } from '../functions/olo-answer/answer.ts';

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
  assertEquals(ps[0].text, 'long content here');
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

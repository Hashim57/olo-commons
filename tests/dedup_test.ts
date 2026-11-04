// deno test tests/   (cross-source deduplication: functions/olo-ingest/dedup.ts)
import { assert, assertEquals } from './_assert.ts';
import { bodyOf, decide, MIN_WORDS, NEAR_TEXT, normDoi, normaliseText, normKey, normPmid, textSimilarity, titleSimilarity, TITLE_MIN, type DedupExisting, type DedupRecord } from '../functions/olo-ingest/dedup.ts';

const ARXIV = 'src-arxiv', PUBMED = 'src-pubmed', OPENALEX = 'src-openalex', WIKI = 'src-wikipedia';

const ABSTRACT = 'We study the effect of regular aerobic exercise on blood pressure in adults with mild hypertension. ' +
  'In a randomised controlled trial of 412 participants followed for twelve months, the exercise group showed a mean ' +
  'reduction in systolic pressure of 6.1 mmHg compared with usual care, with no serious adverse events. ' +
  'Adherence was high and the effect persisted after adjustment for weight loss and diet. These findings support ' +
  'exercise as a first-line intervention for mild hypertension in primary care.';
const TITLE = 'Aerobic exercise and blood pressure in mild hypertension: a randomised trial';

const cand = (o: Partial<DedupRecord> = {}): DedupRecord => ({ source_id: PUBMED, url: 'https://pubmed.ncbi.nlm.nih.gov/123456/', title: TITLE, summary: ABSTRACT.slice(0, 600), content: ABSTRACT, ...o });
const atom = (id: string, o: Partial<DedupExisting> = {}): DedupExisting => ({ id, source_id: ARXIV, url: 'https://arxiv.org/abs/2401.01234v1', title: TITLE, summary: ABSTRACT, content: ABSTRACT, status: 'candidate', ...o });

/* ---------- identifiers ---------- */

Deno.test('normDoi accepts every common written form and lower-cases', () => {
  const want = '10.1038/s41586-024-07566-y';
  for (const s of ['10.1038/S41586-024-07566-Y', 'https://doi.org/10.1038/s41586-024-07566-y', 'http://dx.doi.org/10.1038/S41586-024-07566-Y', 'doi:10.1038/s41586-024-07566-y', 'DOI: 10.1038/s41586-024-07566-y.', 'https://doi.org/10.1038%2Fs41586-024-07566-y', ' 10.1038/s41586-024-07566-y) ']) {
    assertEquals(normDoi(s), want, s);
  }
  assertEquals(normDoi('10.1016/S0140-6736(20)30183-5'), '10.1016/s0140-6736(20)30183-5', 'parentheses inside a DOI are kept');
  assertEquals(normDoi('not a doi'), null);
  assertEquals(normDoi(''), null);
  assertEquals(normDoi(null), null);
  assertEquals(normDoi('%E0%A4%A'), null, 'a malformed escape does not throw');
});

Deno.test('normPmid keeps digits only and drops a prefix and leading zeros', () => {
  assertEquals(normPmid('123456'), '123456');
  assertEquals(normPmid(' PMID: 00123456 '), '123456');
  assertEquals(normPmid(123456), '123456');
  assertEquals(normPmid('12a34'), null);
  assertEquals(normPmid('0000'), null);
  assertEquals(normPmid(undefined), null);
});

Deno.test('same DOI from another source is a duplicate whatever form each side wrote it in', () => {
  const d = decide(cand({ doi: 'https://doi.org/10.1000/ABC.123', title: 'Different wording of the title entirely', content: 'short' }), [atom('a1', { doi: '10.1000/abc.123' })]);
  assertEquals(d, { action: 'duplicate', of: 'a1', reason: 'same_doi', score: 1 });
});

Deno.test('same PMID from another source is a duplicate', () => {
  const d = decide(cand({ source_id: OPENALEX, url: 'https://doi.org/10.1234/x', pmid: 'PMID:123456', content: 'short' }), [atom('p1', { source_id: PUBMED, pmid: '123456' })]);
  assertEquals(d, { action: 'duplicate', of: 'p1', reason: 'same_pmid', score: 1 });
});

Deno.test('one paper from arXiv, then PubMed, then OpenAlex: the later copies point at the first', () => {
  const first = atom('arx', { doi: '10.5555/trial.2024' });
  assertEquals(decide(cand({ doi: '10.5555/TRIAL.2024', pmid: '999' }), [first]), { action: 'duplicate', of: 'arx', reason: 'same_doi', score: 1 });
  const pub = atom('pub', { source_id: PUBMED, doi: '10.5555/trial.2024', pmid: '999' });
  const d = decide(cand({ source_id: OPENALEX, url: 'https://doi.org/10.5555/trial.2024', doi: 'https://doi.org/10.5555/trial.2024' }), [first, pub]);
  assertEquals(d.action === 'duplicate' && d.of, 'arx', 'the oldest copy stays canonical');
});

Deno.test('a DOI match with conflicting PMIDs is not merged (one record is wrong; keep both)', () => {
  const d = decide(cand({ doi: '10.1234/a', pmid: '111', content: 'short' }), [atom('x', { doi: '10.1234/a', pmid: '222' })]);
  assertEquals(d, { action: 'insert' });
});

Deno.test('different DOIs are never merged on text alone (preprint and journal version stay apart)', () => {
  const d = decide(cand({ doi: '10.1234/journal' }), [atom('x', { doi: '10.48550/arxiv.2401.01234' })]);
  assertEquals(d, { action: 'insert' });
});

Deno.test('same source is never deduplicated here: url and content hash already handle exact copies', () => {
  assertEquals(decide(cand({ source_id: ARXIV, doi: '10.1234/a' }), [atom('x', { doi: '10.1234/a' })]), { action: 'insert' });
  assertEquals(decide(cand({ source_id: ARXIV }), [atom('x')]), { action: 'insert' }, 'identical text, same source');
});

Deno.test('a superseded atom is never a duplicate target, so re-check history stays history', () => {
  assertEquals(decide(cand({ doi: '10.1234/a' }), [atom('old', { doi: '10.1234/a', status: 'superseded' })]), { action: 'insert' });
  const d = decide(cand({ doi: '10.1234/a' }), [atom('old', { doi: '10.1234/a', status: 'superseded' }), atom('cur', { doi: '10.1234/a', status: 'verified' })]);
  assertEquals(d.action === 'duplicate' && d.of, 'cur');
});

Deno.test('a retracted atom is still a target: the paper is the same, and the copy must not resurface it', () => {
  const d = decide(cand({ doi: '10.1234/r' }), [atom('r', { doi: '10.1234/r', status: 'retracted' })]);
  assertEquals(d.action === 'duplicate' && d.of, 'r');
});

/* ---------- text ---------- */

Deno.test('normaliseText folds case, accents, punctuation, entities, tags and whitespace', () => {
  assertEquals(normaliseText('  Café &amp; <b>Crème</b>,\n\tbrûlée!! '), 'cafe creme brulee');
  assertEquals(normaliseText('It&#39;s 6.1&nbsp;mmHg'), 'it s 6 1 mmhg');
  assertEquals(normaliseText(null), '');
  assertEquals(normKey('A  Title.', 'Body, text'), normKey('a title', 'body text'));
});

Deno.test('bodyOf compares the longest text a record carries', () => {
  assertEquals(bodyOf({ summary: 'abc', content: 'abcdef' }), 'abcdef');
  assertEquals(bodyOf({ summary: 'abcdef', content: null }), 'abcdef');
  assertEquals(bodyOf({}), '');
});

Deno.test('near-identical abstracts differing only in whitespace, punctuation and HTML entities are the same text', () => {
  const noisy = ABSTRACT.replace(/ /g, '  ').replace(/\./g, ' .').replace('6.1 mmHg', '6.1&nbsp;mmHg').replace('first-line', 'first&#8209;line').replace('randomised', '<i>randomised</i>');
  const d = decide(cand({ content: noisy, summary: '' }), [atom('a')]);
  assertEquals(d, { action: 'duplicate', of: 'a', reason: 'same_text', score: 1 });
  const t = decide(cand({ title: TITLE.toUpperCase().replace(':', ' -') }), [atom('a')]);
  assertEquals(t.action === 'duplicate' && t.reason, 'same_text', 'title case and punctuation');
});

Deno.test('an abstract with a small edit is a near duplicate above the threshold', () => {
  const edited = ABSTRACT.replace('These findings support', 'Our findings support') + ' Trial registered.';
  const s = textSimilarity(edited, ABSTRACT);
  assert(s >= NEAR_TEXT && s < 1, `similarity ${s}`);
  const d = decide(cand({ content: edited, summary: '' }), [atom('a')]);
  assertEquals(d.action === 'duplicate' && d.reason, 'near_text');
  assertEquals(d.action === 'duplicate' && d.score, Math.round(s * 1000) / 1000);
});

Deno.test('a genuinely different abstract just under the threshold is inserted', () => {
  // Change enough words to land just below NEAR_TEXT; the title is unchanged, so only the body decides.
  const ws = ABSTRACT.split(' ');
  let changed = ABSTRACT, s = 1;
  for (let i = ws.length - 1; i > 0 && s >= NEAR_TEXT; i -= 7) { ws[i] = 'zz' + i; changed = ws.join(' '); s = textSimilarity(changed, ABSTRACT); }
  assert(s < NEAR_TEXT && s > NEAR_TEXT - 0.1, `similarity ${s} should sit just under ${NEAR_TEXT}`);
  assertEquals(decide(cand({ content: changed, summary: '' }), [atom('a')]), { action: 'insert' });
});

Deno.test('the same title with different content is inserted', () => {
  const other = 'This review summarises observational evidence on salt intake, potassium and blood pressure across forty cohort studies ' +
    'in Europe and Asia, and discusses the limits of dietary recall, residual confounding and publication bias in the field, ' +
    'concluding that population salt reduction remains the best supported measure.';
  assertEquals(decide(cand({ content: other, summary: '' }), [atom('a')]), { action: 'insert' });
});

Deno.test('near-identical text under a different title is inserted (two Wikipedia articles with similar leads)', () => {
  const lead = (name: string, place: string) => `${name} is a village in the ${place} district of the region, in the north of the country. ` +
    'It lies on the river about ten kilometres from the district centre, and at the last census it had a population of a little under ' +
    'one thousand people, most of whom work in farming, forestry or the nearby town.';
  const a: DedupExisting = { id: 'w1', source_id: WIKI, url: 'https://en.wikipedia.org/wiki/Alpha', title: 'Alpha', content: lead('Alpha', 'Northern'), status: 'verified' };
  const b: DedupRecord = { source_id: 'src-wikipedia-es', url: 'https://es.wikipedia.org/wiki/Beta', title: 'Beta', content: lead('Beta', 'Northern') };
  assert(textSimilarity(a.content!, b.content!) > 0.85, 'the leads really are close');
  assert(titleSimilarity(a.title, b.title) < TITLE_MIN);
  assertEquals(decide(b, [a]), { action: 'insert' });
});

Deno.test('short texts need an exact normalised match; fuzzy matching is not trusted on them', () => {
  const short = 'Species of beetle found in the forests of central Europe and Asia minor.';
  assert(short.split(' ').length < MIN_WORDS);
  assertEquals(decide(cand({ title: 'Carabus x', content: short, summary: '' }), [atom('a', { title: 'Carabus x', content: short.replace('minor', 'Minor!'), summary: '' })]).action, 'duplicate');
  assertEquals(decide(cand({ title: 'Carabus x', content: short + ' Common.', summary: '' }), [atom('a', { title: 'Carabus x', content: short, summary: '' })]), { action: 'insert' });
  assertEquals(decide(cand({ title: 'X', content: 'tiny', summary: '' }), [atom('a', { title: 'X', content: 'tiny', summary: '' })]), { action: 'insert' }, 'too short to judge at all');
});

Deno.test('the closest near duplicate wins when several qualify; nothing to compare means insert', () => {
  const close = ABSTRACT.replace('These findings support', 'Our findings support').replace('Adherence was high', 'Adherence was good');
  const closer = ABSTRACT.replace('These findings', 'The findings');
  const d = decide(cand(), [atom('far', { content: close, summary: '' }), atom('near', { source_id: OPENALEX, content: closer, summary: '' })]);
  assertEquals(d.action === 'duplicate' && d.of, 'near');
  assertEquals(decide(cand(), []), { action: 'insert' });
});

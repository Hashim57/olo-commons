// deno test --allow-read tests/
// Source diversity in rank(): at most two atoms of one source in the first six
// results, unless the question names the source (issue #76, part 3).
import { assert, assertEquals } from './_assert.ts';
import { DIVERSITY_PER_SOURCE, DIVERSITY_WITHIN, diversify, type Hit, namesSource, queryTerms, rank } from '../functions/olo-query/rank.ts';

const atom = (id: string, source_slug: string, title: string, summary = '', extra: Record<string, unknown> = {}): Hit => ({
  id, source_slug, source: { arxiv: 'arXiv', pubmed: 'PubMed', wikipedia: 'Wikipedia', wikipedia_es: 'Wikipedia (español)', wikinews: 'Wikinews', archive_org: 'Internet Archive', data_gov: 'Data.gov' }[source_slug] ?? source_slug,
  title, summary, url: `https://example.org/${id}`, credibility: 80, ...extra,
});
const ids = (list: Hit[]) => list.map(h => h.id);

// A ranked list as rank() would hand to diversify(): six arXiv abstracts about coral, then the others.
const coral = [
  atom('a1', 'arxiv', 'Coral reef recovery after bleaching, a model'),
  atom('a2', 'arxiv', 'Thermal stress and coral bleaching'),
  atom('a3', 'arxiv', 'Reef recovery trajectories'),
  atom('w1', 'wikipedia', 'Coral bleaching'),
  atom('a4', 'arxiv', 'Symbiont shuffling in corals'),
  atom('n1', 'wikinews', 'Great Barrier Reef shows signs of recovery'),
  atom('p1', 'pubmed', 'Coral recovery after mass bleaching events'),
  atom('a5', 'arxiv', 'Ocean warming and reefs'),
  atom('a6', 'arxiv', 'Coral calcification rates'),
];

Deno.test('constants: two per source in the first six', () => {
  assertEquals(DIVERSITY_PER_SOURCE, 2);
  assertEquals(DIVERSITY_WITHIN, 6);
});

Deno.test('diversify sets the third same-source atom aside, right after the block, in order', () => {
  const out = diversify(coral, queryTerms('how do coral reefs recover after bleaching'));
  // the block takes a1 and a2 (arXiv is then full), w1, n1 and p1; every remaining atom is a third arXiv one,
  // so the block ends at five, the set-aside atoms follow in their order and nothing else moves
  assertEquals(ids(out), ['a1', 'a2', 'w1', 'n1', 'p1', 'a3', 'a4', 'a5', 'a6']);
  assertEquals(out.length, coral.length, 'nothing is dropped');
  assertEquals(new Set(ids(out)).size, coral.length, 'nothing is duplicated');
});

Deno.test('diversify fills the block from further down when a different source is there', () => {
  const list = [...coral.slice(0, 5), atom('d1', 'data_gov', 'Coral reef monitoring dataset'), ...coral.slice(5)];
  const out = diversify(list, queryTerms('coral reef recovery'));
  assertEquals(ids(out).slice(0, 6), ['a1', 'a2', 'w1', 'd1', 'n1', 'p1']);
  const block = out.slice(0, 6).map(h => h.source_slug);
  for (const s of new Set(block)) assert(block.filter(x => x === s).length <= 2, `${s} at most twice in the first six`);
  assertEquals(ids(out).slice(6), ['a3', 'a4', 'a5', 'a6'], 'set-aside atoms follow in their order, then the rest');
});

Deno.test('a list with no third same-source atom in the block is unchanged', () => {
  const mixed = [atom('w1', 'wikipedia', 'A'), atom('a1', 'arxiv', 'B'), atom('p1', 'pubmed', 'C'), atom('w2', 'wikipedia', 'D'), atom('a2', 'arxiv', 'E'), atom('n1', 'wikinews', 'F'), atom('w3', 'wikipedia', 'G'), atom('w4', 'wikipedia', 'H')];
  assertEquals(ids(diversify(mixed, queryTerms('anything at all'))), ids(mixed));
});

Deno.test('a list no longer than the block is never reordered', () => {
  const six = coral.slice(0, 6);
  assertEquals(ids(diversify(six, queryTerms('coral'))), ids(six));
  assertEquals(ids(diversify([], queryTerms('coral'))), []);
});

Deno.test('the question naming the source lifts the cap for that source only', () => {
  for (const q of ['what do arxiv papers say about coral recovery', 'coral bleaching on arXiv']) {
    assertEquals(ids(diversify(coral, queryTerms(q))), ids(coral), q);
  }
  // naming another source changes nothing for arXiv
  assertEquals(ids(diversify(coral, queryTerms('coral recovery according to wikipedia'))).slice(0, 5), ['a1', 'a2', 'w1', 'n1', 'p1']);
});

Deno.test('namesSource reads names, slugs and their words', () => {
  const t = (q: string) => queryTerms(q);
  assert(namesSource(t('according to Wikipedia'), atom('x', 'wikipedia', '')));
  assert(namesSource(t('según wikipedia'), atom('x', 'wikipedia_es', '')), 'the Spanish Wikipedia is still Wikipedia');
  assert(namesSource(t('pubmed studies on sleep'), atom('x', 'pubmed', '')));
  assert(namesSource(t('what is on data.gov about rainfall'), atom('x', 'data_gov', '')), 'data.gov by its second word');
  assert(namesSource(t('texts in the internet archive'), atom('x', 'archive_org', '')), '"archive" names the Internet Archive');
  assert(!namesSource(t('internet speed in 2020'), atom('x', 'archive_org', '')), '"internet" alone does not');
  assert(!namesSource(t('open data on rainfall'), atom('x', 'data_gov', '')), '"data" alone does not');
  assert(!namesSource(t('how do coral reefs recover'), atom('x', 'arxiv', '')));
  assert(!namesSource(t('wikinews coverage'), atom('x', 'wikipedia', '')), 'Wikinews is not Wikipedia');
});

Deno.test('an atom without a source slug is counted under its source name, and without either on its own', () => {
  const noSlug = [1, 2, 3, 4, 5, 6, 7].map(i => ({ id: `s${i}`, source: 'PubMed', title: `t${i}`, summary: '' } as Hit));
  const out = diversify([...noSlug, atom('w1', 'wikipedia', 'W')], queryTerms('sleep'));
  assertEquals(ids(out).slice(0, 3), ['s1', 's2', 'w1'], 'the name groups them');
  const bare = [1, 2, 3, 4, 5, 6, 7].map(i => ({ id: `b${i}`, title: `t${i}`, summary: '' } as Hit));
  assertEquals(ids(diversify(bare, queryTerms('sleep'))), ids(bare), 'no source, no grouping');
});

Deno.test('rank applies the cap after duplicates are demoted and before k', () => {
  const semantic = coral.map((h, i) => ({ ...h, similarity: 0.9 - i * 0.01 }));
  const out = rank('how do coral reefs recover after bleaching', semantic, [], 6);
  assertEquals(out.length, 6);
  // only three atoms of other sources exist, so the block holds two arXiv atoms and those three, and the sixth
  // place goes to the first set-aside arXiv atom rather than staying empty
  const slugs = out.map(h => h.source_slug);
  assertEquals(slugs.slice(0, 5).filter(s => s === 'arxiv').length, 2);
  assert(ids(out).slice(0, 5).includes('w1') && ids(out).slice(0, 5).includes('n1') && ids(out).slice(0, 5).includes('p1'), 'the three other sources reach the top five');
  assertEquals(slugs[5], 'arxiv');
  // k larger than the block: the set-aside arXiv atoms are still returned, after the block
  const eight = rank('how do coral reefs recover after bleaching', semantic, [], 8);
  assertEquals(eight.length, 8);
  assert(ids(eight).includes('a3') && ids(eight).includes('a4'), 'set-aside atoms stay in a k of 8');
  // the asker names arXiv: the fusion and coverage order stands, nothing is set aside
  const named = rank('coral reefs recovery arxiv', semantic, [], 6);
  assertEquals(named.filter(h => h.source_slug === 'arxiv').length >= 3, true);
});

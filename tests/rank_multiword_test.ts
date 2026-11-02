// deno test --allow-read tests/
// Multi-word ranking: rank() against a fixture of realistic retriever output,
// plus a unit test for each scoring piece.
import { assert, assertEquals } from './_assert.ts';
import {
  BODY_HIT, coverage, demoteDuplicates, fuse, type Fused, type Hit, hitStrength, poolIdf, proximity, queryTerms, rank, RANK_WEIGHTS, stem, termMatches, terms,
} from '../functions/olo-query/rank.ts';

type Atom = { id: string; title: string; summary: string; source: string; url: string; credibility: number };
type Question = { q: string; note: string; semantic: [string, number][]; keyword: [string, number][]; k: number; expect_top: string[]; forbid_top: string[]; fails_before: boolean };
const fixture: { atoms: Atom[]; questions: Question[] } = JSON.parse(await Deno.readTextFile(new URL('./fixtures/rank_multiword.json', import.meta.url)));
const atoms = new Map(fixture.atoms.map(a => [a.id, a]));

function lists(c: Question): { semantic: Hit[]; keyword: Hit[] } {
  const get = (id: string) => { const a = atoms.get(id); if (!a) throw new Error(`fixture: unknown atom ${id}`); return a; };
  return {
    semantic: c.semantic.map(([id, similarity]) => ({ ...get(id), similarity })),
    keyword: c.keyword.map(([id, r]) => ({ ...get(id), rank: r })),
  };
}
function verdict(c: Question, out: Fused[]): string | null {
  const ids = out.map(r => r.id);
  const missing = c.expect_top.filter(id => !ids.includes(id)), unwanted = c.forbid_top.filter(id => ids.includes(id));
  return missing.length || unwanted.length ? `"${c.q}": got ${JSON.stringify(ids)}, missing ${JSON.stringify(missing)}, unwanted ${JSON.stringify(unwanted)}` : null;
}

Deno.test('fixture is well formed', () => {
  assert(fixture.atoms.length >= 20 && fixture.atoms.length <= 40, 'pool of 20 to 40 atoms');
  assertEquals(new Set(fixture.atoms.map(a => a.id)).size, fixture.atoms.length);
  for (const c of fixture.questions) { lists(c); assert(c.expect_top.length <= c.k, `${c.q}: expect_top fits in k`); }
});

for (const c of fixture.questions) {
  Deno.test(`rank puts the right atoms on top: ${c.q}`, () => {
    const { semantic, keyword } = lists(c);
    const out = rank(c.q, semantic, keyword, c.k);
    assertEquals(out.length, c.k);
    const bad = verdict(c, out);
    assert(!bad, bad || '');
  });
}

Deno.test('plain fusion fails exactly the cases marked fails_before (the reason rank exists)', () => {
  const failing = fixture.questions.filter(c => { const { semantic, keyword } = lists(c); return verdict(c, fuse(semantic, keyword, c.k)) !== null; }).map(c => c.q);
  assertEquals(failing, fixture.questions.filter(c => c.fails_before).map(c => c.q));
  assert(failing.length >= 3, 'the fixture shows real failures of the old ranking');
});

// ---- stemming and terms ----

Deno.test('stem joins common inflections and leaves short words and numbers alone', () => {
  assertEquals(['founded', 'founding', 'found'].map(stem), ['found', 'found', 'found']);
  assertEquals(['reefs', 'reef', 'cities', 'city', 'studies'].map(stem), ['reef', 'reef', 'city', 'city', 'study']);
  assertEquals(['beaches', 'boxes', 'causes', 'caused', 'cause'].map(stem), ['beach', 'box', 'caus', 'caus', 'caus']);
  assertEquals(['vaccine', 'vaccination', 'vaccines'].map(stem), ['vaccin', 'vaccin', 'vaccin']);
  assertEquals(['glass', 'virus', 'photosynthesis', 'mmr', 'co2', '1971'].map(stem), ['glass', 'virus', 'photosynthesis', 'mmr', 'co2', '1971']);
  assertEquals(stem('need'), 'need'); // stripping "ed" would leave too little
});

Deno.test('terms drops stopwords and one-letter words; queryTerms keeps the asked order once each', () => {
  assertEquals(terms('How do coral reefs recover after bleaching?'), ['coral', 'reef', 'recover', 'after', 'bleach']);
  assertEquals(queryTerms('what is the effect of the effects of a b'), ['effect']);
  assertEquals(queryTerms('what is it'), []);
  assertEquals(queryTerms('¿Cuándo se fundó Gutenberg?'), ['cuándo', 'se', 'fundó', 'gutenberg']);
});

Deno.test('termMatches allows a short prefix for long stems only', () => {
  assert(termMatches('recover', 'recovery'));
  assert(termMatches('recover', 'recovere'));
  assert(!termMatches('sea', 'seas2'));
  assert(!termMatches('art', 'arts'));          // short stems must match exactly
  assert(!termMatches('vaccine', 'vaccinated')); // more than two letters apart
});

// ---- scoring pieces ----

const doc = (title: string, summary = '') => ({ title: terms(title), body: terms(summary) });

Deno.test('hitStrength: a title hit is worth more than a summary hit', () => {
  const d = doc('Sea level rise', 'caused by thermal expansion');
  assertEquals(hitStrength(d, 'sea'), 1);
  assertEquals(hitStrength(d, stem('caused')), BODY_HIT);
  assertEquals(hitStrength(d, 'glacier'), 0);
});

Deno.test('poolIdf: a term few atoms share weighs more than one they all share', () => {
  const docs = [doc('Vaccine'), doc('MMR vaccine'), doc('Vaccine safety')];
  const [mmr, vaccine] = poolIdf(['mmr', 'vaccine'], docs);
  assert(mmr > vaccine, `mmr ${mmr} should outweigh vaccine ${vaccine}`);
  assert(vaccine > 0, 'a common term still weighs a little');
});

Deno.test('coverage rewards distinct terms, not repetition', () => {
  const q = queryTerms('python list comprehension');
  const snake = doc('Python', 'python python python python');
  const comp = doc('List comprehension', 'a construct in Python');
  const idf = poolIdf(q, [snake, comp]);
  assert(coverage(comp, q, idf) > coverage(snake, q, idf));
  assertEquals(coverage(doc('Anything'), [], []), 0);
  assertEquals(coverage(doc('Python list comprehension'), q, [1, 1, 1]), 1);
});

Deno.test('proximity: adjacent in order scores 1, near scores 0.5, apart scores 0', () => {
  const q = queryTerms('sea level rise');
  assertEquals(proximity(doc('Sea level rise'), q), 1);
  assertEquals(proximity(doc('Rise and level of the sea'), q), 0.5); // both pairs within three words, out of order
  assertEquals(proximity(doc('Sea', 'level of glaciers worldwide shrinking fast now rise'), q), 0);
  assertEquals(proximity(doc('Sea level rise'), ['sea']), 0);
});

Deno.test('demoteDuplicates moves mirrors and same-url copies behind the rest, keeping order', () => {
  const s = 'Long term surveys show reefs recover within fifteen years.';
  const list = [
    { id: 'a', title: 'Reef recovery', summary: s, url: 'https://a' },
    { id: 'b', title: 'Reef Recovery.', summary: s + ' Mirror.', url: 'https://b' },
    { id: 'c', title: 'Coral bleaching', summary: 'Corals expel algae.', url: 'https://c' },
    { id: 'd', title: 'Another title', summary: 'Different words here.', url: 'https://a' },
    { id: 'e', title: 'Reef recovery', summary: 'A completely different paper with the same short title.', url: 'https://e' },
  ];
  assertEquals(demoteDuplicates(list).map(x => x.id), ['a', 'c', 'e', 'b', 'd']);
});

// ---- rank() as a whole ----

Deno.test('rank weights sum to one and scores stay within 0..1', () => {
  assertEquals(Math.round(Object.values(RANK_WEIGHTS).reduce((s, w) => s + w, 0) * 1e9) / 1e9, 1);
  const c = fixture.questions[0], { semantic, keyword } = lists(c);
  for (const r of rank(c.q, semantic, keyword, 20)) assert(r.score >= 0 && r.score <= 1, `score ${r.score}`);
});

Deno.test('rank keeps fusion order for a question with no content words, and handles empty input', () => {
  const sem = [{ id: 'a', similarity: 0.9, title: 'A' }, { id: 'b', similarity: 0.8, title: 'B' }];
  const key = [{ id: 'c', rank: 1, title: 'C' }];
  assertEquals(rank('what is it', sem, key, 5).map(r => r.id), fuse(sem, key, 5).map(r => r.id));
  assertEquals(rank('coral reefs', [], [], 5), []);
  assertEquals(rank('coral reefs', sem, key, 0), []);
});

Deno.test('rank keeps match labels and one entry per id', () => {
  const sem = [{ id: 'a', similarity: 0.9, title: 'Coral reef' }, { id: 'b', similarity: 0.8, title: 'Ocean' }];
  const key = [{ id: 'a', rank: 1, title: 'Coral reef' }, { id: 'c', rank: 0.5, title: 'Coral reef fish' }, { id: 'a', rank: 1 }];
  const out = rank('coral reef fish', sem, key, 10);
  assertEquals(new Set(out.map(r => r.id)).size, out.length);
  const label = Object.fromEntries(out.map(r => [r.id, r.match]));
  assertEquals([label.a, label.b, label.c], ['both', 'semantic', 'keyword']);
});

Deno.test('rank: the meaning retriever still wins when no atom has the words', () => {
  const sem = [{ id: 'p', similarity: 0.86, title: 'Photosynthesis', summary: 'Light energy becomes chemical energy.' }, { id: 'q', similarity: 0.8, title: 'Ocean currents', summary: 'Water moves.' }];
  assertEquals(rank('how do leaves feed themselves', sem, [], 2).map(r => r.id), ['p', 'q']);
});

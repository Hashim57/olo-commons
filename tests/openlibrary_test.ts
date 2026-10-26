import { assert, assertEquals } from './_assert.ts';
import { openLibraryApiBase, openLibraryCandidate, openLibraryCandidates, openLibrarySearchUrl, openLibrarySubjects, openLibrarySubjectUrl, OPENLIBRARY_API, OPENLIBRARY_LICENCE } from '../functions/olo-ingest/openlibrary.ts';

// Shaped like a search.json doc with fields=key,title,author_name,first_publish_year,subject,language,edition_count
// (https://openlibrary.org/dev/docs/api/search). Not captured live: the API host is unreachable from the build container.
function doc(over: Record<string, unknown> = {}) {
  return {
    key: '/works/OL45804W',
    title: 'Fantastic Mr Fox',
    author_name: ['Roald Dahl'],
    first_publish_year: 1970,
    subject: ['Animals', 'Foxes', 'Accessible book', 'Protected DAISY', 'nyt:childrens-middle-grade=2009-01-01', 'Foxes', 'Farmers', 'collectionID:dahl'],
    language: ['eng', 'spa', 'fre'],
    edition_count: 82,
    // Fields the mapper must never read, even when the API sends them.
    description: 'A blurb copied from the publisher.',
    first_sentence: ['Down in the valley there were three farms.'],
    ...over,
  };
}

Deno.test('openLibraryCandidate writes its own text from catalogue facts, with a stable work URL and CC0', () => {
  const c = openLibraryCandidate(doc())!;
  assertEquals(c.external_id, 'OL45804W');
  assertEquals(c.url, 'https://openlibrary.org/works/OL45804W');
  assertEquals(c.title, 'Fantastic Mr Fox');
  assertEquals(c.summary, 'Fantastic Mr Fox is a book by Roald Dahl, first published in 1970. Subjects: Animals; Foxes; Farmers.');
  assert(c.content!.endsWith('Open Library catalogues 82 editions in 3 languages.'));
  assertEquals(c.authors, ['Roald Dahl']);
  assertEquals(c.licence, OPENLIBRARY_LICENCE);
  assertEquals(c.lang, 'en');
  assertEquals(c.published_at, undefined);
});

Deno.test('descriptions and first sentences never reach the atom', () => {
  const all = JSON.stringify(openLibraryCandidate(doc()));
  assert(!all.includes('blurb'), 'description leaked');
  assert(!all.includes('Down in the valley'), 'first sentence leaked');
});

Deno.test('openLibrarySubjects drops copy and reading-list tags, tagged values and duplicates', () => {
  assertEquals(openLibrarySubjects(['History', 'history', 'In library', 'Lending library', 'OverDrive', 'nyt:x=1', 'Rome -- History.', '<b>War</b>']), ['History', 'Rome -- History', 'War']);
  assertEquals(openLibrarySubjects(undefined), []);
  assertEquals(openLibrarySubjects(Array.from({ length: 30 }, (_, i) => `Subject ${i}`)).length, 10);
});

Deno.test('authors are joined in plain English and the year is optional', () => {
  const two = openLibraryCandidate(doc({ author_name: ['A. Writer', 'B. Writer'], first_publish_year: undefined }))!;
  assert(two.summary!.startsWith('Fantastic Mr Fox is a book by A. Writer and B. Writer. Subjects:'));
  const three = openLibraryCandidate(doc({ author_name: ['A', 'B', 'C'] }))!;
  assert(three.summary!.includes('by A, B and C, first published'));
  const one = openLibraryCandidate(doc({ edition_count: 1, language: ['eng'] }))!;
  assert(one.content!.endsWith('Open Library catalogues 1 edition.'));
});

Deno.test('non-works, untitled, authorless or subject-poor docs are skipped', () => {
  assertEquals(openLibraryCandidate(doc({ key: '/books/OL1M' })), null);
  assertEquals(openLibraryCandidate(doc({ key: '/works/../x' })), null);
  assertEquals(openLibraryCandidate(doc({ title: '' })), null);
  assertEquals(openLibraryCandidate(doc({ author_name: [] })), null);
  assertEquals(openLibraryCandidate(doc({ subject: ['Accessible book', 'Fiction'] })), null);
  assertEquals(openLibraryCandidate(null), null);
});

Deno.test('openLibraryCandidates reads the docs array and stops at n', () => {
  const resp = { numFound: 4, start: 0, docs: [doc(), doc({ key: '/works/OL2W' }), doc({ author_name: [] }), doc({ key: '/works/OL3W' })] };
  assertEquals(openLibraryCandidates(resp, 2).length, 2);
  assertEquals(openLibraryCandidates(resp, 10).length, 3);
  assertEquals(openLibraryCandidates({}, 5).length, 0);
});

Deno.test('search URLs ask for explicit fields, cap the page and fall back to the default host', () => {
  assertEquals(openLibraryApiBase('http://evil.example'), OPENLIBRARY_API);
  assertEquals(openLibraryApiBase('https://openlibrary.org/'), OPENLIBRARY_API);
  assertEquals(openLibrarySubjectUrl('', 'natural history', 99, 9),
    'https://openlibrary.org/search.json?q=subject%3A%22natural%20history%22&fields=key,title,author_name,first_publish_year,subject,language,edition_count&sort=random.hourly&limit=50&page=5');
  assertEquals(openLibrarySearchUrl('', 'roman <i>roads</i>', 6),
    'https://openlibrary.org/search.json?q=roman%20roads&fields=key,title,author_name,first_publish_year,subject,language,edition_count&limit=6');
});

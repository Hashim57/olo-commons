// Re-check helpers: pure functions, tested without the network. index.ts does the fetching.

export type Stored = { id: string; url: string; content_hash: string; source_revision?: string | null };

/**
 * What to do after reading an atom's source page again.
 *   same:    the text is byte-identical (or the revision id has not moved): only observed_at advances.
 *   changed: the text differs: the old atom is superseded and the new text stored as a new atom.
 * A revision id that is unchanged is trusted even if our stored hash differs (cleaning rules may have changed),
 * so a cleaning tweak never rewrites history.
 */
export function planRecheck(old: Stored, fresh: { hash: string; revision?: string | null }): { action: 'same' | 'changed' } {
  if (fresh.revision && old.source_revision && String(fresh.revision) === String(old.source_revision)) return { action: 'same' };
  if (fresh.hash === old.content_hash) return { action: 'same' };
  return { action: 'changed' };
}

/**
 * The address the superseded atom keeps, so its url stays unique and still resolves to the text it quotes:
 * Wikipedia's permanent link to that revision, Wikidata's oldid link, otherwise the live url with a revision fragment.
 */
export function permalink(slug: string, url: string, revision: string | null): string {
  const rev = revision && /^\d+$/.test(revision) ? revision : null;
  if ((slug === 'wikipedia' || slug === 'wikipedia_es') && rev) {
    const m = url.match(/^https:\/\/([a-z]+)\.wikipedia\.org\/wiki\/(.+)$/);
    if (m) return `https://${m[1]}.wikipedia.org/w/index.php?title=${m[2]}&oldid=${rev}`;
  }
  if (slug === 'wikidata' && rev) {
    const m = url.match(/^https:\/\/www\.wikidata\.org\/wiki\/(Q\d+)$/);
    if (m) return `https://www.wikidata.org/w/index.php?title=${m[1]}&oldid=${rev}`;
  }
  return url + (url.includes('#') ? '' : '#') + (rev ? `rev=${rev}` : `observed=${new Date().toISOString().slice(0, 10)}`);
}

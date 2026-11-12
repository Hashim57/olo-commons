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

/** The REST summary of one Wikipedia page, the call the ingester and the re-check both read. */
export function wikiSummaryUrl(lang: string, title: string): string {
  return `https://${lang}.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(title.replace(/ /g, '_'))}`;
}

/** True for the error get() throws when a source answers 404. */
export function isNotFound(e: unknown): boolean {
  return /^404 /.test(e instanceof Error ? e.message : String(e));
}

/**
 * The action API's question about one title, asked when the summary endpoint answers 404: that endpoint says 404 for a
 * deleted page but also for a title that moved, and only action=query (with redirects followed) tells the two apart.
 */
export function wikiPageStateUrl(lang: string, title: string): string {
  return `https://${lang}.wikipedia.org/w/api.php?action=query&titles=${encodeURIComponent(title)}&redirects=1&format=json&formatversion=2`;
}

export type PageState = { state: 'gone' } | { state: 'at'; title: string } | { state: 'unknown' };

/**
 * What action=query says about the one title asked for: gone (deleted, or never a page), at a title (the same one, a
 * normalised one or a redirect's target), or unknown when the answer has no page in it. Both API format versions are
 * read: formatversion=2 gives pages as an array with `missing: true`, the old one an object with `missing: ""`.
 */
export function wikiPageState(r: any): PageState {
  const pages = r?.query?.pages;
  const list: any[] = Array.isArray(pages) ? pages : (pages && typeof pages === 'object' ? Object.values(pages) : []);
  const p = list[0];
  if (!p || typeof p !== 'object') return { state: 'unknown' };
  if (p.missing !== undefined || p.invalid !== undefined) return { state: 'gone' };
  if (typeof p.title === 'string' && p.title) return { state: 'at', title: p.title };
  return { state: 'unknown' };
}

/** What wbgetentities says about one item: gone (deleted or merged away), or present with its current revision. */
export function wikidataEntityState(e: any, id: string): { state: 'gone' } | { state: 'at'; revision?: string } {
  const ent = e?.entities?.[id];
  if (!ent || typeof ent !== 'object' || ent.missing !== undefined) return { state: 'gone' };
  return { state: 'at', revision: ent.lastrevid ? String(ent.lastrevid) : undefined };
}

/**
 * The row update that retires an atom whose source page is gone, or is no longer an article that can be quoted (a
 * redirect, a disambiguation page, an item that lost its description): the atom keeps its text as history under the
 * permanent link of the revision it was read from, closes its validity today and leaves search (status superseded, no
 * successor). Nothing is deleted. Before this existed such an atom was left as it was, and since its observed_at never
 * moved it stayed the oldest row and took one of the re-check slots in every run for good: a deleted article did exactly
 * that from 26 October to 12 November 2026, as a 404 in every run note.
 */
export function retireUpdate(slug: string, old: Stored, today = new Date()): { status: 'superseded'; valid_to: string; url: string } {
  return { status: 'superseded', valid_to: today.toISOString().slice(0, 10), url: permalink(slug, old.url, old.source_revision ? String(old.source_revision) : null) };
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

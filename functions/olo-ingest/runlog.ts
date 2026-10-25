// What went wrong in an ingest run, written into olo_ingest_runs.note so a
// starving source can be diagnosed from the run log alone. Before this, a
// connector that threw only added one to `failed`, and a source with zero atoms
// after days (data_gov in October 2026) left no trace of why.
//
// Pure functions, no I/O, tested in tests/runlog_test.ts.

export type RunError = { slug: string; message: string };

const PER_MESSAGE = 90;    // characters kept of one error message
const TOTAL = 480;         // characters of the whole errors clause (the note column is text, but the page reads it)

/** One line of text for an error thrown by a connector: no newlines, no stack, bounded. */
export function errorText(e: unknown): string {
  const raw = e instanceof Error ? e.message : typeof e === 'string' ? e : (() => { try { return JSON.stringify(e); } catch { return String(e); } })();
  const flat = String(raw ?? '').replace(/\s+/g, ' ').trim();
  if (!flat) return 'unknown error';
  return flat.length > PER_MESSAGE ? flat.slice(0, PER_MESSAGE - 1) + '…' : flat;
}

/** Keep the first error per source and count the rest, so one noisy connector cannot flood the note. */
export function collect(errors: RunError[]): { slug: string; message: string; count: number }[] {
  const by = new Map<string, { slug: string; message: string; count: number }>();
  for (const e of errors) {
    const slug = (e.slug || 'run').slice(0, 40);
    const cur = by.get(slug);
    if (cur) cur.count++;
    else by.set(slug, { slug, message: errorText(e.message), count: 1 });
  }
  return Array.from(by.values());
}

/**
 * The clause appended to the run note, or '' when nothing failed. Example:
 *   ' errors: data_gov: 403 https://catalog.data.gov/api/3/action/package_search?... (x3); pubmed: TimeoutError: signal timed out'
 * Bounded to TOTAL characters; when sources have to be dropped, the clause ends with how many.
 */
export function errorNote(errors: RunError[]): string {
  const items = collect(errors);
  if (!items.length) return '';
  const parts: string[] = [];
  let used = 0, dropped = 0;
  for (const it of items) {
    const p = `${it.slug}: ${it.message}${it.count > 1 ? ` (x${it.count})` : ''}`;
    if (used + p.length + 2 > TOTAL) { dropped++; continue; }
    parts.push(p); used += p.length + 2;
  }
  return ` errors: ${parts.join('; ')}${dropped ? `; and ${dropped} more source${dropped > 1 ? 's' : ''}` : ''}`;
}

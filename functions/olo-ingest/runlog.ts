// What went wrong in an ingest run, written into olo_ingest_runs.note so a
// starving source can be diagnosed from the run log alone. Before this, a
// connector that threw only added one to `failed`, and a source with zero atoms
// after days (data_gov in October 2026) left no trace of why.
//
// Pure functions, no I/O, tested in tests/runlog_test.ts.

export type RunError = { slug: string; message: string };

const PER_MESSAGE = 90;    // characters kept of one error message
const TOTAL = 480;         // characters of the whole errors clause (the note column is text, but the page reads it)

/** A URL query parameter that carries a credential; its value never reaches the run note. */
const SECRET_PARAM = /([?&](?:api_key|apikey|key|wskey|token|access_token)=)[^&\s]*/gi;

/** The message with every credential-carrying query parameter value replaced by ***. */
export function redactSecrets(s: string): string {
  return s.replace(SECRET_PARAM, '$1***');
}

/** One line of text for an error thrown by a connector: no newlines, no stack, no credentials, bounded. */
export function errorText(e: unknown): string {
  const raw = e instanceof Error ? e.message : typeof e === 'string' ? e : (() => { try { return JSON.stringify(e); } catch { return String(e); } })();
  const flat = redactSecrets(String(raw ?? '')).replace(/\s+/g, ' ').trim();
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

/** Everything a run's note is made of; index.ts fills it in as the run goes. */
export type NoteParts = {
  /** Who started the run: 'cron', 'manual' or a name the caller passed. */
  source: string;
  /** The gap-filling clause, ' (gap "topic": 2 added of 5 found)', or ''. */
  gap?: string;
  /** The re-check clauses, ' (wikipedia re-check: 3 unchanged, 0 updated)', or ''. */
  recheck?: string;
  sightings?: number;
  stubs?: number;
  withEmail?: number;
  courtRecords?: number;
  /** The resting clause from restingNote, or ''. */
  resting?: string;
  /** True when the forty-second budget stopped the run before every source had its turn. */
  cutShort?: boolean;
  errors: RunError[];
};

/**
 * The run note from its parts. Written at every checkpoint, not only at the end, so a run the Edge runtime kills
 * (two of twelve on 13 November 2026) keeps the clauses it had earned; before this such a run was closed by
 * run_olo_ingest with the bare word "cron" and no trace of which source it was on or what had failed.
 */
export function composeNote(p: NoteParts): string {
  return (p.source || 'manual') + (p.gap || '') + (p.recheck || '')
    + (p.sightings ? ` (${p.sightings} duplicates recorded as sightings)` : '')
    + (p.stubs ? ` (${p.stubs} stubs skipped)` : '')
    + (p.withEmail ? ` (${p.withEmail} with an email address skipped)` : '')
    + (p.courtRecords ? ` (${p.courtRecords} court records skipped)` : '')
    + (p.resting || '')
    + (p.cutShort ? ' (time budget reached, continues next run)' : '')
    + errorNote(p.errors);
}

/**
 * The sources a finished run's note names as failed in the random walk, out of the slugs given. The errors clause
 * reads ' errors: arxiv: Signal timed out.; gutenberg: Signal timed out.'; a gap-search failure is written
 * 'arxiv (gap search): ...' and does not count, because it is a different call. Only known slugs are matched, so
 * text inside an error message cannot name a source by accident.
 */
export function failedInNote(note: string | null | undefined, slugs: string[]): Set<string> {
  const out = new Set<string>();
  const at = (note || '').indexOf(' errors: ');
  if (at < 0) return out;
  const clause = (note || '').slice(at + ' errors: '.length);
  for (const slug of slugs) {
    if (clause.startsWith(`${slug}: `) || clause.includes(`; ${slug}: `)) out.add(slug);
  }
  return out;
}

/** How many of the last REST_WINDOW finished runs that asked a source must fail before it rests. */
export const REST_AFTER = 4;

/**
 * How many recent runs that asked the source are read. Four failures in a row rest it as before; so do four failures
 * among the last six runs. Why: on 28 November 2026 Project Gutenberg was down for maintenance (its site answered
 * 503) and gutendex answered in 19 to 20 s or not at all, so the 20 s call failed in 7 of 9 runs between 10:18 and
 * 12:18 UTC but never four times in a row, the one answer inside the limit reset the streak each time, and the
 * source never rested: 20 s of most forty-second runs went to it while ten other sources queued behind.
 */
export const REST_WINDOW = 6;

/** The sources a finished run's note names as resting, out of the slugs given (the clause restingNote writes). */
export function restingInNote(note: string | null | undefined, slugs: string[]): Set<string> {
  const out = new Set<string>();
  const m = /\(resting after \d+ failed runs: ([^)]*)\)/.exec(note || '');
  if (!m) return out;
  const named = new Set(m[1].split(',').map((x) => x.trim()));
  for (const slug of slugs) if (named.has(slug)) out.add(slug);
  return out;
}

/**
 * The sources to leave out of this run. A source starts resting when REST_AFTER of the last REST_WINDOW finished
 * runs that asked it failed it (four in a row, or four of six), and keeps resting while every run that asked it
 * since has failed it. A resting source is still asked once an hour (the run that starts in the first quarter of
 * the hour), so it comes back by itself within the hour once it answers again: one answered probe ends the rest,
 * whatever the window before the rest held. Why: on 19 November 2026 Project Gutenberg was down for maintenance and
 * gutendex timed out at 20 s in 9 of 12 runs, half of every forty-second run spent waiting on a call that could not
 * answer while ten other sources queued behind it. `recentNotes` is newest first.
 *
 * A run in which a source rested is not a run in which it answered, so it neither ends the streak nor counts in
 * it. Before 20 November 2026 the resting run itself ended the streak, so a source that never answered rested in
 * only one run of five: OpenAlex answered 429 in 10 of the 12 runs between 09:33 and 12:18 UTC that day and
 * rested in 2.
 */
export function restingSources(recentNotes: (string | null | undefined)[], slugs: string[], now: Date): Set<string> {
  const out = new Set<string>();
  if (now.getUTCMinutes() < 15) return out;
  const parsed = recentNotes.map((n) => ({ failed: failedInNote(n, slugs), rested: restingInNote(n, slugs) }));
  for (const slug of slugs) {
    let failures = 0, asked = 0;
    for (const p of parsed) {
      // A rest in the history: it goes on only while every run that asked the source since (if any) failed it. One
      // answered probe wakes the source, and the failures before the rest are not counted against it again.
      if (p.rested.has(slug)) { if (failures === asked) out.add(slug); break; }
      asked++;
      if (p.failed.has(slug)) failures++;
      if (failures >= REST_AFTER) { out.add(slug); break; }
      if (asked >= REST_WINDOW) break;
    }
  }
  return out;
}

/** The run-note clause for resting sources, ' (resting after 4 failed runs: gutenberg)', or ''. */
export function restingNote(resting: Set<string> | string[]): string {
  const list = Array.from(resting).sort();
  return list.length ? ` (resting after ${REST_AFTER} failed runs: ${list.join(', ')})` : '';
}

// Pure helpers for the keyless bulk export (GET ?export=1). No I/O, so
// `deno test tests/` covers them without the network. index.ts does the call.

/**
 * An ISO 8601 timestamp as Postgres prints one: date, optional time with up to
 * nine fractional digits, optional zone (Z, +hh, +hh:mm or +hhmm). Nothing else
 * reaches the RPC, so the text is as safe to pass through as a parsed Date.
 */
const ISO = /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?)?(?:Z|[+-]\d{2}(?::?\d{2})?)?$/i;

/**
 * The `after` cursor to hand olo_export(). Postgres keeps created_at to the
 * microsecond and olo_export() hands the last one back as `next_after`, but
 * `new Date(after).toISOString()` kept only milliseconds, so the cursor came
 * back a little earlier than the row it named and `created_at > p_after`
 * matched that row again: every 500-atom page repeated its last atom, and the
 * offline snapshot carried one duplicate per page. A well-formed timestamp is
 * now passed through as written; anything else is normalised through Date,
 * and a value Date cannot read gives null (the caller answers 400).
 */
export function exportAfter(raw: string | null | undefined): string | null {
  const s = String(raw ?? '').trim();
  if (!s) return '1970-01-01T00:00:00.000Z';
  if (isNaN(Date.parse(s))) return null;
  return ISO.test(s) ? s : new Date(s).toISOString();
}

/** The page size for the export: 1 to 500, 500 when absent or unreadable. */
export function exportLimit(raw: string | null | undefined): number {
  const n = Math.floor(Number(raw)) || 500;
  return Math.max(1, Math.min(n, 500));
}

// One reading of licence URLs for every connector that takes a licence per item.
// Pure, no I/O, covered by tests/licence_test.ts.
//
// The Commons keeps only what may be passed on with at most attribution or
// share-alike (README, "Adding a source"): the public domain in its two Creative
// Commons spellings, CC0, CC BY and CC BY-SA. Anything else (NC, ND, "in
// copyright", a rights statement, an unknown URL, no URL at all) is refused,
// and the stored licence line is the canonical short name, never the URL and
// never a guess.

/** Open licence URLs, matched with the scheme, "www." and any trailing slash removed. */
const OPEN_LICENCES: Array<[RegExp, (m: RegExpMatchArray) => string]> = [
  [/^creativecommons\.org\/publicdomain\/mark\/1\.0$/, () => 'Public Domain Mark 1.0'],
  [/^creativecommons\.org\/publicdomain\/zero\/1\.0$/, () => 'CC0 1.0'],
  // The retired CC Public Domain Dedication and Certification, which older Internet Archive items still carry.
  [/^creativecommons\.org\/licenses\/publicdomain(?:\/1\.0)?$/, () => 'Public domain (CC Public Domain Dedication)'],
  [/^creativecommons\.org\/licenses\/by\/(\d\.\d)(?:\/[a-z]{2}(?:-[a-z]+)?)?$/, (m) => `CC BY ${m[1]}`],
  [/^creativecommons\.org\/licenses\/by-sa\/(\d\.\d)(?:\/[a-z]{2}(?:-[a-z]+)?)?$/, (m) => `CC BY-SA ${m[1]}`],
];

export function normaliseLicenceUrl(u: string): string {
  return u.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/^www\./, '').replace(/\/+$/, '');
}

/**
 * The canonical licence name for a licence URL, or null when the item may not
 * be passed on. Takes a string or a list (the first entry is read), so a
 * connector can hand it the field as the API returns it.
 */
export function openLicence(url: unknown): string | null {
  const raw = Array.isArray(url) ? url[0] : url;
  if (typeof raw !== 'string' || !raw.trim()) return null;
  const n = normaliseLicenceUrl(raw);
  for (const [re, name] of OPEN_LICENCES) { const m = n.match(re); if (m) return name(m); }
  return null;
}

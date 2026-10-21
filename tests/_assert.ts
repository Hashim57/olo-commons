// Tiny assertion helper so the tests need no network to run: `deno test tests/`.
export function assertEquals(actual: unknown, expected: unknown, msg = '') {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${msg ? msg + ': ' : ''}expected ${e}, got ${a}`);
}
export function assert(cond: unknown, msg = 'assertion failed') { if (!cond) throw new Error(msg); }

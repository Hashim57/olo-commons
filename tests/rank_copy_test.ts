// deno test tests/
// olo-answer carries its own copy of rank.ts because each Edge Function is
// deployed from its own directory. This keeps the two copies identical.
import { assertEquals } from './_assert.ts';

Deno.test('olo-answer/rank.ts is byte-identical to olo-query/rank.ts', async () => {
  const a = await Deno.readTextFile(new URL('../functions/olo-query/rank.ts', import.meta.url));
  const b = await Deno.readTextFile(new URL('../functions/olo-answer/rank.ts', import.meta.url));
  assertEquals(a, b);
});

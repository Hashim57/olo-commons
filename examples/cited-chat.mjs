// examples/cited-chat.mjs
// A chatbot that cites. Asks Olo Commons first, then your LLM, and prints the
// answer with numbered sources. Node 18+. No key needed for the Commons.
//
//   node examples/cited-chat.mjs "how do coral reefs recover after bleaching"
//
// Plug in any model in `answer()`: Claude, GPT, a local Ollama model. The
// Commons gives the facts and the citations; the model writes the prose.

const OLO = 'https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-query';
const question = process.argv.slice(2).join(' ') || 'how do coral reefs recover after bleaching';

const r = await fetch(OLO, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ q: question, k: 6 }) });
const { results } = await r.json();
if (!results.length) { console.log('The Commons has nothing on that yet. Propose a source at https://heliusnetwork.app/olo/#propose'); process.exit(0); }

const context = results.map((a, i) => `[${i + 1}] ${a.title}\n${a.summary}\n(${a.source}, ${a.licence}) ${a.url}`).join('\n\n');
const prompt = `Answer the question using only the sources below. Cite with [n] after each claim. If the sources do not cover it, say so.\n\nSources:\n${context}\n\nQuestion: ${question}`;

async function answer(prompt) {
  // Replace this with a real model call, for example (Anthropic):
  // const res = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers: { 'x-api-key': process.env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' }, body: JSON.stringify({ model: 'claude-sonnet-4-5', max_tokens: 600, messages: [{ role: 'user', content: prompt }] }) });
  // return (await res.json()).content[0].text;
  return 'Model not configured. Here is what the Commons found:\n' + results.map((a, i) => `[${i + 1}] ${a.summary.slice(0, 160)}…`).join('\n');
}

console.log(await answer(prompt));
console.log('\nSources');
results.forEach((a, i) => console.log(`[${i + 1}] ${a.citation}`));

// Pure helpers for olo-answer: prompt building, sentence splitting, citation
// parsing and verdict parsing. No I/O, so `deno test tests/` covers them
// without the Edge runtime, a model or a key.
//
// The answer loop is: retrieve passages, ask a language model for a short
// answer in which every sentence ends with the ids of the passages it rests on
// (like "[a1][b2]"), split that answer into sentences, and ask the verifier
// (Zeus) for each sentence whether its cited passages support, contradict or
// do not cover it. The page then shows each sentence with its verdict.

export type Passage = { id: string; source: string; url: string; text: string; title?: string };
export const LABELS = ['supported', 'contradicted', 'not_covered'] as const;
export type Label = typeof LABELS[number];
export type Verdict = { label: Label; evidence: { passage: string; quote: string }[]; rationale: string };

/** Short ids for the model to cite: p1, p2, ... in retrieval order. */
export function labelPassages(results: { id: string; source_slug?: string; source?: string; url?: string; title?: string; summary?: string; content?: string }[], maxChars = 900): Passage[] {
  return results.map((r, i) => ({
    id: `p${i + 1}`,
    source: String(r.source_slug || r.source || ''),
    url: String(r.url || ''),
    title: String(r.title || ''),
    text: String(r.content || r.summary || '').replace(/\s+/g, ' ').trim().slice(0, maxChars),
  })).filter(p => p.text.length > 0);
}

export const ANSWER_SYSTEM = [
  'You are Olo, an assistant that answers only from the numbered passages it is given.',
  'Write two to four plain sentences. After every sentence put the ids of the passages that support it in square brackets, like [p1] or [p1][p3].',
  'Use only facts stated in the passages. Do not add background knowledge. If the passages do not answer the question, write exactly: The Commons does not cover this yet.',
  'No headings, no lists, no markdown.',
].join(' ');

export function renderAnswerPrompt(q: string, passages: Passage[]): string {
  const ps = passages.map(p => `[${p.id}] (${p.source}${p.title ? `: ${p.title}` : ''}) ${p.text}`).join('\n\n');
  return `Question: ${q}\n\nPassages:\n${ps}`;
}

/** The exact Zeus prompt from zeus/train_lora.py, so a served adapter and the fallback model see the same format. */
export const ZEUS_SYSTEM = 'You are Zeus, the verification layer of Olo. Given a claim and numbered passages, answer with one JSON object: '
  + '{"label": "supported" | "contradicted" | "not_covered", "evidence": [{"passage": "<id>", "quote": "<exact words from that passage>"}], "rationale": "<one sentence>"}. '
  + 'Quote only words that appear in a passage. If no passage covers the claim, label not_covered with empty evidence.';

export function renderZeusPrompt(claim: string, passages: Passage[]): string {
  const ps = passages.map(p => `[${p.id}] (${p.source}) ${p.text}`).join('\n\n');
  return `Claim: ${claim}\n\nPassages:\n${ps}`;
}

export const NOT_COVERED_TEXT = 'The Commons does not cover this yet.';

/**
 * Split a model answer into sentences, each with the passage ids it cites.
 * Citations are the bracketed ids at the end of (or inside) a sentence; they
 * are stripped from the sentence text. Sentences without a terminal mark are
 * kept. Empty strings never come back.
 */
export function splitSentences(answer: string): { text: string; citations: string[] }[] {
  let flat = String(answer || '').replace(/\s+/g, ' ').trim();
  if (!flat) return [];
  // a citation group written after the full stop belongs to the sentence before it: "1971. [p1] It" -> "1971.[p1] It"
  flat = flat.replace(/([.!?]["')]*)\s+((?:\[p\d+\]\s*)+)/g, (_, end, cites) => end + cites.replace(/\s+/g, '') + ' ');
  // split after . ! ? (optionally followed by closing quotes and citations) when a space and a capital, digit, quote or bracket follows
  const parts = flat.split(/(?<=[.!?]["')]*(?:\[p\d+\])*)\s+(?=["'(\[A-Z0-9])/);
  const out: { text: string; citations: string[] }[] = [];
  for (const part of parts) {
    const citations = Array.from(part.matchAll(/\[(p\d+)\]/g)).map(m => m[1]);
    const text = part.replace(/\s*\[p\d+\]/g, '').replace(/\s+/g, ' ').trim();
    if (text) out.push({ text, citations: Array.from(new Set(citations)) });
  }
  return out;
}

/** Parse the verifier's JSON. Returns null when it is not a usable verdict. */
export function parseVerdict(text: string): Verdict | null {
  const m = String(text || '').match(/\{[\s\S]*\}/);
  if (!m) return null;
  let o: any;
  try { o = JSON.parse(m[0]); } catch { return null; }
  if (!o || !LABELS.includes(o.label)) return null;
  const evidence = Array.isArray(o.evidence) ? o.evidence.filter((e: any) => e && typeof e.passage === 'string' && typeof e.quote === 'string').map((e: any) => ({ passage: e.passage, quote: e.quote })) : [];
  return { label: o.label, evidence, rationale: typeof o.rationale === 'string' ? o.rationale.slice(0, 300) : '' };
}

/**
 * Keep only evidence whose quote really appears in the named passage (what
 * eval.py calls evidence_hit). A supported or contradicted verdict with no
 * surviving evidence is downgraded to not_covered, because a verdict the
 * passages cannot show is not one the page should assert.
 */
export function checkEvidence(v: Verdict, passages: Passage[]): Verdict & { evidence_checked: boolean } {
  const texts = new Map(passages.map(p => [p.id, p.text]));
  const evidence = v.evidence.filter(e => e.quote.trim() && (texts.get(e.passage) || '').includes(e.quote));
  if (v.label === 'not_covered') return { label: 'not_covered', evidence: [], rationale: v.rationale, evidence_checked: true };
  if (!evidence.length) return { label: 'not_covered', evidence: [], rationale: v.rationale ? v.rationale + ' (no quoted evidence found in the passages)' : 'No quoted evidence found in the passages.', evidence_checked: false };
  return { label: v.label, evidence, rationale: v.rationale, evidence_checked: true };
}

/** One line for the page: how many sentences each verdict got. */
export function summarise(verdicts: { label: Label }[]): { supported: number; contradicted: number; not_covered: number } {
  const s = { supported: 0, contradicted: 0, not_covered: 0 };
  for (const v of verdicts) s[v.label]++;
  return s;
}

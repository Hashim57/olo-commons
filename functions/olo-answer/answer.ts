// Pure helpers for olo-answer: prompt building, sentence splitting, citation
// parsing and verdict parsing. No I/O, so `deno test tests/` covers them
// without the Edge runtime, a model or a key.
//
// The answer loop is: retrieve passages, ask a language model for a short
// answer in which every sentence ends with the ids of the passages it rests on
// (like "[a1][b2]"), split that answer into sentences, and ask the verifier
// (Zeus) for each sentence whether its cited passages support, contradict or
// do not cover it. The page then shows each sentence with its verdict.

export type Passage = { id: string; source: string; url: string; text: string; title?: string; published?: string };
export const LABELS = ['supported', 'contradicted', 'not_covered'] as const;
export type Label = typeof LABELS[number];
export type Verdict = { label: Label; evidence: { passage: string; quote: string }[]; rationale: string };

/**
 * Sources whose publication date is a fact about the text itself: a news story, a paper. A Wikinews
 * story says "On April 30th" and only its date says which year; without it the writer added the
 * year from the question, and the figure check rightly found no "2005" in the passage (answer eval
 * of 2026-11-18, questions q037, q042, q045). For an encyclopedia, a catalogue or a dataset the
 * stored date is a revision or an upload, not something the text asserts, so it is left out.
 */
export const DATED_SOURCES = new Set(['wikinews', 'arxiv', 'pubmed', 'openalex', 'europepmc', 'doaj']);
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/** "Published 1 May 2005." for a dated source with a valid ISO date, else "". */
export function publishedLine(source: string, published: unknown): string {
  if (!DATED_SOURCES.has(source)) return '';
  const m = String(published || '').match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return '';
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return '';
  // Papers carry 1 January when only the year is known; say the year alone rather than invent a day.
  return mo === 1 && d === 1 && source !== 'wikinews' ? `Published ${y}.` : `Published ${d} ${MONTH_NAMES[mo - 1]} ${y}.`;
}

/**
 * True when a body already opens with its title (a Wikidata description, a Gutenberg summary that opens
 * with the quoted title), compared without case, quotes or punctuation.
 */
export function opensWithTitle(title: string, body: string): boolean {
  const k = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
  const t = k(title);
  return !t || k(body.slice(0, title.length + 40)).startsWith(t);
}

/** "Title." for the start of a passage: the title as written, with a full stop unless it ends in one. */
function titleLine(title: string): string {
  const t = title.replace(/\s+/g, ' ').trim();
  return t ? (/[.!?]$/.test(t) ? t : t + '.') : '';
}

/**
 * Short ids for the model to cite: p1, p2, ... in retrieval order. Each passage's text starts with its
 * title, then, for a dated source, its publication date ("TUTTI: Parallel CKKS Bootstrapping in under
 * 3 ms on CPU. Published 9 November 2026. ..."), so the writer, Zeus and the figure check all read the
 * same text, and a quote of the title or the date is a quote of the passage. The writer used to see the
 * title and Zeus not: TUTTI's "under 3 ms" is in its title only, and Zeus could not check it (answer eval
 * of 2026-11-18, q063); a Wikinews headline often holds the story's main figure.
 */
export function labelPassages(results: { id: string; source_slug?: string; source?: string; url?: string; title?: string; summary?: string; content?: string; published_at?: string | null }[], maxChars = 900): Passage[] {
  return results.map((r, i) => {
    const source = String(r.source_slug || r.source || '');
    const body = String(r.content || r.summary || '').replace(/\s+/g, ' ').trim();
    const dated = body ? publishedLine(source, r.published_at) : '';
    const title = String(r.title || '');
    const lead = body && title && !opensWithTitle(title, body) ? titleLine(title) : '';
    return {
      id: `p${i + 1}`,
      source,
      url: String(r.url || ''),
      title,
      ...(dated ? { published: String(r.published_at).slice(0, 10) } : {}),
      text: [lead, dated, body].filter(Boolean).join(' ').slice(0, maxChars),
    };
  }).filter(p => p.text.length > 0);
}

export const ANSWER_SYSTEM = [
  'You are Olo, an assistant that answers only from the numbered passages it is given.',
  'Write two to four plain sentences. After every sentence put the ids of the passages that support it in square brackets, like [p1] or [p1][p3].',
  'Use only facts stated in the passages. Do not add background knowledge. If the passages do not answer the question, write exactly: The Commons does not cover this yet.',
  // Each sentence is checked on its own, without the one before it: "She established it in 1924" cannot be
  // checked, "Ada Mackenzie founded the Ladies Golf Club of Toronto in 1924" can (answer eval, 2026-11-18).
  // A paper's title used as a name ("When will androids outnumber humans paper states that...") read as a name
  // swap to the verifier (q061); a plain noun phrase ("The study of humanoid robot populations") does not.
  'Every sentence is checked on its own, so begin each one with a plain noun phrase that names what it is about: a person, a place, a work, or for a study a phrase such as "The meta-analysis of facial botulinum toxin injections". Never begin with a pronoun such as he, she, it, they, his or this, and never use a title as if it were a name. This holds in whatever language you answer.',
  'Give a date or year only when the passage states it; a passage that begins "Published ..." states that date.',
  'No headings, no lists, no markdown.',
].join(' ');

export function renderAnswerPrompt(q: string, passages: Passage[]): string {
  // The title is in the text now (labelPassages); it is named in the label only for a passage built elsewhere without it.
  const ps = passages.map(p => `[${p.id}] (${p.source}${p.title && !opensWithTitle(p.title, p.text) ? `: ${p.title}` : ''}) ${p.text}`).join('\n\n');
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

const EN_MARKERS = new Set(['the', 'of', 'and', 'is', 'was', 'were', 'are', 'with', 'that', 'for', 'by', 'his', 'her', 'its', 'has', 'had', 'this', 'which', 'from', 'it', 'as', 'at', 'an']);
const OTHER_MARKERS = new Set(['el', 'la', 'los', 'las', 'del', 'que', 'y', 'un', 'una', 'es', 'fue', 'por', 'con', 'para', 'se', 'su', 'al', 'como', 'desde', 'entre', 'le', 'les', 'des', 'du', 'et', 'est', 'une', 'der', 'die', 'das', 'und', 'ist', 'il', 'di', 'della', 'che', 'em', 'da', 'não', 'uma']);

/**
 * True when a sentence is English, the only language Zeus has been trained on (build_dataset.py
 * skips every other). On the answer eval of 2026-11-18 Zeus flagged 8 of 9 Spanish sentences that
 * the passages state almost word for word, so a sentence in another language goes to the fallback
 * verifier instead, and the response says so per sentence (`checked_by`). A sentence with no marker
 * words at all (a name and a number) counts as English.
 */
export function zeusReads(text: string): boolean {
  const ws = String(text || '').toLowerCase().match(/[\p{L}']+/gu) || [];
  let en = 0, other = 0;
  for (const w of ws) { if (EN_MARKERS.has(w)) en++; else if (OTHER_MARKERS.has(w)) other++; }
  if (/[ñ¿¡ãõçß]/i.test(text)) other++;
  return en >= other;
}

/**
 * Split a model answer into sentences, each with the passage ids it cites.
 * Citations are the bracketed ids at the end of (or inside) a sentence; they
 * are stripped from the sentence text. Sentences without a terminal mark are
 * kept. Empty strings never come back.
 */
/**
 * Words after which a full stop does not end a sentence. "St. Mark's Masonic Lodge", "George A. Romero"
 * and "William F. Buckley" were each split in two by the answer eval of 2026-11-18 (q024, q029, q046),
 * and the verifier rightly found neither half in the passage. A lone capital letter is an initial.
 */
// "U.S.", "U.K.", "D.C.", "Ph.D.": letters and stops with no space; "the U.S. Census Bureau" was split in two (q064).
const NO_BREAK_AFTER = /(?:^|[\s(])(?:(?:\p{L}\.)+\p{L}|\p{Lu}|St|Mt|Ft|Dr|Mr|Mrs|Ms|Mme|Jr|Sr|Prof|Gen|Col|Capt|Lt|Sgt|Gov|Sen|Rep|Rev|Hon|Fr|Sra|Dña|No|Nos|Vol|vs|etc|approx|ca|cf|e\.g|i\.e|Inc|Co|Corp|Ltd|Bros|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.$/u;

export function splitSentences(answer: string): { text: string; citations: string[] }[] {
  let flat = String(answer || '').replace(/\s+/g, ' ').trim();
  if (!flat) return [];
  // Some models cite with lenticular or full-width brackets ("【p1】", "［p1］"); read them as [p1].
  flat = flat.replace(/[【［]\s*(p\d+)\s*[】］]/g, '[$1]');
  // a citation group written after the full stop belongs to the sentence before it: "1971. [p1] It" -> "1971.[p1] It"
  flat = flat.replace(/([.!?]["')]*)\s+((?:\[p\d+\]\s*)+)/g, (_, end, cites) => end + cites.replace(/\s+/g, '') + ' ');
  // split after . ! ? (optionally followed by closing quotes and citations) when a space and a capital, digit, quote or bracket follows
  const pieces = flat.split(/(?<=[.!?]["')]*(?:\[p\d+\])*)\s+(?=["'(\[\p{Lu}0-9¿¡])/u);
  // Join back a piece that ended on an initial or an abbreviation (and carries no citation yet).
  const parts: string[] = [];
  for (const piece of pieces) {
    const prev = parts[parts.length - 1];
    if (prev !== undefined && NO_BREAK_AFTER.test(prev) && !/\[p\d+\]$/.test(prev)) parts[parts.length - 1] = prev + ' ' + piece;
    else parts.push(piece);
  }
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
/**
 * A quote and a passage compared as a reader would: case, runs of spaces, curly and straight quotes,
 * dashes and a trailing full stop or comma do not make a quote inexact. The words must still be the
 * passage's own, in its order.
 */
export function quoteKey(t: string): string {
  return checkText(t).toLowerCase().replace(/[\u2018\u2019\u201a\u2032`]/g, "'").replace(/[\u201c\u201d\u201e\u2033«»]/g, '"')
    .replace(/[\u2010-\u2015\u2212]/g, '-').replace(/[\u00a0\u2009\u202f]/g, ' ').replace(/\s+/g, ' ').trim().replace(/[.,;:]+$/, '');
}

/**
 * A sentence as the checks read it: a multiplication sign after a number is the letter x ("10×" is "10x",
 * as abstracts write it; Zeus called the writer's "10×" a different value, q059), and a no-break or thin
 * space is a space. What the reader sees is not changed.
 */
export function checkText(t: string): string {
  return String(t || '').replace(/(\d)\s?\u00d7/g, '$1x').replace(/[\u00a0\u2009\u202f]/g, ' ');
}

export function checkEvidence(v: Verdict, passages: Passage[]): Verdict & { evidence_checked: boolean } {
  const texts = new Map(passages.map(p => [p.id, quoteKey(p.text)]));
  const evidence = v.evidence.filter(e => { const k = quoteKey(e.quote); return k.length >= 3 && (texts.get(e.passage) || '').includes(k); });
  if (v.label === 'not_covered') return { label: 'not_covered', evidence: [], rationale: v.rationale, evidence_checked: true };
  if (!evidence.length) return { label: 'not_covered', evidence: [], rationale: v.rationale ? v.rationale + ' (no quoted evidence found in the passages)' : 'No quoted evidence found in the passages.', evidence_checked: false };
  return { label: v.label, evidence, rationale: v.rationale, evidence_checked: true };
}

/** One line for the page: how many sentences each verdict got. */
export function summarise(verdicts: ({ label: Label } | { verdict: Label })[]): { supported: number; contradicted: number; not_covered: number } {
  const s = { supported: 0, contradicted: 0, not_covered: 0 };
  for (const v of verdicts) {
    const l = 'label' in v ? v.label : v.verdict;
    if (l in s) s[l]++;
  }
  return s;
}

const STOP = new Set(['the', 'and', 'for', 'are', 'was', 'were', 'what', 'when', 'where', 'who', 'why', 'how', 'does', 'did', 'this', 'that', 'with', 'from', 'into', 'about', 'which', 'there', 'their', 'have', 'has', 'had', 'been', 'being', 'can', 'could', 'would', 'should', 'made', 'make', 'many', 'much', 'some', 'any', 'all', 'not', 'but', 'you', 'your', 'its', 'our', 'one', 'two', 'tell', 'explain', 'please', 'is', 'of', 'in', 'on', 'to', 'a', 'an']);
const words = (t: string) => (t.toLowerCase().match(/[\p{L}\p{N}]+/gu) || []).filter(w => w.length >= 3 && !STOP.has(w));
/** The content words of a text (lower case, three letters or more, common words left out), as the extractive answer and the check mode read them. */
export const contentWords = words;

/**
 * The answer when no writing model can be reached: the passages' own sentences
 * that share the most content words with the question, one per passage, at
 * most three. Each sentence is a verbatim quote of its passage, so it is
 * "supported" by construction and its evidence is itself; the response marks
 * the whole answer as extractive so nobody mistakes it for a written one.
 */
export function extractiveAnswer(q: string, passages: Passage[], max = 3): { text: string; citations: string[]; verdict: Label; evidence: { passage: string; quote: string }[]; rationale: string; evidence_checked: boolean }[] {
  const qw = new Set(words(q));
  if (!qw.size) return [];
  const need = qw.size === 1 ? 1 : 2;
  const picks: { p: Passage; s: string; score: number; order: number }[] = [];
  passages.forEach((p, order) => {
    // Question words already in the title are context: they count toward relevance, weigh less.
    const inTitle = new Set(words(p.title || '').filter(w => qw.has(w)));
    let best: { s: string; score: number } | null = null;
    for (const s of p.text.split(/(?<=[.!?])(?<!\b[A-Z]\.)(?<!\b(?:Mr|Mrs|Ms|Dr|St|Jr|Sr|Prof|No|vs|etc|e\.g|i\.e)\.)\s+(?=["'(\[]?[\p{Lu}0-9])/u)) {
      const t = s.trim();
      if (t.length < 40 || t.length > 320) continue;
      // the title and the publication line that labelPassages puts first are labels, not statements to quote
      if ((p.title && quoteKey(t) === quoteKey(titleLine(p.title))) || /^Published \d/.test(t)) continue;
      const hit = new Set(words(t).filter(w => qw.has(w)));
      if (!hit.size || new Set([...hit, ...inTitle]).size < need) continue;
      const score = [...hit].reduce((n, w) => n + (inTitle.has(w) ? 0.4 : 1), 0);
      if (!best || score > best.score) best = { s: t, score };
    }
    if (best) picks.push({ p, ...best, order });
  });
  picks.sort((a, b) => b.score - a.score || a.order - b.order);
  return picks.slice(0, max).map(({ p, s }) => ({
    text: s, citations: [p.id], verdict: 'supported' as Label,
    evidence: [{ passage: p.id, quote: s }], rationale: 'Quoted word for word from the passage.', evidence_checked: true,
  }));
}

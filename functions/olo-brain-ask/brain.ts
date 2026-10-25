// Pure logic for olo-brain-ask, tested without the Edge runtime (tests/brain_test.ts).
//
// A question someone asked Olo can become a small orb in the public Olo brain
// (heliusnetwork.app/olo#brain). Only the question text is kept, scrubbed of
// personal details; never who asked, never the answer, never the conversation.
// Anything that still looks personal after scrubbing, reads as a crisis, is
// abusive or is too short to mean anything is held for a person to review and
// never shown.

export const CLIENTS = ['web', 'ios', 'macos'] as const;
export type Client = typeof CLIENTS[number];
export const MAX_QUESTION = 500;
export const MAX_ATOMS = 12;
export const MIN_PUBLISHED = 8;
export const PER_HOUR = 30;
export const PER_HOUR_SERVICE = 3000;   // olo-web calls from one server address for every signed-in user
export const RECENT_DEFAULT = 200;
export const RECENT_MAX = 500;

export type Ask = { question: string; client: Client; atoms: string[]; answered: boolean };
export type HoldReason = 'personal' | 'crisis' | 'abuse' | 'too_short';
export type Verdict = { text: string; status: 'published' | 'held'; reason: HoldReason | null; scrubbed: string[] };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Control characters, zero-width and bidi marks: removed first so they cannot split a pattern.
// deno-lint-ignore no-control-regex
const INVISIBLE = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F­​-‏‪-‮⁠-⁯﻿]/g;

/** Collapse whitespace, drop invisible characters, normalise compatibility forms (fullwidth digits and so on). */
export function oneLine(s: unknown): string {
  return String(s ?? '').normalize('NFKC').replace(INVISIBLE, '').replace(/\s+/g, ' ').trim();
}

/** The validated request, or the reason it is refused (400). */
export function parseAsk(body: unknown): { ok: true; value: Ask } | { ok: false; error: string } {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, error: 'body must be a JSON object' };
  const b = body as Record<string, unknown>;
  if (typeof b.question !== 'string') return { ok: false, error: 'question is required (1 to 500 characters)' };
  const question = oneLine(b.question);
  if (question.length < 1 || question.length > MAX_QUESTION) return { ok: false, error: 'question must be 1 to 500 characters' };
  const client = String(b.client ?? '');
  if (!(CLIENTS as readonly string[]).includes(client)) return { ok: false, error: `client must be one of ${CLIENTS.join(', ')}` };
  if (b.atoms !== undefined && !Array.isArray(b.atoms)) return { ok: false, error: 'atoms must be an array of atom ids' };
  if (b.answered !== undefined && typeof b.answered !== 'boolean') return { ok: false, error: 'answered must be true or false' };
  const atoms: string[] = [];
  for (const a of (b.atoms as unknown[] | undefined) ?? []) {
    if (typeof a !== 'string' || !UUID.test(a.trim())) continue;   // only Commons atom ids; anything else could carry text
    const id = a.trim().toLowerCase();
    if (!atoms.includes(id)) atoms.push(id);
    if (atoms.length >= MAX_ATOMS) break;
  }
  return { ok: true, value: { question, client: client as Client, atoms, answered: b.answered === true } };
}

// ---------------------------------------------------------------------------
// Scrubbing. Order matters: emails before handles, URLs before domains and
// digits, IBANs and phones before plain digit runs.
// ---------------------------------------------------------------------------
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g;
const URL_FULL = /\b(?:https?:\/\/|www\.)[^\s<>"']+/gi;
// A bare domain followed by a path or query: example.com/a/b?x=1
const URL_BARE = /\b((?:[a-z0-9-]+\.)+[a-z]{2,24})([/?#][^\s<>"']*)/gi;
const IBAN = /\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b/g;
const PHONES = [
  /(?:\+|\b00)\d{1,3}[\s.-]?(?:\(0?\d{1,4}\)|\d{1,4})(?:[\s.-]?\d{2,4}){2,4}\b/g,            // international: +44 20 7946 0958, 0033 1 23 45 67 89
  /(?:\(0\d{2,5}\)|\b0\d{2,5})[\s.-]?\d{3,4}[\s.-]?\d{3,4}\b/g,                            // UK national: 07700 900123, (020) 7946 0958, 0161 496 0000
  /(?:\(\d{3}\)|\b\d{3})[\s.-]\d{3}[\s.-]\d{4}\b/g,                                               // North American: (415) 555-0132
];
const UK_POSTCODE = /\b(?:GIR ?0AA|[A-PR-UWYZ][A-HK-Y]?\d[A-Z\d]? ?\d[ABD-HJLNP-UW-Z]{2})\b/gi;
const NI_NUMBER = /\b[A-Z]{2} ?\d{2} ?\d{2} ?\d{2} ?[A-D]\b/gi;
const DIGIT_RUN = /\d(?:[ .-]?\d){5,}/g;
const HANDLE = /(^|[^\w@.\]])@[A-Za-z0-9_](?:[A-Za-z0-9_.]{0,28}[A-Za-z0-9_])?\b/g;
// Names: "my name is X" takes the next one to three words whatever their case; "I am X", "I'm X"
// and "call me X" take only capitalised words that are not ordinary words.
const MY_NAME = /\b(my name is|my name's|my names|i am called|i'm called|im called|they call me)\s+([\p{L}'-]+(?:\s+(?!(?:and|but|or|i|im|i'm|what|how|why|who|can|could|please|so|then|from|in|at|of)\b)[\p{L}'-]+){0,2})/giu;
const I_AM = /\b([Ii] am|[Ii]'m|[Ii]m|[Cc]all me)\s+((?:[A-Z][\p{Ll}'-]+)(?:\s+[A-Z][\p{Ll}'-]+){0,2})/gu;
const NOT_NAMES = new Set(['a', 'an', 'the', 'not', 'british', 'english', 'scottish', 'welsh', 'irish', 'european', 'american', 'french', 'german', 'spanish', 'italian', 'polish', 'dutch', 'indian', 'pakistani', 'chinese', 'japanese', 'african', 'muslim', 'christian', 'jewish', 'hindu', 'sikh', 'buddhist', 'catholic', 'atheist', 'vegan', 'vegetarian', 'christmas', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday', 'olo', 'zeus', 'helius', 'here', 'there', 'it', 'what', 'how', 'why', 'sorry', 'just', 'so', 'very', 'really', 'trying', 'looking', 'going', 'new', 'learning', 'interested', 'curious', 'wondering', 'confused', 'happy', 'sad', 'tired', 'ok', 'okay', 'fine']);

/** Replace personal details with placeholders. Returns the scrubbed text and the kinds removed. */
export function scrub(input: string): { text: string; scrubbed: string[] } {
  const kinds: string[] = [];
  const hit = (k: string) => { if (!kinds.includes(k)) kinds.push(k); };
  let t = oneLine(input);
  t = t.replace(EMAIL, () => { hit('email'); return '[email]'; });
  t = t.replace(URL_FULL, (m) => {
    hit('url');
    const raw = m.replace(/[),.;:!?]+$/, '');
    const trail = m.slice(raw.length);
    try { return new URL(/^https?:/i.test(raw) ? raw : 'https://' + raw).hostname.replace(/^www\./, '').toLowerCase() + trail; } catch { return '[link]' + trail; }
  });
  t = t.replace(URL_BARE, (_m, host: string) => { hit('url'); return host.toLowerCase().replace(/^www\./, ''); });
  t = t.replace(IBAN, (m) => ((m.match(/\d/g) || []).length >= 6 ? (hit('iban'), '[account]') : m));
  for (const re of PHONES) t = t.replace(re, (m) => ((m.match(/\d/g) || []).length >= 9 ? (hit('phone'), '[phone]') : m));
  t = t.replace(NI_NUMBER, () => { hit('id'); return '[id]'; });
  // "the A1 1st junction" is a road and an ordinal, not a postcode: lower-case ordinals are left alone.
  t = t.replace(UK_POSTCODE, (m) => (/\d(st|nd|rd|th)$/.test(m) ? m : (hit('postcode'), '[postcode]')));
  t = t.replace(DIGIT_RUN, () => { hit('number'); return '[number]'; });
  t = t.replace(HANDLE, (_m, pre: string) => { hit('handle'); return pre + '[handle]'; });
  t = t.replace(MY_NAME, (_m, lead: string) => { hit('name'); return lead + ' [name]'; });
  t = t.replace(I_AM, (m, lead: string, name: string) => {
    if (NOT_NAMES.has(name.split(/\s+/)[0].toLowerCase())) return m;
    hit('name'); return lead + ' [name]';
  });
  return { text: t.replace(/\s+/g, ' ').trim(), scrubbed: kinds };
}

// ---------------------------------------------------------------------------
// Hold rules.
// ---------------------------------------------------------------------------
// Still personal after scrubbing: someone sharing their own identifiers, address or a named relative.
const PERSONAL = [
  /\b(my|our)\s+(home\s+|house\s+|full\s+|postal\s+)?(address|postcode|post code|zip code|password|passcode|pin( number)?|login|username|account number|sort code|bank details|card( number| details)?|credit card|debit card|national insurance( number)?|ni number|nhs number|passport( number)?|driving licen[cs]e|date of birth|dob|phone number|mobile number|number is|email|social security|ssn|tax code|utr|reference number|booking reference|case number|registration|reg plate|number plate)\b/i,
  /\bi live (at|on)\b/i,
  /\b(born on|date of birth|d\.o\.b)\b/i,
  /\bmy\s+(wife|husband|partner|son|daughter|child|kid|mum|mom|mother|dad|father|brother|sister|boss|manager|colleague|friend|neighbour|neighbor|ex|girlfriend|boyfriend|teacher|doctor|landlord|tenant)(?:'s)?\s+(?!(?:is|was|has|had|and|but|who|said|says|keeps|wants|thinks|will|would|can|could|does|did)\b)[A-Z][a-z]{2,}\b/,
];

const STREET = /\b\d{1,4}[a-z]?,?\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\s+(street|st|road|rd|avenue|ave|lane|ln|close|drive|dr|way|court|ct|crescent|place|pl|terrace|gardens|grove|square|mews|hill|row)\b/i;

// First-person self-harm or suicide language. Copied from olo-web client/src/lib/crisis.ts
// (detectCrisis); keep the two lists in step. Narrow on purpose: "suicide rates in the UK" is a
// fair public question, "I want to kill myself" is not something to put on a public page.
const FIRST_PERSON = /\b(i|i'?m|i am|me|myself|my life|my own life)\b/i;
const CRISIS = [
  /\b(kill|killing|end|ending|take|taking)\s+(myself|my\s+(own\s+)?life)\b/i,
  /\b(want|wanted|wanting|going|plan|planning|ready)\s+to\s+(die(?!\s+on\s+(this|that)\s+hill)|be dead|not (be alive|exist|wake up))\b/i,
  /\bwanna\s+die\b/i,
  /\b(don'?t|do not|no longer)\s+want\s+to\s+(live|be alive|be here( any ?more)?|wake up)\b/i,
  /\bbetter off dead\b/i,
  /\b(i'?m|i am|feel|feeling)\s+suicidal\b/i,
  /\b(commit|committing)\s+suicide\b/i,
  /\b(thinking|thought|thoughts)\s+(about|of)\s+(suicide|killing myself|ending it( all)?)\b/i,
  /\b(hurt|hurting|harm|harming|cut|cutting)\s+myself\b/i,
  /\bself[- ]harm(ing|ed)?\b/i,
  /\b(overdose|overdosing)\s+(on purpose|to die|myself)\b/i,
];
// Asking for a method is held whoever it is about.
const CRISIS_ANY = [/\b(suicide|self[- ]harm)\s+(method|methods|note|notes)\b/i, /\bhow\s+(to|do i|can i|could i)\s+(kill|hang|poison)\s+myself\b/i, /\bpainless(ly)?\s+(way|ways)\s+to\s+die\b/i];

// A small, conservative list: slurs and direct abuse only. Words with ordinary meanings are left out
// on purpose (a reviewer sees held items; a false hold costs little, a false publish costs more).
const ABUSE = [
  /\bn[i1!]gg(?:a|er|ers|as|az)\b/i,
  /\bf[a@]gg?[o0]ts?\b/i,
  /\bk[i1]kes?\b/i,
  /\bp[a@]k[i1]s?\b/i,
  /\bc[u*]nts?\b/i,
  /\bwh[o0]res?\b/i,
  /\bkys\b/i,
  /\b(go\s+)?kill\s+yourself\b/i,
  /\bi\s*(will|'ll|am going to|m going to)\s+(kill|rape|hurt|stab|shoot)\s+(you|u|him|her|them)\b/i,
  /\brape\s+(you|u|her|him)\b/i,
];

export function isCrisis(text: string): boolean {
  const t = oneLine(text);
  if (CRISIS_ANY.some((p) => p.test(t))) return true;
  if (t.length < 4 || !FIRST_PERSON.test(t)) return false;
  return CRISIS.some((p) => p.test(t));
}
export function isAbusive(text: string): boolean { return ABUSE.some((p) => p.test(oneLine(text))); }
export function looksPersonal(scrubbedText: string, kinds: string[] = []): boolean {
  // Three or more different kinds of detail in one question reads as someone describing themselves.
  if (kinds.length >= 3) return true;
  // A street address is public when it is 10 Downing Street, personal when it is where I live.
  if (STREET.test(scrubbedText) && FIRST_PERSON.test(scrubbedText)) return true;
  return PERSONAL.some((p) => p.test(scrubbedText));
}

/** Scrub, then decide: published, or held with the first reason that applies. Crisis and abuse are judged on the original words. */
export function judge(question: string): Verdict {
  const { text, scrubbed } = scrub(question);
  const original = oneLine(question);
  let reason: HoldReason | null = null;
  if (isCrisis(original) || isCrisis(text)) reason = 'crisis';
  else if (isAbusive(original) || isAbusive(text)) reason = 'abuse';
  else if (looksPersonal(text, scrubbed)) reason = 'personal';
  else if (text.replace(/\[(email|link|account|phone|id|postcode|number|handle|name)\]/g, '').replace(/\s+/g, ' ').trim().length < MIN_PUBLISHED) reason = 'too_short';
  return { text: text.slice(0, MAX_QUESTION), status: reason ? 'held' : 'published', reason, scrubbed };
}

/** The key for "the same question": case, punctuation, spacing and a trailing question mark do not matter. */
export function normalise(scrubbedText: string): string {
  return oneLine(scrubbedText).toLowerCase()
    .replace(/[‘’‛`]/g, "'")
    .replace(/[^\p{L}\p{N}\[\]' ]+/gu, ' ')
    .replace(/\s+/g, ' ').trim();
}

/** recent=N from the query string, bounded. */
export function recentLimit(v: string | null): number {
  const n = Math.floor(Number(v));
  if (!Number.isFinite(n) || n < 1) return RECENT_DEFAULT;
  return Math.min(RECENT_MAX, n);
}

/** Compare two secrets without leaking where they differ through timing. */
export function sameSecret(a: string, b: string): boolean {
  if (!a || !b) return false;
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/** The bearer token from an Authorization header, or ''. */
export function bearer(h: string | null): string {
  const m = /^Bearer\s+(\S+)$/i.exec(h || '');
  return m ? m[1] : '';
}

// Pure validation for olo-feedback, tested without the Edge runtime.
//
// A flag is one sentence Olo showed, the verdict it gave, what the person says it
// should be, and the passages it was checked against. Nothing else: never the
// question, never who asked, never an account id. The claim is bounded so a flag
// cannot be used to store arbitrary text.

export const CLIENTS = ['web', 'ios', 'macos', 'commons', 'api'] as const;
export const ANSWER_SOURCES = ['olo', 'commons', 'offline'] as const;
export const GIVEN = ['supported', 'contradicted', 'not_covered'] as const;
export const USER = ['supported', 'contradicted', 'not_covered', 'wrong_source', 'unclear'] as const;

export type Feedback = {
  client: typeof CLIENTS[number];
  answer_source: typeof ANSWER_SOURCES[number];
  claim: string;
  verdict_given: typeof GIVEN[number];
  verdict_user: typeof USER[number];
  passages: { atom?: string; url?: string; quote?: string }[];
  evidence_quote: string | null;
  note: string | null;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const oneLine = (s: unknown, max: number) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, max);

/** The validated flag, or the reason it is refused. */
export function parseFeedback(body: any): { ok: true; value: Feedback } | { ok: false; error: string } {
  if (!body || typeof body !== 'object') return { ok: false, error: 'body must be a JSON object' };
  const client = String(body.client || '');
  if (!(CLIENTS as readonly string[]).includes(client)) return { ok: false, error: `client must be one of ${CLIENTS.join(', ')}` };
  const answer_source = String(body.answer_source || 'olo');
  if (!(ANSWER_SOURCES as readonly string[]).includes(answer_source)) return { ok: false, error: `answer_source must be one of ${ANSWER_SOURCES.join(', ')}` };
  const claim = oneLine(body.claim, 600);
  if (claim.length < 3) return { ok: false, error: 'claim is required (3 to 600 characters)' };
  const verdict_given = String(body.verdict_given || '');
  if (!(GIVEN as readonly string[]).includes(verdict_given)) return { ok: false, error: `verdict_given must be one of ${GIVEN.join(', ')}` };
  const verdict_user = String(body.verdict_user || '');
  if (!(USER as readonly string[]).includes(verdict_user)) return { ok: false, error: `verdict_user must be one of ${USER.join(', ')}` };
  const passages = (Array.isArray(body.passages) ? body.passages : []).slice(0, 12).map((p: any) => {
    const out: { atom?: string; url?: string; quote?: string } = {};
    if (typeof p?.atom === 'string' && UUID.test(p.atom)) out.atom = p.atom.toLowerCase();
    if (typeof p?.url === 'string' && /^https?:\/\/\S+$/.test(p.url)) out.url = p.url.slice(0, 500);
    if (typeof p?.quote === 'string' && p.quote.trim()) out.quote = oneLine(p.quote, 600);
    return out;
  }).filter((p: any) => p.atom || p.url);
  const evidence_quote = oneLine(body.evidence_quote, 600) || null;
  const note = oneLine(body.note, 500) || null;
  return { ok: true, value: { client: client as Feedback['client'], answer_source: answer_source as Feedback['answer_source'], claim, verdict_given: verdict_given as Feedback['verdict_given'], verdict_user: verdict_user as Feedback['verdict_user'], passages, evidence_quote, note } };
}

/** A flag that agrees with the verdict and says nothing more teaches nothing; it is counted, not stored. */
export function isInformative(f: Feedback): boolean {
  return f.verdict_user !== f.verdict_given || !!f.note || !!f.evidence_quote;
}

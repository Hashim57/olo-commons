// deno test tests/   (olo-brain-ask: validation, scrubbing, hold rules, normalisation)
import { assert, assertEquals } from './_assert.ts';
import { bearer, isAbusive, isCrisis, judge, normalise, parseAsk, recentLimit, sameSecret, scrub } from '../functions/olo-brain-ask/brain.ts';

const ATOM = '78E2BE27-FED2-467A-BF47-DEBF10C93B49';

Deno.test('parseAsk accepts a well-formed ask and normalises atoms', () => {
  const r = parseAsk({ question: '  How   old is the\nuniverse? ', client: 'ios', atoms: [ATOM, ATOM.toLowerCase(), 'not-an-id', 42, '<script>'], answered: true });
  assert(r.ok);
  if (!r.ok) return;
  assertEquals(r.value.question, 'How old is the universe?');
  assertEquals(r.value.atoms, [ATOM.toLowerCase()]);
  assertEquals(r.value.answered, true);
  assertEquals(r.value.client, 'ios');
});

Deno.test('parseAsk refuses bad bodies, clients, lengths and types', () => {
  assertEquals(parseAsk(null).ok, false);
  assertEquals(parseAsk([]).ok, false);
  assertEquals(parseAsk({ client: 'web' }).ok, false);
  assertEquals(parseAsk({ question: '   ', client: 'web' }).ok, false);
  assertEquals(parseAsk({ question: 'x'.repeat(501), client: 'web' }).ok, false);
  assertEquals(parseAsk({ question: 'fine question', client: 'android' }).ok, false);
  assertEquals(parseAsk({ question: 'fine question', client: 'web', atoms: 'a' }).ok, false);
  assertEquals(parseAsk({ question: 'fine question', client: 'web', answered: 'yes' }).ok, false);
});

Deno.test('parseAsk keeps at most 12 distinct atoms and defaults answered to false', () => {
  const ids = Array.from({ length: 20 }, (_, i) => `00000000-0000-0000-0000-${String(i).padStart(12, '0')}`);
  const r = parseAsk({ question: 'what links these', client: 'macos', atoms: ids });
  assert(r.ok && r.value.atoms.length === 12 && r.value.answered === false);
});

Deno.test('scrub: email addresses', () => {
  const s = scrub('Can you email jane.doe+news@example.co.uk about rent?');
  assertEquals(s.text, 'Can you email [email] about rent?');
  assertEquals(s.scrubbed, ['email']);
});

Deno.test('scrub: UK mobile and landline numbers', () => {
  assertEquals(scrub('Is 07700 900123 a scam number?').text, 'Is [phone] a scam number?');
  assertEquals(scrub('Who owns (020) 7946 0958').text, 'Who owns [phone]');
  assertEquals(scrub('call 0161 496 0000 now').text, 'call [phone] now');
});

Deno.test('scrub: international numbers', () => {
  assertEquals(scrub('Is +44 7700 900123 real?').text, 'Is [phone] real?');
  assertEquals(scrub('ring +33 1 23 45 67 89 today').text, 'ring [phone] today');
  assertEquals(scrub('what about (415) 555-0132').text, 'what about [phone]');
});

Deno.test('scrub: URLs keep only the domain', () => {
  assertEquals(scrub('Is https://www.bbc.co.uk/news/uk-123?ref=abc&u=me reliable?').text, 'Is bbc.co.uk reliable?');
  assertEquals(scrub('what is on example.org/user/jane?id=9').text, 'what is on example.org');
  assertEquals(scrub('read http://arxiv.org/abs/2401.00001.').text, 'read arxiv.org.');
});

Deno.test('scrub: long digit runs, but not years or grouped figures', () => {
  assertEquals(scrub('my order 12345678 is late').text, 'my order [number] is late');
  assertEquals(scrub('card 4111 1111 1111 1111 declined').text, 'card [number] declined');
  assertEquals(scrub('What happened in 1066 and 1914?').text, 'What happened in 1066 and 1914?');
  assertEquals(scrub('Is 1,000,000 a million?').text, 'Is 1,000,000 a million?');
});

Deno.test('scrub: UK postcodes, but not road ordinals', () => {
  assertEquals(scrub('bin day for SW1A 1AA?').text, 'bin day for [postcode]?');
  assertEquals(scrub('schools near m1 1ae').text, 'schools near [postcode]');
  assertEquals(scrub('the A1 1st junction').text, 'the A1 1st junction');
});

Deno.test('scrub: @handles, without touching email', () => {
  assertEquals(scrub('who is @hashim_r on X?').text, 'who is [handle] on X?');
  assertEquals(scrub('meet @ 5pm').text, 'meet @ 5pm');
});

Deno.test('scrub: names after "my name is" and "I am"', () => {
  assertEquals(scrub('my name is jane smith and I need a visa').text, 'my name is [name] and I need a visa');
  assertEquals(scrub("Hi, I'm Hashim Ruan. What is RLS?").text, "Hi, I'm [name]. What is RLS?");
  assertEquals(scrub('I am British, do I need a visa for Spain?').text, 'I am British, do I need a visa for Spain?');
  assertEquals(scrub('What name is given to a baby swan?').text, 'What name is given to a baby swan?');
});

Deno.test('scrub: IBAN-like strings and national insurance numbers', () => {
  assertEquals(scrub('is GB82 WEST 1234 5698 7654 32 valid').text, 'is [account] valid');
  assertEquals(scrub('is QQ 12 34 56 C a real NI number').text, 'is [id] a real NI number');
});

Deno.test('scrub: invisible characters cannot split a pattern', () => {
  assertEquals(scrub('mail jane​@example.com').text, 'mail [email]');
  assertEquals(scrub('０７７００ 900123 is it spam').text, '[phone] is it spam');
});

Deno.test('judge publishes an ordinary question', () => {
  const v = judge('How does photosynthesis work?');
  assertEquals(v.status, 'published');
  assertEquals(v.reason, null);
});

Deno.test('judge holds personal details that survive scrubbing', () => {
  assertEquals(judge('my home address is the flat above the bakery').reason, 'personal');
  assertEquals(judge('my national insurance number is on my payslip, where?').reason, 'personal');
  assertEquals(judge('I live at 14 Elm Grove, is the area safe').reason, 'personal');
  assertEquals(judge('my son Oliver keeps failing maths').reason, 'personal');
  assertEquals(judge('I was born on the 3rd of May, which star sign').reason, 'personal');
});

Deno.test('judge publishes famous addresses and plain relatives', () => {
  assertEquals(judge('Who lives at 10 Downing Street?').status, 'published');
  assertEquals(judge('my son is learning fractions, how do I help').status, 'published');
});

Deno.test('judge holds when three different kinds of detail were removed', () => {
  const v = judge('jane@example.com 07700 900123 SW1A 1AA what now');
  assertEquals(v.status, 'held');
  assertEquals(v.reason, 'personal');
});

Deno.test('judge holds crisis text and keeps fair questions about the topic', () => {
  assertEquals(judge('I want to die, nothing helps').reason, 'crisis');
  assertEquals(judge('how to kill myself').reason, 'crisis');
  assertEquals(judge('best suicide methods').reason, 'crisis');
  assertEquals(judge('What are suicide rates in the UK?').status, 'published');
  assertEquals(judge('How do I kill a process on Linux?').status, 'published');
  assertEquals(judge("I'll die on this hill: tabs or spaces?").status, 'published');
});

Deno.test('judge holds slurs and threats, not ordinary words', () => {
  assert(isAbusive('you are a f@ggot'));
  assert(isAbusive('go kill yourself'));
  assert(isAbusive("I'll stab you"));
  assertEquals(judge('kys loser').reason, 'abuse');
  assert(!isAbusive('a chink in the armour'));
  assert(!isAbusive('is flame retardant safe'));
  assert(!isAbusive('Pakistan population'));
});

Deno.test('judge holds questions under 8 characters, placeholders not counted', () => {
  assertEquals(judge('why?').reason, 'too_short');
  assertEquals(judge('hi @someone').reason, 'too_short');
  assertEquals(judge('Why is the sky blue').status, 'published');
});

Deno.test('crisis detection matches the olo-web list on its own examples', () => {
  assert(isCrisis("I don't want to be here anymore"));
  assert(isCrisis('thinking about ending it all, I am tired'));
  assert(isCrisis('I keep cutting myself'));
  assert(!isCrisis('the film Suicide Squad'));
  assert(!isCrisis('end the process'));
});

Deno.test('normalise: case, punctuation and spacing do not make a new question', () => {
  assertEquals(normalise('How old is the Universe?'), normalise('  how OLD is the universe '));
  assertEquals(normalise("What’s [email]'s domain?"), "what's [email]'s domain");
  assert(normalise('How old is the universe') !== normalise('How old is the sun'));
});

Deno.test('recentLimit is bounded', () => {
  assertEquals(recentLimit(null), 200);
  assertEquals(recentLimit('abc'), 200);
  assertEquals(recentLimit('0'), 200);
  assertEquals(recentLimit('50'), 50);
  assertEquals(recentLimit('100000'), 500);
});

Deno.test('sameSecret and bearer', () => {
  assert(sameSecret('abc', 'abc'));
  assert(!sameSecret('abc', 'abd'));
  assert(!sameSecret('abc', 'abcd'));
  assert(!sameSecret('', ''));
  assertEquals(bearer('Bearer tok.en'), 'tok.en');
  assertEquals(bearer('Basic x'), '');
  assertEquals(bearer(null), '');
});

Deno.test('judge never returns more than 500 characters and the text it judged', () => {
  const v = judge('Why '.repeat(200));
  assert(v.text.length <= 500);
  const w = judge('Email me at a@b.co about the moon landing please');
  assertEquals(w.text, 'Email me at [email] about the moon landing please');
  assertEquals(w.status, 'published');
});

# Wiring helius-olo.io (olo-web) to Olo Commons and Zeus

`commons.ts` is a dependency-free module for the olo-web server. It asks the Commons for a checked answer and converts it into the newline-delimited JSON events the olo-web client already renders: `status`, `sources`, `delta`, `verification` (claims with `supported`, `contradicted`, `unsupported`, an `excerpt`, a `rationale` and `citedBy` source indexes), `notice`, `followups`. Those names and fields were read from the shipped client bundle, so no client change is needed for a first version.

## Server change (the `/api/chat/stream` handler)

1. Copy `commons.ts` next to the handler (it compiles as TypeScript or, with the types stripped, as plain JavaScript).
2. Before the model call, when `grounded` is true (or always, your call):

```ts
import { askCommons, commonsEvents, answerText } from './commons';

const a = await askCommons(content, { k: 8, signal: req.signal });
if (a && a.covered) {
  for (const ev of commonsEvents(a, { conversationId })) send(ev);   // send = write JSON + '\n'
  await saveAssistantMessage({ content: answerText(a), sources: toSources(a), verification: toVerification(a) });
  send({ type: 'answer_complete', conversationId, messageId });
  return;
}
// not covered, or the Commons is unreachable: carry on with the usual model answer,
// and if `a` exists, still send its `notice` so the user knows the Commons was asked.
```

3. Optional partner key: pass `apiKey` (an `olo_...` key from `olo_api_keys`) to lift the limit from 120 to 3,000 answers an hour per address. Keep it in a server environment variable, never in the client.

## What the user then sees

The Zeus panel that already exists in the client ("Zeus checking claims", verdict cards, "Source: wikipedia.org") fills from the `verification` event. The `status` event names which verifier ran: "Checked by Zeus against Olo Commons passages" once `OLO_ZEUS_URL` points at the served adapter, or the honest fallback line until then. The `confidence` field is left out on purpose: Zeus gives a verdict and a quote, not a probability, and the client hides the percentage when the field is absent.

## Running Zeus for real

The Commons function `olo-answer` verifies with Zeus when the Supabase secrets `OLO_ZEUS_URL` and `OLO_ZEUS_API_KEY` are set. `zeus/mac/install-serve.sh` sets up the Mac to serve the promoted version behind an authenticated gate and a tunnel, and sets those two secrets itself when the Supabase CLI is logged in. See `zeus/mac/README.md`.

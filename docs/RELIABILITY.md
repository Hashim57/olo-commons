# Reliability: how Olo, the Commons and Zeus stay up

The aim is that a question always gets the best answer the situation allows, and says which situation it was. Each layer has a fallback, and every fallback is labelled in the response so nothing pretends to be more than it is.

## The chain for one question

| Layer | First choice | If it fails | If that fails too |
|---|---|---|---|
| Passages | olo-query: meaning + keyword search in Supabase | keyword search through the public RPC | the copy of the Commons saved on the device (pages and apps), searched locally |
| Writing the answer | the main provider (`OLO_LLM_*`, Groq by default) | the Cloudflare Worker's `olo-draft` (Llama 3.3 70B on Workers AI) | an extractive answer: the passages' own sentences, quoted word for word, marked `mode: "extractive"` |
| Checking each sentence | Zeus on Cloudflare (`OLO_ZEUS_URL`) | the writer with the Zeus prompt (`verifier: "llm-fallback"`) | the sentence is marked not covered with the reason; never passed unchecked |

helius-olo.io follows the same idea: Anthropic first, then OpenAI if configured, then the Cloudflare `olo-draft`; if every model fails it answers from the Commons; offline it answers from the saved copy (with the on-device model when one is downloaded, or by quoting when not).

## Offline

`.github/workflows/snapshot.yml` builds `commons.json` every six hours (every atom's title, summary, link, origin and licence) and publishes it on the `snapshot` branch, served by jsDelivr with GitHub as the second source. The Olo page keeps it in the browser (IndexedDB), refreshes it when it is more than six hours old, and its service worker keeps the page itself, so heliusnetwork.app/olo opens and answers with no connection at all. helius-olo.io does the same in its offline mode. During a wide internet outage the saved copy is what answers; nothing is lost, and questions are checked again when the connection returns.

## Watching

`.github/workflows/uptime.yml` runs every 15 minutes: the Commons status call (and that the ingester ran in the last two hours), both functions' browser preflight, the two sites, and Zeus's public health. Once an hour it asks a real question. When something is down it opens one issue labelled `outage` (GitHub emails the owner), comments while it stays down and closes it when everything is back. Set the repository variable `ZEUS_HEALTH_URL` (Settings, Secrets and variables, Actions, Variables) to `https://zeus.<your-subdomain>.workers.dev/health` to include Zeus.

## What this cannot promise

Each provider has its own uptime (Supabase, Netlify, Cloudflare, Groq, Anthropic). The chain means one of them failing narrows the answer rather than breaking it, but a 99 percent figure is something the uptime log will show over time, not something to claim in advance. The log is the issue history.

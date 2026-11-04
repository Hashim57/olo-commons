# Zeus on Cloudflare Workers AI

Zeus runs on Cloudflare, not on the Mac: a fixed address that is always on, costs nothing while idle, and is paid per word checked (Workers AI gives 10,000 neurons a day free, then $0.011 per 1,000). The Mac still trains Zeus, hands-free; Cloudflare serves it.

## How it fits together

| Piece | Where | What it does |
|---|---|---|
| Base model | Cloudflare, `@cf/mistral/mistral-7b-instruct-v0.2-lora` | Mistral 7B Instruct v0.2 (Apache 2.0), the base Cloudflare runs uploaded LoRA adapters on |
| Zeus adapter | uploaded per version as the fine-tune `zeus-vN` | rank 8 on q_proj and v_proj, trained on the Mac by `zeus/train_mac.sh` (profile `cloudflare`, the default from v6) and converted by `zeus/export_peft.py` |
| The `zeus` Worker | `https://zeus.<your-subdomain>.workers.dev` | OpenAI-compatible API with a bearer key: model `default_model` is Zeus, model `olo-draft` is the fallback writer (Llama 3.3 70B) both sites use when their main provider is down |
| Callers | olo-answer (Commons), helius-olo.io | the same URL and key; the response says which verifier ran |

## Once

```
cd ~/olo-commons && git pull && bash zeus/cloudflare/setup.sh
```

A browser window opens for the Cloudflare sign-in (a free account works). The script deploys the Worker, stores the key, points the Commons at it when the Supabase CLI is logged in, and prints the exact values for Netlify.

## Every version after that

Nothing to do. When a training run finishes and `zeus/promote.py` records the best Cloudflare-servable version in `zeus/BEST.json` (field `cloudflare`), the Mac agent runs `publish.sh`: it uploads `zeus-vN`, redeploys the Worker pointing at it with that version's measured scores, scores the served model on the frozen eval split and commits `zeus/out/zeus-vN/eval-cloudflare.json`. A worse version is never promoted.

## Honest notes

The adapter is trained on a 4-bit copy of the base on the Mac (QLoRA) and served by Cloudflare on the full-precision base. That is the normal way QLoRA adapters are deployed, but the numbers can move a little, which is why the served model is scored separately and both numbers are kept.

The Worker can retry once when Zeus answers with something that is not a valid verdict (opt in: the Worker var `ZEUS_FORMAT_RETRY=1`, or `"format_retry": true` in a request; off by default). The retry sends the original messages, the bad answer and a short repair instruction at temperature 0, capped at 200 tokens and 15 seconds, and never repeats. The response says `"retried"` (with the first answer in `zeus_first_answer`) so `eval_endpoint.py --format-retry` keeps the first-attempt scores apart; when the retry fails too the Worker answers 502 `zeus_unparseable_answer`. Workers AI JSON mode (constrained decoding through `response_format`) is not used because the LoRA base model is not on Cloudflare's list of JSON mode models.

Until the first Mistral version is published, the Worker answers 503 for Zeus and every caller falls back (olo-answer to the hosted writer with the Zeus prompt, helius-olo.io to its Claude verifier), and says so.

## When answers say "checked by Zeus (backup verifier)"

That means helius-olo.io's key does not match the Worker's `ZEUS_TOKEN` secret, so every check is refused
with 401 and Claude stands in. On the Mac, from the repo clone:

    bash zeus/cloudflare/connect.sh

It sets one key on the Worker, checks the Worker accepts it with a real Zeus verification, sets
`ZEUS_VERIFIER_*` and the Cloudflare fallback writer (`OLO_FALLBACK_*`) on the helius-olo.io Netlify site,
and the matching Supabase secrets for Olo Commons when the Supabase CLI is signed in. It never prints the
key. Netlify applies the variables on the next deploy.

## Deploying a change to worker.js

The daily cloud training redeploys the Worker only when a new Zeus version beats the one serving. To ship a
code change before then:

    bash zeus/cloudflare/deploy_worker.sh

It keeps the serving version (from `zeus/BEST.json`) and every variable set in the dashboard, such as
`DRAFT_MODEL`. Never run a bare `wrangler deploy`: `wrangler.toml` leaves `ZEUS_LORA` blank on purpose,
and a bare deploy would stop Zeus serving its adapter.

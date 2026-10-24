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

The adapter is trained on a 4-bit copy of the base on the Mac (QLoRA) and served by Cloudflare on the full-precision base. That is the normal way QLoRA adapters are deployed, but the numbers can move a little, which is why the served model is scored separately and both numbers are kept. Until the first Mistral version is published, the Worker answers 503 for Zeus and every caller falls back (olo-answer to the hosted writer with the Zeus prompt, helius-olo.io to its Claude verifier), and says so.

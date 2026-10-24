# Retired: Zeus no longer runs on a Mac

Training moved to a cloud GPU (`zeus/cloud/`) and serving to Cloudflare (`zeus/cloudflare/`) because training on a laptop slowed it down. The files here are kept for reference; `zeus/cloud/README.md` says how to remove the agents from a Mac.

# Hands-free Zeus training on a Mac

The daily cloud run cannot type into a Terminal on the Mac, so training is
requested through the repository instead:

1. When a training run is due, the cloud run commits `zeus/TRAIN_REQUEST.json`
   (`{"version": "v3", "requested_at": "...", "reason": "..."}`) and pushes.
2. `zeus-agent.sh`, run by launchd every 30 minutes on the Mac, sees the
   request, runs `zeus/train_mac.sh v3` on the Mac GPU (the Mac is kept awake,
   the display may sleep), commits `zeus/out/zeus-v3/eval.json` and
   `train_summary.json` (or `FAILED.txt` with the log tail if it broke),
   removes the request and pushes.
3. The next cloud run reads the results and adds the measured row to
   `zeus/STATUS.md`, or records the failure and fixes the cause.

Install once, from the repo clone on the Mac: `bash zeus/mac/install.sh`.
Needs push access stored in the keychain (one `git push` from Terminal does it).
Logs: `~/zeus-agent.log` (agent) and `~/zeus-train-<version>.log` (training).
To train by hand without waiting, commit a request file yourself, or run
`bash zeus/train_mac.sh vN` as before.

## Serving Zeus to the cloud from the same Mac

`bash zeus/mac/install-serve.sh` installs a second launchd agent, `com.helius.zeus-serve`, that stays up while you are logged in and runs three parts: `mlx_lm.server` with the promoted adapter from `zeus/BEST.json` on 127.0.0.1:8008; `zeus_gate.py` on 127.0.0.1:8009, which forwards only `POST /v1/chat/completions` and `GET /v1/models`, requires `Authorization: Bearer <token>` (the token is made once into `~/.zeus-gate-token`, never committed), caps bodies and forces the model name so a caller can never make the server load another model; and a `cloudflared` quick tunnel in front of the gate. The public URL lands in `~/zeus-serve.url`.

If the Supabase CLI is logged in on the Mac, the agent sets the project secrets `OLO_ZEUS_URL` and `OLO_ZEUS_API_KEY` on every start, so `olo-answer` verifies with Zeus and says so (`verifier: "zeus:default_model"`). Otherwise set them by hand from `~/zeus-serve.url` and `~/.zeus-gate-token`. A quick tunnel gets a new URL each start; the agent handles that. When the Mac is off or asleep, `olo-answer` falls back to the hosted model with the Zeus prompt and labels it `llm-fallback`; nothing breaks.

When a new version is promoted (`zeus/BEST.json` changes on main and its weights are on this Mac), the training agent restarts the serving agent so the better model takes over within 30 minutes. Logs: `~/zeus-serve.log`, `~/zeus-model.log`, `~/zeus-gate.log`, `~/zeus-tunnel.log`. Check from anywhere: `curl -s -H "Authorization: Bearer $(cat ~/.zeus-gate-token)" "$(cat ~/zeus-serve.url)/models"`.

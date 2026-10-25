# Zeus trains in the cloud

Nothing of Zeus runs on anyone's computer. Training and measuring run on a GPU rented by the second from Modal (modal.com), started by GitHub Actions; serving runs on Cloudflare Workers AI (`zeus/cloudflare/`).

## Every day, by itself

The workflow runs at 03:23 UTC every day. It turns reviewed feedback flags into gold lines (docs/FEEDBACK.md), rebuilds the dataset, and trains a new version only when there is something new to learn from: new feedback, a tenth more data, or a week since the last version (`zeus/cloud/due.py`). Each trained version is measured on the frozen split, on held-out VitaminC dev and on a 600-item LLM-AggreFact sample, written to `docs/ZEUS_SCORECARD.md`, promoted only if not worse, and published to the Worker. Run it by hand from the Actions tab to train regardless.

One more optional secret makes the feedback export work: `SUPABASE_SERVICE_ROLE_KEY` (Supabase dashboard, Project Settings, API keys, service_role). Without it the daily run still trains on the rule-made data and the hand-written gold.

## How a version is made

1. A training request (`zeus/TRAIN_REQUEST.json`, written by the daily run) is pushed, or someone starts **Zeus training (cloud)** by hand in GitHub Actions with a version number.
2. The workflow builds the dataset from the Commons (keyless), adds the VitaminC pairs and checks the gold set, then sends them to an A100 on Modal.
3. On the GPU: Mistral 7B Instruct v0.2 at full precision, a rank-8 LoRA on q_proj and v_proj (exactly what Cloudflare serves), one pass over the data, then greedy decoding on the frozen eval split for the measured scores. About 40 minutes; about $1.50 of GPU time. Modal gives $30 of credit a month.
4. Back on GitHub: the STATUS row is written from the measured numbers, `promote.py` decides (never promoting a worse version), the adapter is kept as a workflow artifact for 90 days, and when it is the best Cloudflare-servable version it is uploaded to Cloudflare, the Worker switches to it, and the served model is scored too (`eval-cloudflare.json`).

## One-time setup (about 10 minutes)

1. Make a free account at modal.com, then Settings > API tokens > New token. Keep the two values.
2. In GitHub, olo-commons > Settings > Secrets and variables > Actions, add these repository secrets:

| Secret | Value |
|---|---|
| `MODAL_TOKEN_ID` | from step 1 |
| `MODAL_TOKEN_SECRET` | from step 1 |
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard > My Profile > API Tokens > Create Token > "Edit Cloudflare Workers" template, plus Account > Workers AI > Edit |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard, right-hand side of the Workers & Pages page |
| `ZEUS_KEY` | the Zeus Worker key (`cat ~/.zeus-cf-token` on the Mac) |
| `HF_TOKEN` | huggingface.co > Settings > Access Tokens (read). Needed for the LLM-AggreFact sample in the scorecard (a gated dataset: open huggingface.co/datasets/lytang/LLM-AggreFact once and accept its terms), and if Mistral is gated for you |

and this repository variable (Variables tab): `ZEUS_URL` = `https://zeus.<your-subdomain>.workers.dev/v1`.

With the GitHub CLI installed and logged in, the same from Terminal:

```
gh secret set MODAL_TOKEN_ID -R Hashim57/olo-commons
gh secret set MODAL_TOKEN_SECRET -R Hashim57/olo-commons
gh secret set CLOUDFLARE_API_TOKEN -R Hashim57/olo-commons
gh secret set CLOUDFLARE_ACCOUNT_ID -R Hashim57/olo-commons
gh secret set ZEUS_KEY -R Hashim57/olo-commons < ~/.zeus-cf-token
gh variable set ZEUS_URL -R Hashim57/olo-commons --body "$(cat ~/zeus-cf.url)"
```

3. Start the first run: GitHub > olo-commons > Actions > Zeus training (cloud) > Run workflow > version `v6`.

## The Mac agents are retired

`zeus/mac/` (the launchd training and serving agents) is kept for reference only. Remove them from a Mac with:

```
launchctl bootout gui/$(id -u)/com.helius.zeus-train 2>/dev/null; launchctl bootout gui/$(id -u)/com.helius.zeus-serve 2>/dev/null
rm -f ~/Library/LaunchAgents/com.helius.zeus-train.plist ~/Library/LaunchAgents/com.helius.zeus-serve.plist
```

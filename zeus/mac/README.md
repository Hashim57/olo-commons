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

#!/usr/bin/env python3
"""Ask the Mac agent to train the next Zeus version (see zeus/mac/README.md).

  python3 zeus/request_training.py --reason "412 train examples, no measured row near that size"
  python3 zeus/request_training.py --version v4 --reason "..."     # explicit version

Writes zeus/TRAIN_REQUEST.json with the next vN after the highest zeus-vN that
has results under zeus/out/ or a measured row in STATUS.md. Commit and push it;
the agent on the Mac does the rest. Refuses to overwrite a pending request.
"""
import argparse, json, os, re, sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))


def highest_version():
    vs = [0]
    out = os.path.join(HERE, "out")
    if os.path.isdir(out):
        for d in os.listdir(out):
            m = re.fullmatch(r"zeus-v(\d+)", d)
            if m and (os.path.exists(os.path.join(out, d, "eval.json")) or os.path.exists(os.path.join(out, d, "FAILED.txt"))):
                vs.append(int(m.group(1)))
    status = os.path.join(HERE, "STATUS.md")
    if os.path.exists(status):
        for line in open(status, encoding="utf-8"):
            m = re.match(r"\|\s*\d{4}-\d{2}-\d{2}\s*\|\s*v(\d+)\b", line)
            if m:
                vs.append(int(m.group(1)))
    return max(vs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version")
    ap.add_argument("--reason", required=True)
    args = ap.parse_args()
    path = os.path.join(HERE, "TRAIN_REQUEST.json")
    if os.path.exists(path):
        sys.exit(f"a request is already pending: {open(path).read().strip()}")
    v = args.version or f"v{highest_version() + 1}"
    if not re.fullmatch(r"v\d{1,3}", v):
        sys.exit(f"bad version {v!r}")
    req = {"version": v, "requested_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "reason": args.reason[:200]}
    with open(path, "w") as f:
        json.dump(req, f)
        f.write("\n")
    print(json.dumps(req))


if __name__ == "__main__":
    main()

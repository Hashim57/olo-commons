#!/usr/bin/env python3
"""After a cloud run: add the measured row to zeus/STATUS.md (after the last row of the table) and
run promote.py. Only measured numbers go in; nothing is estimated.

  python3 zeus/cloud/record.py v6
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ZEUS = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import recipe  # noqa: E402

ROW = re.compile(r"^\| \d{4}-\d{2}-\d{2} \| v\d+ \|")


def add_row(status_path, row, version):
    lines = open(status_path, encoding="utf-8").read().split("\n")
    if any(re.match(rf"^\| \d{{4}}-\d{{2}}-\d{{2}} \| {version} \|", l) for l in lines):
        return False  # already recorded
    last = max((i for i, l in enumerate(lines) if ROW.match(l)), default=None)
    if last is None:
        lines += ["", row]
    else:
        lines.insert(last + 1, row)
    open(status_path, "w", encoding="utf-8").write("\n".join(lines))
    return True


def note_generators(summary_path, summary, meta_path):
    """Copy the train generators of the build this version was trained on (meta.json, the same run) into
    train_summary.json, which is committed, so promote.py can put them in BEST.json and due.py can see when
    the recipe changes. Returns the list, or None when meta.json has none."""
    if summary.get("train_generators"):
        return summary["train_generators"]
    try:
        gens = json.load(open(meta_path, encoding="utf-8")).get("train_generators")
    except (OSError, ValueError, AttributeError):
        gens = None
    if gens:
        summary["train_generators"] = gens
        with open(summary_path, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2)
            f.write("\n")
    return gens


def main():
    v = sys.argv[1]
    out = os.path.join(ZEUS, "out", f"zeus-{v}")
    ev = json.load(open(os.path.join(out, "eval.json")))
    s = json.load(open(os.path.join(out, "train_summary.json")))
    note_generators(os.path.join(out, "train_summary.json"), s, os.path.join(ZEUS, "data", "meta.json"))
    row = recipe.status_row(datetime.now(timezone.utc).date().isoformat(), v, s.get("base") or ev.get("base"), f"{s.get('train_examples'):,}", ev, s.get("minutes"), s.get("gpu"))
    ext_path = os.path.join(out, "eval-external.json")
    if os.path.exists(ext_path):
        ext = json.load(open(ext_path))
        vit, agg, ev2, ev3 = ext.get("vitaminc_dev") or {}, ext.get("llm_aggrefact") or {}, ext.get("eval_v2") or {}, ext.get("eval_v3") or {}
        held = []
        if ev2.get("label_accuracy") is not None:
            held.append(f"Commons eval v2 (harder, n={ev2.get('n')}) accuracy {ev2.get('label_accuracy')}, evidence hit {ev2.get('evidence_hit')}")
        if ev3.get("label_accuracy") is not None:
            held.append(f"Commons eval v3 ({ev3.get('version')}, n={ev3.get('n')}) accuracy {ev3.get('label_accuracy')}, evidence hit {ev3.get('evidence_hit')}")
        if vit:
            held.append(f"VitaminC dev (held out, n={vit.get('n')}) accuracy {vit.get('label_accuracy')}, evidence hit {vit.get('evidence_hit')}, binary balanced accuracy {vit.get('binary_balanced_accuracy')}")
        if agg.get("balanced_accuracy") is not None:
            held.append(f"LLM-AggreFact sample (n={agg.get('n')}) balanced accuracy {agg['balanced_accuracy']} percent")
        if held:
            row = row.rstrip()[:-1].rstrip() + " Held out: " + "; ".join(held) + ". |"
    print("STATUS row added" if add_row(os.path.join(ZEUS, "STATUS.md"), row, v) else "STATUS row already there")
    subprocess.run([sys.executable, os.path.join(ZEUS, "promote.py")], check=True)
    subprocess.run([sys.executable, os.path.join(HERE, "scorecard.py")], check=False)


if __name__ == "__main__":
    main()

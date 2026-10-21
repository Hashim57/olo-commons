# Zeus status

| Date | Version | Base | Train examples | Label acc. | Evidence hit | Notes |
|---|---|---|---|---|---|---|
| 2026-10-21 | v0 (not trained yet) | Qwen/Qwen2.5-7B-Instruct | 0 | n/a | n/a | Scaffold: dataset builder, trainer, eval, serve. Commons has ~25 atoms; dataset builder needs a few hundred before a first training run is worth it. |

## Open decisions
- Base model: Qwen2.5-7B-Instruct chosen for licence, JSON reliability and the 1.5B sibling. Re-check monthly.
- Contradiction quality: rule-made for now; add hand-written gold set under `data/gold/`.

## Log (unmeasured runs; a row goes in the table only when something was trained and scored)
- 2026-10-21: build_dataset.py could not reach the Commons from the cloud sandbox (egress blocked for supabase.co and heliusnetwork.app), so no dataset counts this run. Fixed a real bug on the way: olo_export returns an object (`atoms`, `next_after`), not a list, so every build would have crashed on the first page. Added relation-flip contradictions (before/after, increased/decreased, is/is not) as a second kind of rule-made negative, gold example counting in meta.json (`gold`, `train_total`), and unit tests under `zeus/tests/`. No gold examples written: they must quote real atoms and none could be fetched. Training not due (no meta.json; the Commons had about 25 atoms at the last count). Base model check not due (Wednesday).

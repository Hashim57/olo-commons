# Zeus status

| Date | Version | Base | Train examples | Label acc. | Evidence hit | Notes |
|---|---|---|---|---|---|---|
| 2026-10-21 | v0 (not trained yet) | Qwen/Qwen2.5-7B-Instruct | 0 | n/a | n/a | Scaffold: dataset builder, trainer, eval, serve. Commons has ~25 atoms; dataset builder needs a few hundred before a first training run is worth it. |

## Open decisions
- Base model: Qwen2.5-7B-Instruct chosen for licence, JSON reliability and the 1.5B sibling. Re-check monthly.
- Contradiction quality: rule-made for now; add hand-written gold set under `data/gold/`.

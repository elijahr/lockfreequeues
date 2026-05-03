# Followup work prompts

Each file is a self-contained kickoff prompt for a fresh `/develop` session, derived from `~/lockfreequeues-bench-comparison-followups.md` after Item 3 (issue #15 / Mupmuc livelock + protocol fix) shipped in v4.0.0.

## Files

| # | File | Tier | Depends on |
|---|---|---|---|
| 01 | [bench-polish.md](01-bench-polish.md) | SIMPLE | — (5b defers until 03 lands) |
| 02 | [latency-bench.md](02-latency-bench.md) | STANDARD | — (parallel to 03) |
| 03 | [comparison-libs-bench.md](03-comparison-libs-bench.md) | LARGE / COMPLEX | — |
| 04 | [interactive-graphs.md](04-interactive-graphs.md) | MEDIUM | 03 (and resolves 03's two-pipeline pre-work) |

## Recommended order

1. **01a (5c CHANGELOG cleanup)** — quick win, ~30min, no design doc.
2. **02 (latency bench)** — independent of 03, skeleton already exists.
3. **03 (comparison libs)** — multi-PR sequence, design doc gates everything else.
4. **04 (interactive graphs)** — needs 03's pipeline-decision design doc.
5. **01b/c** — fold in alongside the above where natural.

## Not committed (radar items, no prompt files)

From Item 6 of the followups doc:
- Stress tests in CI (nightly cron)
- Smarter variant exploration for the rejected item 3b path
- CodSpeed integration (revisit if non-simulation mode matures)
- Multi-arch CI matrix (ARM, high-core)

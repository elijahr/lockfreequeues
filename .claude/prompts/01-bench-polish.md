# Item 5 — Bench shape polish

**Tier:** SIMPLE (no design doc required). Can be split across multiple small PRs or bundled into one.

**Source:** `~/lockfreequeues-bench-comparison-followups.md` Item 5 (lines 444-468).

## Three sub-items

### 5a. UnboundedMupsic 1P/1C noise

CI numbers show `unbounded_mupsic/1p1c` with stddev ~19% of mean while 2p1c and 4p1c have <1%. Likely cause: first run includes DEBRA epoch initialization / first-segment allocation cost that amortizes across the message count.

**Fix options (pick one):**
- Bump `WarmupRuns` from 2 → 3 specifically for `unbounded_mupsic`
- Report first-run separately as a "cold start" measure

Files to investigate: `benchmarks/nim/bench_throughput.nim`, the warmup logic.

### 5b. Per-step CI timeout-minutes

`Run bench_throughput` already has `timeout-minutes: 20`. Consider per-variant time budgeting: kill a single variant if it exceeds its expected wall-clock; continue to the next. **Defer until Item 1 (comparison libs) lands** — variant count is what makes this worthwhile.

### 5c. CHANGELOG / docs

- Add CHANGELOG entry for cloud bench harness (PR #14 squash-merge `d4c1388`).
- Add CHANGELOG entry noting item 3b was evaluated and rejected with bench evidence; link the closed PR #16 and the Bencher reports.
- `benchmarks/README.md` is up to date as of PR #14 — update again when Item 1 lands.

## Kickoff prompt

```
/develop

Polish the bench harness per ~/lockfreequeues-bench-comparison-followups.md
Item 5. See .claude/prompts/01-bench-polish.md for breakdown.

Suggested order: 5c (CHANGELOG cleanup, ~30min) first as standalone PR.
Then 5a (UnboundedMupsic warmup) as a separate small PR. Defer 5b until
Item 1 lands.

SIMPLE tier; no design doc needed.
```

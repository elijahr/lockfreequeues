# Bench Rollup - Chunk 6/7: PR 6 (optional) — Latency thresholds in Bencher gating + p999_ns/max_ns measures

## Working Directory

**Path:** ~/Development/worktrees/bench-rollup-pr6/lockfreequeues
**Branch:** feat/bench-rollup-pr6-latency-thresholds
**Base:** devel (PR 5's branch must be merged before this chunk starts; if PR 5 is still in review, rebase on PR 5's branch instead.)

BEFORE ANY WORK:
1. `cd ~/Development/worktrees/bench-rollup-pr6/lockfreequeues && pwd && git branch --show-current`
2. Verify output shows `feat/bench-rollup-pr6-latency-thresholds`
3. ALL file paths must be absolute, rooted at `~/Development/worktrees/bench-rollup-pr6/lockfreequeues`
4. Do NOT create new branches or switch branches
5. ALL git commands must run from `~/Development/worktrees/bench-rollup-pr6/lockfreequeues`

If the worktree does NOT yet exist, dispatch a subagent that invokes the `using-git-worktrees` skill via the Skill tool to create it, branched from origin/devel (with PR 5 already merged AND ≥ 10 stable runs accumulated).

## Context

This optional final chunk activates Bencher regression gating for tail-latency measures. Two new measures (`latency_p999_ns` and `latency_max_ns`) are emitted by `bench_latency.nim` via the existing `BMFEmitter`. The histogram top-K capacity is raised to 5000 (or alternatively documented as reservoir-derived) to ensure p999 accuracy at production sample sizes (3.3M samples per slug at default 33 runs × 100,000 messages). A mandatory manual stability soak across ≥ 10 runs verifies p99 coefficient of variation < 5% on the Bencher dashboard BEFORE threshold args are added — otherwise the first regression alert is a false positive on uncalibrated noise. After the soak passes, `bench.yml` adds `--threshold-measure latency_p99_ns --threshold-test t_test --threshold-max-sample-size 64 --threshold-upper-boundary 0.99` (and a parallel block for throughput with `--threshold-lower-boundary 0.99`), terminated by `--thresholds-reset`. The CHANGELOG documents the new measures and the gating activation.

Previous chunks completed: Chunk 0 (Track 0), Chunk 1 (Track 1), Chunk 2 (Track 2), Chunk 3 (Track 3 — Comparison MVP + padding audit), Chunk 4 (Track 4 — Comparison expansion to 7 libraries), Chunk 5 (Track 5 — Interactive uPlot charts + mkdocs deploy from devel).

This chunk implements Track 6 from the implementation plan: tasks 6.1-6.5.

## Execution

**MANDATORY: You MUST invoke the `develop` skill using the Skill tool before doing ANY work.**

```
Skill tool call:
  skill: "develop"
  args: "Escape hatch: impl plan at /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md, treat as ready. Track 6 tasks only. Fully autonomous mode. Worktree per parallel track (already created or to be created at ~/Development/worktrees/bench-rollup-pr6/lockfreequeues). Parallelization maximize. Post-impl: create PR against devel."
```

**Key documents:**
- Implementation plan: `/Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md`
- Design document: `/Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-design.md`
- Understanding doc: `/Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/understanding/understanding-bench-rollup-2026-05-01.md`

## Subagent Dispatch Discipline

<CRITICAL>
The develop skill orchestrates via subagents. Every subagent that does
substantive work MUST invoke the appropriate skill using the Skill tool.

"Do TDD" is NOT the same as "invoke the test-driven-development skill."
"Review the code" is NOT the same as "invoke the requesting-code-review skill."
Doing the work without invoking the skill is a workflow violation.

Every subagent prompt MUST begin with:
  "First, invoke the [skill-name] skill using the Skill tool.
   Then follow its complete workflow."

After each subagent returns, verify its output contains
"Launching skill: [name]". If not found, REJECT the result and re-dispatch.
</CRITICAL>

### Per-Task Gate Sequence (mandatory, sequential, not batched)

After EACH task, run these gates in order:

1. **TDD** (4.3): Dispatch subagent → must invoke `test-driven-development` skill using the Skill tool
2. **Completion verification** (4.4): Dispatch subagent with inline audit prompt
3. **Code review** (4.5): Dispatch subagent → must invoke `requesting-code-review` skill using the Skill tool
4. **Fact-checking** (4.5.1): Dispatch subagent → must invoke `fact-checking` skill using the Skill tool

Do NOT batch gates across tasks.

### Post-All-Tasks Gates (mandatory)

1. Comprehensive implementation audit (4.6.1)
2. Full test suite (4.6.2)
3. Green mirage audit (4.6.3) → must invoke `audit-green-mirage` skill using the Skill tool
4. Comprehensive fact-checking (4.6.4) → must invoke `fact-checking` skill using the Skill tool
5. Finishing (4.7) → must invoke `finishing-a-development-branch` skill using the Skill tool

## Pre-conditions

- Devel branch is at or past the merged state of PR 5 (verify: `git log origin/devel --oneline -- docs/benchmarks.md` shows the chart wiring commit; `docs/assets/bench-charts.js` exists on devel).
- ≥ 10 prior CI runs of `bench.yml` on devel have accumulated since PR 5 merged, providing the noise-floor data needed for the stability soak in task 6.4. If fewer than 10 runs are available, this chunk MUST wait — activating thresholds prematurely produces false-positive alerts.
- The Bencher dashboard is reachable to inspect p99 coefficient of variation across the recent runs.
- `BMFEmitter`, `LatencyMetrics`, and the Histogram top-K + reservoir machinery from Track 0 are in place and unmodified by intervening tracks.
- Bumping `LatencyHistogramTopK` from 1000 to 5000 (Option A in task 6.2) does not break any existing test; Option B (documenting reservoir-derived p999) is acceptable if Option A produces a regression.
- Task ordering: 6.4 (manual stability soak) MUST complete with passing evidence before 6.3 (threshold args activation) merges. 6.1 and 6.2 may land first to enable the soak.

## Exit Criteria

- All Track 6 tasks (6.1-6.5) implemented and committed
- All per-task gates passed for every task
- All post-all-tasks gates passed
- Branch pushed to origin
- PR opened against devel via `creating-issues-and-pull-requests` skill
- PR description follows repo template (no "Test plan" section, no AI attribution, no GitHub issue numbers)

## Next

When PR 6 is merged, the bench-rollup feature is complete. Run:
1. Full test suite to confirm devel is green
2. Verify all 7 PRs are merged via `gh pr list --state merged --search "bench-rollup"`
3. Invoke `finishing-a-development-branch` skill to handle any remaining cleanup

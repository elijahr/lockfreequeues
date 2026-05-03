# Bench Rollup - Chunk 1/7: PR 1 — bench_latency wired to BMF (smoke shape)

## Working Directory

**Path:** ~/Development/worktrees/bench-rollup-pr1/lockfreequeues
**Branch:** feat/bench-rollup-pr1-latency-mvp
**Base:** devel (PR 0's branch must be merged before this chunk starts; if PR 0 is still in review, rebase on PR 0's branch instead.)

BEFORE ANY WORK:
1. `cd ~/Development/worktrees/bench-rollup-pr1/lockfreequeues && pwd && git branch --show-current`
2. Verify output shows `feat/bench-rollup-pr1-latency-mvp`
3. ALL file paths must be absolute, rooted at `~/Development/worktrees/bench-rollup-pr1/lockfreequeues`
4. Do NOT create new branches or switch branches
5. ALL git commands must run from `~/Development/worktrees/bench-rollup-pr1/lockfreequeues`

If the worktree does NOT yet exist, dispatch a subagent that invokes the `using-git-worktrees` skill via the Skill tool to create it, branched from origin/devel (with PR 0 already merged).

## Context

This chunk proves the multi-measure-per-slug pipeline end-to-end by rewiring `bench_latency.nim` onto the `runLatencyHarness` from `bench_common`, emitting BMF natively for the 4 lockfreequeues bounded variants at the 1p1c smoke shape (latency_p50_ns, latency_p95_ns, latency_p99_ns; p999/max deferred to PR 6). A new `bench-latency` CI job is added as a sibling to `bench-throughput`, the merge step is parameterized to ingest N BMF inputs (downloading both `bench-throughput-bmf` and `bench-latency-bmf` artifacts), and a smoke test asserts that a single slug carries both throughput and latency measures after `merge_bmf.py`. Manual verification on the Bencher dashboard confirms multi-measure rendering before merge.

Previous chunks completed: Chunk 0 (Track 0 — bench_common scaffolding + native BMF emission + adapter rename).

This chunk implements Track 1 from the implementation plan: tasks 1.1-1.7.

## Execution

**MANDATORY: You MUST invoke the `develop` skill using the Skill tool before doing ANY work.**

```
Skill tool call:
  skill: "develop"
  args: "Escape hatch: impl plan at /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md, treat as ready. Track 1 tasks only. Fully autonomous mode. Worktree per parallel track (already created or to be created at ~/Development/worktrees/bench-rollup-pr1/lockfreequeues). Parallelization maximize. Post-impl: create PR against devel."
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

- Devel branch is at or past the merged state of PR 0 (verify: `git log origin/devel --oneline -- benchmarks/nim/bench_common.nim | head -1` shows commits).
- `bench_common.nim` exposes `runLatencyHarness`, `BMFEmitter`, `LatencyMetrics`, and the histogram helpers from Track 0.
- `bmf_adapter.py` is removed from devel; `merge_bmf.py` and its tests exist on devel.
- `bench_throughput.nim` still emits BMF natively on devel (PR 2 will delete it; this chunk does not touch it).
- The 4 lockfreequeues bounded variants (sipsic, mupmuc, sipmuc, mupsic) have working adapter modules at `benchmarks/nim/adapters/*_adapter.nim`.
- The Bencher dashboard project is reachable for the manual multi-measure verification step.

## Exit Criteria

- All Track 1 tasks (1.1-1.7) implemented and committed
- All per-task gates passed for every task
- All post-all-tasks gates passed
- Branch pushed to origin
- PR opened against devel via `creating-issues-and-pull-requests` skill
- PR description follows repo template (no "Test plan" section, no AI attribution, no GitHub issue numbers)

## Next

When PR 1 is merged into devel, run the next chunk:
```
Follow the prompt in /Users/eek/Development/lockfreequeues/.claude/prompts/bench-rollup-chunk-2.md
```

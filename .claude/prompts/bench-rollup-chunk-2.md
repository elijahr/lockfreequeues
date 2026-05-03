# Bench Rollup - Chunk 2/7: PR 2 — Topology split (5 binaries) + per-step CI timeouts

## Working Directory

**Path:** ~/Development/worktrees/bench-rollup-pr2/lockfreequeues
**Branch:** feat/bench-rollup-pr2-topology-split
**Base:** devel (PR 1's branch must be merged before this chunk starts; if PR 1 is still in review, rebase on PR 1's branch instead.)

BEFORE ANY WORK:
1. `cd ~/Development/worktrees/bench-rollup-pr2/lockfreequeues && pwd && git branch --show-current`
2. Verify output shows `feat/bench-rollup-pr2-topology-split`
3. ALL file paths must be absolute, rooted at `~/Development/worktrees/bench-rollup-pr2/lockfreequeues`
4. Do NOT create new branches or switch branches
5. ALL git commands must run from `~/Development/worktrees/bench-rollup-pr2/lockfreequeues`

If the worktree does NOT yet exist, dispatch a subagent that invokes the `using-git-worktrees` skill via the Skill tool to create it, branched from origin/devel (with PR 1 already merged).

## Context

This chunk replaces the monolithic `bench_throughput.nim` with four topology-specific binaries (`bench_spsc`, `bench_mpsc`, `bench_mpmc`, `bench_unbounded`) plus the existing `bench_latency`, each with its own per-binary intdefines for runs and message counts. A pre-split slug-set fixture is captured first, then a Python `superset_check.py` script enforces deletion-safety (post-split slugs must be a strict superset of pre-split). `bench.yml` is restructured into a 5-way matrix job with explicit `timeout-minutes: 12` per binary, all artifacts are merged into one BMF, and `bench_throughput.nim` is deleted. `merge_bmf.py` is extended for 5-input union testing. Total CI wall time stays under 15 minutes through parallel matrix execution.

Previous chunks completed: Chunk 0 (Track 0 — bench_common scaffolding), Chunk 1 (Track 1 — bench_latency BMF wiring).

This chunk implements Track 2 from the implementation plan: tasks 2.1-2.11.

## Execution

**MANDATORY: You MUST invoke the `develop` skill using the Skill tool before doing ANY work.**

```
Skill tool call:
  skill: "develop"
  args: "Escape hatch: impl plan at /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md, treat as ready. Track 2 tasks only. Fully autonomous mode. Worktree per parallel track (already created or to be created at ~/Development/worktrees/bench-rollup-pr2/lockfreequeues). Parallelization maximize. Post-impl: create PR against devel."
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

- Devel branch is at or past the merged state of PR 1 (verify: `git log origin/devel --oneline -- benchmarks/nim/bench_latency.nim` shows the BMF emission commits from PR 1; `bench-latency` job exists in `bench.yml`).
- `bench_throughput.nim` still exists on devel and is operational; this chunk captures its current slug set BEFORE deletion.
- `bench_common.nim` from Track 0 exposes `runThroughputHarness` plus the topology-related types used by the new binaries.
- `merge_bmf.py` accepts variable-length input lists (parameterization landed in Track 1).
- The Bencher dashboard reflects PR 1's multi-measure smoke shape; this chunk expands shape coverage and must not regress it.
- `actionlint` is available locally for `bench.yml` matrix changes.

## Exit Criteria

- All Track 2 tasks (2.1-2.11) implemented and committed
- All per-task gates passed for every task
- All post-all-tasks gates passed
- Branch pushed to origin
- PR opened against devel via `creating-issues-and-pull-requests` skill
- PR description follows repo template (no "Test plan" section, no AI attribution, no GitHub issue numbers)

## Next

When PR 2 is merged into devel, run the next chunk:
```
Follow the prompt in /Users/eek/Development/lockfreequeues/.claude/prompts/bench-rollup-chunk-3.md
```

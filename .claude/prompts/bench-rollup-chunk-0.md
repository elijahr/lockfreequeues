# Bench Rollup - Chunk 0/7: PR 0 — bench_common scaffolding + native BMF emission + adapter rename

## Working Directory

**Path:** ~/Development/worktrees/bench-rollup-pr0/lockfreequeues
**Branch:** feat/bench-rollup-pr0-bench-common
**Base:** devel (this is the first chunk; base directly on origin/devel.)

BEFORE ANY WORK:
1. `cd ~/Development/worktrees/bench-rollup-pr0/lockfreequeues && pwd && git branch --show-current`
2. Verify output shows `feat/bench-rollup-pr0-bench-common`
3. ALL file paths must be absolute, rooted at `~/Development/worktrees/bench-rollup-pr0/lockfreequeues`
4. Do NOT create new branches or switch branches
5. ALL git commands must run from `~/Development/worktrees/bench-rollup-pr0/lockfreequeues`

If the worktree does NOT yet exist, dispatch a subagent that invokes the `using-git-worktrees` skill via the Skill tool to create it, branched from origin/devel.

## Context

This chunk lays the foundation for the entire bench-rollup feature. It introduces a single shared `bench_common.nim` module that centralizes BMF (Bencher Metric Format) emission, throughput/latency harness logic, histogram (top-K + reservoir) and stats helpers, and adapter conventions. The existing throughput binary is rewired to emit BMF natively (replacing the Python `bmf_adapter.py`), the legacy adapter files are renamed to a uniform `_adapter.nim` suffix, the 5 missing lockfreequeues bounded/unbounded variants get adapters, a `merge_bmf.py` CLI plus tests are added, and `bench.yml` is updated to merge native BMF inputs before invoking Bencher. PR 0 keeps `bench_throughput.nim` operational (PR 2 deletes it) and intentionally leaves latency wiring for PR 1.

Previous chunks completed: none (this is the first chunk).

This chunk implements Track 0 from the implementation plan: tasks 0.1-0.14.

## Execution

**MANDATORY: You MUST invoke the `develop` skill using the Skill tool before doing ANY work.**

```
Skill tool call:
  skill: "develop"
  args: "Escape hatch: impl plan at /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md, treat as ready. Track 0 tasks only. Fully autonomous mode. Worktree per parallel track (already created or to be created at ~/Development/worktrees/bench-rollup-pr0/lockfreequeues). Parallelization maximize. Post-impl: create PR against devel."
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

- Local clone of `lockfreequeues` is up to date with `origin/devel`.
- The worktree at `~/Development/worktrees/bench-rollup-pr0/lockfreequeues` either already exists on branch `feat/bench-rollup-pr0-bench-common` based on `origin/devel`, or will be created via the `using-git-worktrees` skill before any task work begins.
- `nim`, `nimble`, and `python3` are installed and on PATH (verified by attempting `nim --version` / `python3 --version` from within the worktree).
- `actionlint` is available locally for `.github/workflows/bench.yml` validation; if not, install it as part of the self-unblocking budget.
- No release tag has been created on `devel` since the last merge (Track 0 modifies `render_readme.nim`'s consumer path).

## Exit Criteria

- All Track 0 tasks (0.1-0.14) implemented and committed
- All per-task gates passed for every task
- All post-all-tasks gates passed
- Branch pushed to origin
- PR opened against devel via `creating-issues-and-pull-requests` skill
- PR description follows repo template (no "Test plan" section, no AI attribution, no GitHub issue numbers)

## Next

When PR 0 is merged into devel, run the next chunk:
```
Follow the prompt in /Users/eek/Development/lockfreequeues/.claude/prompts/bench-rollup-chunk-1.md
```

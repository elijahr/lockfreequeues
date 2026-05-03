# Bench Rollup - Chunk 3/7: PR 3 — Comparison MVP (Loony + Boost + Crossbeam) + cache-line padding audit

## Working Directory

**Path:** ~/Development/worktrees/bench-rollup-pr3/lockfreequeues
**Branch:** feat/bench-rollup-pr3-comparison-mvp
**Base:** devel (PR 2's branch must be merged before this chunk starts; if PR 2 is still in review, rebase on PR 2's branch instead.)

BEFORE ANY WORK:
1. `cd ~/Development/worktrees/bench-rollup-pr3/lockfreequeues && pwd && git branch --show-current`
2. Verify output shows `feat/bench-rollup-pr3-comparison-mvp`
3. ALL file paths must be absolute, rooted at `~/Development/worktrees/bench-rollup-pr3/lockfreequeues`
4. Do NOT create new branches or switch branches
5. ALL git commands must run from `~/Development/worktrees/bench-rollup-pr3/lockfreequeues`

If the worktree does NOT yet exist, dispatch a subagent that invokes the `using-git-worktrees` skill via the Skill tool to create it, branched from origin/devel (with PR 2 already merged).

## Context

This is the most critical PR of the rollup. It opens with a mandatory cache-line padding audit (tasks 3.1-3.4) that MUST land as the first three commits before any external library work: a RED test asserts 64-byte alignment for unbounded queue Segments, an `allocAlignedSegment` allocator is implemented via `posix_memalign`, the four unbounded variants' `c_calloc` call sites are swapped over, segment Atomic fields receive `{.align: CacheLineBytes.}` pragmas, and a smoke-bench parity check confirms throughput delta within ±5%. After the padding audit goes green, five MVP comparison adapters land: Loony (unbounded MPMC via nimble), Boost lockfree::queue (MPMC bounded via apt + `nim cpp`), Boost lockfree::spsc_queue (SPSC bounded), Crossbeam ArrayQueue (bounded MPMC via Rust cdylib FFI), and Crossbeam SegQueue (unbounded MPMC). Each adapter is gated by `-d:adapter_<name>_available` with a `when declared(...)` wiring pattern and soft-skip CI flow. A new `bench-comparison.yml` workflow runs the Crossbeam path nightly + on dispatch + on relevant path changes. Acceptance: ≥ 3 libraries × ≥ 3 shapes each in merged BMF.

Previous chunks completed: Chunk 0 (Track 0 — bench_common), Chunk 1 (Track 1 — latency BMF), Chunk 2 (Track 2 — topology split).

This chunk implements Track 3 from the implementation plan: tasks 3.1-3.18.

## Execution

**MANDATORY: You MUST invoke the `develop` skill using the Skill tool before doing ANY work.**

```
Skill tool call:
  skill: "develop"
  args: "Escape hatch: impl plan at /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md, treat as ready. Track 3 tasks only. Fully autonomous mode. Worktree per parallel track (already created or to be created at ~/Development/worktrees/bench-rollup-pr3/lockfreequeues). Parallelization maximize. Post-impl: create PR against devel."
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

- Devel branch is at or past the merged state of PR 2 (verify: `git ls-tree -r origin/devel --name-only | grep -q '^benchmarks/nim/bench_throughput\.nim$'` returns NO match — `bench_throughput.nim` was deleted by PR 2; the four topology binaries `bench_spsc/mpsc/mpmc/unbounded` exist on devel).
- The padding audit ordering constraint: tasks 3.1, 3.2, 3.3 MUST be the first three commits on the branch BEFORE any external adapter work begins. The RED test (3.1) must fail on initial run and reach GREEN only after 3.3 wires the aligned allocator.
- Rust toolchain (`cargo`, `rustc`) is available for the Crossbeam FFI crate; `cargo --version` succeeds.
- Local toolchain has `nim cpp` working for the Boost adapter path; on Ubuntu CI the `libboost-dev` apt package is installable; on macOS the dev box has Boost via Homebrew or skips locally.
- `posix_memalign` import path verified per task 3.2's compile probe sub-step before writing the allocator.
- No release tag has been created on `devel` since PR 2 merged (the padding fix changes runtime behavior of unbounded queues).

## Exit Criteria

- All Track 3 tasks (3.1-3.18) implemented and committed
- All per-task gates passed for every task
- All post-all-tasks gates passed
- Branch pushed to origin
- PR opened against devel via `creating-issues-and-pull-requests` skill
- PR description follows repo template (no "Test plan" section, no AI attribution, no GitHub issue numbers)

## Next

When PR 3 is merged into devel, run the next chunk:
```
Follow the prompt in /Users/eek/Development/lockfreequeues/.claude/prompts/bench-rollup-chunk-4.md
```

# Bench Rollup - Chunk 4/7: PR 4 — Comparison expansion (Threading.Channels + Nim Channel + MoodyCamel + Boost SPSC)

## Working Directory

**Path:** ~/Development/worktrees/bench-rollup-pr4/lockfreequeues
**Branch:** feat/bench-rollup-pr4-comparison-expansion
**Base:** devel (PR 3's branch must be merged before this chunk starts; if PR 3 is still in review, rebase on PR 3's branch instead.)

BEFORE ANY WORK:
1. `cd ~/Development/worktrees/bench-rollup-pr4/lockfreequeues && pwd && git branch --show-current`
2. Verify output shows `feat/bench-rollup-pr4-comparison-expansion`
3. ALL file paths must be absolute, rooted at `~/Development/worktrees/bench-rollup-pr4/lockfreequeues`
4. Do NOT create new branches or switch branches
5. ALL git commands must run from `~/Development/worktrees/bench-rollup-pr4/lockfreequeues`

If the worktree does NOT yet exist, dispatch a subagent that invokes the `using-git-worktrees` skill via the Skill tool to create it, branched from origin/devel (with PR 3 already merged).

## Context

This chunk grows comparison coverage from 3 libraries (PR 3 MVP) to 7 libraries × ≥ 3 shapes by adding four more adapters: MoodyCamel ConcurrentQueue (vendored at a pinned upstream SHA under `benchmarks/vendor/concurrentqueue/` with a `moodycamel_wrapper.cpp` exposing `extern "C"` `mc_init/push/pop/destroy` for `uint64_t`), Threading.Channels (nimble `threading` package's `Chan[T]`, bounded MPMC), Nim built-in `system/Channel` (MPSC bounded blocking — documented with an asterisk legend marker because of blocking-on-full semantics), and Boost lockfree::spsc piggybacked on the existing `FORCE_SKIP_BOOST` flag. New `FORCE_SKIP_*` workflow flags are added per library, `THIRD_PARTY_LICENSES.md` gets its first concrete vendor entry (MoodyCamel), `.gitattributes` marks vendored paths as `linguist-vendored=true linguist-generated=true`, and `benchmarks/README.md` is updated to document the full 7-library comparison table. A manual `workflow_dispatch` run with `force_skip_moodycamel=true` verifies the soft-skip annotation and BMF omission.

Previous chunks completed: Chunk 0 (Track 0), Chunk 1 (Track 1), Chunk 2 (Track 2), Chunk 3 (Track 3 — Comparison MVP + cache-line padding audit).

This chunk implements Track 4 from the implementation plan: tasks 4.1-4.11.

## Execution

**MANDATORY: You MUST invoke the `develop` skill using the Skill tool before doing ANY work.**

```
Skill tool call:
  skill: "develop"
  args: "Escape hatch: impl plan at /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md, treat as ready. Track 4 tasks only. Fully autonomous mode. Worktree per parallel track (already created or to be created at ~/Development/worktrees/bench-rollup-pr4/lockfreequeues). Parallelization maximize. Post-impl: create PR against devel."
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

- Devel branch is at or past the merged state of PR 3 (verify: `git log origin/devel --oneline -- benchmarks/nim/adapters/loony_adapter.nim | head -1` shows the loony adapter commit; the Crossbeam Rust crate exists at `benchmarks/rust/bench-ffi-crossbeam/`; `tests/t_unbounded_padding.nim` exists and passes).
- `THIRD_PARTY_LICENSES.md` placeholder from PR 3 exists at the repo root.
- The `FORCE_SKIP_BOOST` and `FORCE_SKIP_LOONY` flags from PR 3 already work in `bench.yml`; this chunk extends the same template to four new flags.
- `nim cpp` toolchain is functional locally (proven by PR 3's Boost MPMC path).
- The nimble `threading` package is installable; pin will land in `nimble.lock`.
- Network access to `github.com/cameron314/concurrentqueue` for vendoring is available, OR an alternate fetch path (curl tarball, gh release download) is exercised within the self-unblocking budget if the primary `git clone` fails.

## Exit Criteria

- All Track 4 tasks (4.1-4.11) implemented and committed
- All per-task gates passed for every task
- All post-all-tasks gates passed
- Branch pushed to origin
- PR opened against devel via `creating-issues-and-pull-requests` skill
- PR description follows repo template (no "Test plan" section, no AI attribution, no GitHub issue numbers)

## Next

When PR 4 is merged into devel, run the next chunk:
```
Follow the prompt in /Users/eek/Development/lockfreequeues/.claude/prompts/bench-rollup-chunk-5.md
```

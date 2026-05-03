# Bench Rollup - Chunk 5/7: PR 5 — Interactive uPlot charts + mkdocs deploy from devel

## Working Directory

**Path:** ~/Development/worktrees/bench-rollup-pr5/lockfreequeues
**Branch:** feat/bench-rollup-pr5-interactive-charts
**Base:** devel (PR 4's branch must be merged before this chunk starts; if PR 4 is still in review, rebase on PR 4's branch instead.)

BEFORE ANY WORK:
1. `cd ~/Development/worktrees/bench-rollup-pr5/lockfreequeues && pwd && git branch --show-current`
2. Verify output shows `feat/bench-rollup-pr5-interactive-charts`
3. ALL file paths must be absolute, rooted at `~/Development/worktrees/bench-rollup-pr5/lockfreequeues`
4. Do NOT create new branches or switch branches
5. ALL git commands must run from `~/Development/worktrees/bench-rollup-pr5/lockfreequeues`

If the worktree does NOT yet exist, dispatch a subagent that invokes the `using-git-worktrees` skill via the Skill tool to create it, branched from origin/devel (with PR 4 already merged).

## Context

This chunk replaces the static auto-rendered README throughput table with an interactive uPlot chart hosted on the mkdocs site (mike-versioned). uPlot 1.6.27 IIFE bundle is vendored at `docs/assets/uplot-1.6.27.iife.min.js` (SHA verified against upstream); a vanilla-JS module `docs/assets/bench-charts.js` fetches the latest BMF snapshot, groups slugs by library, renders log-scale Y-axis series with library-toggle legend and stddev tooltips. `docs/benchmarks.md` gets the chart container, script tags, and a verbatim fairness footer. `docs.yml` extends triggers + deploy condition to include `devel` (publishing to the `dev` mike alias). `bench.yml` gains a snapshot-push step that copies `merged.json` into `docs/assets/bench-results/<sha>.json` + `latest.json` and commits back to devel — guarded by THREE layers against self-retrigger loops (`[skip ci]` in commit message, `paths-ignore` extension, and `actor != github-actions[bot]` job-level guard, with the paths-ignore + actor-guard landing as a SEPARATE earlier commit verified by a no-op edit). A post-deploy `curl` smoke check verifies the asset URL returns HTTP 200 with valid JSON. `THIRD_PARTY_LICENSES.md` and `.gitattributes` get uPlot entries. `benchmarks/render_readme.nim` is deleted; the README BENCHMARKS markers receive a hand-curated 4-row summary plus a link to the live chart.

Previous chunks completed: Chunk 0 (Track 0), Chunk 1 (Track 1), Chunk 2 (Track 2), Chunk 3 (Track 3 — Comparison MVP + padding audit), Chunk 4 (Track 4 — Comparison expansion to 7 libraries).

This chunk implements Track 5 from the implementation plan: tasks 5.1-5.9.

## Execution

**MANDATORY: You MUST invoke the `develop` skill using the Skill tool before doing ANY work.**

```
Skill tool call:
  skill: "develop"
  args: "Escape hatch: impl plan at /Users/eek/.local/spellbook/docs/Users-eek-Development-lockfreequeues/plans/2026-05-01-bench-rollup-impl.md, treat as ready. Track 5 tasks only. Fully autonomous mode. Worktree per parallel track (already created or to be created at ~/Development/worktrees/bench-rollup-pr5/lockfreequeues). Parallelization maximize. Post-impl: create PR against devel."
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

- Devel branch is at or past the merged state of PR 4 (verify: `git log origin/devel --oneline -- benchmarks/nim/adapters/moodycamel_adapter.nim | head -1` shows the moodycamel adapter commit; `THIRD_PARTY_LICENSES.md` lists `concurrentqueue`).
- `mkdocs` + `mike` toolchain is installable locally (used by `mkdocs serve` for visual verification of the chart in 5.2/5.3).
- `docs.yml` exists on devel (PR 5 modifies it; it is not created here).
- `bench.yml` from PR 4 already produces a `merged.json` artifact at the standard location (5.5 reads it).
- The deploy target `https://elijahr.github.io/lockfreequeues/dev/benchmarks/` is reachable for the post-deploy curl verification (task 5.6) and the manual chart performance check (task 5.9).
- Loop-prevention guards land in 5.5.a as a SEPARATE commit verified before 5.5.b adds the snapshot-push step. Verification requires a no-op edit to `docs/assets/bench-results/.gitkeep` on a feature branch and confirmation that the bench job is skipped in the Actions UI.
- Before deleting `benchmarks/render_readme.nim` (task 5.8), verify no release tag was created on devel between PR 0's merge and now: `git tag --contains HEAD --sort=-version:refname | head -5`. If a tag exists in that range, backfill the README BENCHMARKS markers manually before deletion.

## Exit Criteria

- All Track 5 tasks (5.1-5.9) implemented and committed
- All per-task gates passed for every task
- All post-all-tasks gates passed
- Branch pushed to origin
- PR opened against devel via `creating-issues-and-pull-requests` skill
- PR description follows repo template (no "Test plan" section, no AI attribution, no GitHub issue numbers)

## Next

When PR 5 is merged into devel, run the next chunk:
```
Follow the prompt in /Users/eek/Development/lockfreequeues/.claude/prompts/bench-rollup-chunk-6.md
```

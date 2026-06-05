# lockfreequeues — agent notes

Operational notes for AI agents working in this repo. Build/test commands and
architecture live in the source itself; this file captures gotchas that are
not obvious from reading the code.

## Known issue: TSAN test-runner appears to hang after build succeeds

When invoking the TSAN-instrumented MM-MATRIX leg, e.g.

```
nim c --cc:clang --mm:atomicArc \
      --passC:"-fsanitize=thread" --passL:"-fsanitize=thread" \
      --threads:on -r -f tests/test.nim
```

the **build succeeds quickly** (the `Hint: ... [SuccessX]` line is emitted and
`.tmp/test` is produced), but the `-r`-driven exec phase frequently appears to
hang — the parent `nim` process sits in `S` (sleep, 0% CPU) for many minutes
without producing test output, then never finishes. This has been observed
repeatedly across sessions.

The hang is in the *runner*, not the test logic. The compiled binary itself
runs to completion (211 OK) in well under a second when invoked directly.

### Detection signal

You are in this state when:

- `Hint: ... .tmp/test [SuccessX]` has appeared in the output.
- `Hint: ... .tmp/test [Exec]` has *not* appeared (or appeared but no test
  output follows for >60 seconds).
- `ps -p <pid> -o stat,%cpu` shows the nim process is in `S` (sleep) at 0% CPU.
- `.tmp/test` exists with a recent mtime.

### Short-circuit

Treat the build as successful, kill the nim runner, and execute the binary
directly:

```
kill <nim-pid>
.tmp/test
```

Verify a clean `[Summary] 211 tests run (...): 211 OK, 0 FAILED, 0 SKIPPED`
line appears. That output is the same data the `-r` runner would have produced
if it had not hung.

This same pattern (`build then exec the artifact directly`) also works for the
focused TSAN×100 loop the v4.3 mitigation briefs prescribe — build once with
`-r` (or omit `-r`, equivalent), then loop the produced `.tmp/<test>` binary
in a shell `for` / `while` loop instead of re-running `nim c -r` per iteration.

### Why this matters operationally

Briefs that say "run the TSAN MM-MATRIX leg, expect 211 OK" can stall an
agent for 5+ minutes per attempt if the agent waits for `nim c -r` to return.
Detecting the hang early and pivoting to direct binary invocation keeps the
mitigation/verification loop tight without losing TSAN coverage — the binary
*is* TSAN-instrumented; only the runner driver is misbehaving.

## Defense placement follows commit placement

When a typestate verb's correctness depends on snapshotted state, the
defense against TOCTOU drift between snapshot and commit goes
**immediately before the irreversible commit**, not at the snapshot site
and not after the commit. The commit is the moment the snapshot's
staleness becomes load-bearing. Defending earlier wastes work on
snapshots that were never used; defending after is too late — the commit
has already been observed by other actors and cannot be unwound.

The two unbounded TOCTOU fixes in v4.3 illustrate this with mirrored
physical placement. In SPMC pop (`bb50bc9`), the irreversible commit is
the facade's CAS that advances `headSegment` past `oldSeg` (multi-
consumer coordination requires the CAS to live outside the verb to keep
the verb pipeline single-CAS-free). The defense — re-acquire-load
`consumerHead` and abort if items remain unclaimed — lives at the
facade, immediately before that CAS, in `unbounded_spmc.nim`'s
`USPMCPopReady` arm. In SPSC/MPSC pop (`7296240`), the irreversible
commit is the plain `headSegment.store` inside `advanceSegment`
(single-consumer; no coordination required, so the commit stays
verb-internal). The defense — F1' — re-loads `seg.tail` between
`next.load(moAcquire)` and the `headSegment.store`, and aborts the
advance if `freshTail > head`. Same principle, different physical
placement; both defenses sit at their respective commit points, not
before, not after.

For any future typestate work where commit-point defense is needed, the
heuristic is: locate the irreversible state transition (whether it is a
CAS, a plain release-store, or a multi-step facade-coordinated advance),
then place the defense immediately before that transition. If you can
not articulate where the commit lives — in the verb, in the facade, in
a coordinated CAS — you do not yet understand the topology well enough
to add a defense; the placement question will surface bugs before the
defense is needed. Note that this means the defense can widen the
verb's return contract (e.g., F1' makes `Ready` either "advance
happened" or "retry on same segment"); when that happens, callers need
a disambiguator (e.g., facade comparing `headSegment` before and after
`advanceSegment`). Document the widened contract at the call site so it
does not decay (see `unbounded_spsc.nim` and `unbounded_mpsc.nim`
comparison-site comments per `12eb259`).

## Typestate state-name U-prefix rule

State names in the eight `typestates/unbounded_*_{push,pop}.nim` files
use a `U`-prefix to avoid registry collisions with the bounded-graph
names, with one exception: SPSC PUSH (`unbounded_spsc_push.nim`) leaves
its states UN-prefixed because the SPSC push state graph has no bounded
counterpart to collide with. SPSC POP and the other six files are
U-prefixed. The rule is per state-graph, not per concurrency variant —
see commit body of `3d96020` for the migration-time discovery.

## Repository hygiene

These rules govern what may and may not enter source-controlled
files — code comments, docstrings, prose docs, and commit messages.

### No ephemeral process artifacts in tracked files

The following classes of content MUST NOT appear in tracked files
(source, docs, examples, tests, workflows):

- **Phase / Track / Bundle / Step markers.** Implementation-timeline
  identifiers like "Phase 3.3", "Track E", "Bundle F", "Step 3.3.9-D",
  "3.3.11-B", or any equivalent ad-hoc plan coordinate. These live in
  external plan documents and git history, not in shipped code.
- **Reviewer-feedback references.** Per-cycle flag identifiers
  (M-codes, F-codes, R-codes, "Gemini cycle N", "Momus r3 LOWs",
  "pepper flag-N", "lychee MED-N", "smart-ctor F-N", "BENCH-LOW-N",
  "CB-NNN", "arc-orc-NNN", "cascade-NNN"). The fix lives in the diff;
  the flag identifier dies with the review.
- **Temporary-state statements.** "Until X lands", "Once Y ships",
  "When Z completes", "(planned C1)". If a workaround is in place,
  describe the workaround in present tense without naming the future
  event that retires it. If the workaround DOES need retiring, file
  an issue or a TODO with no ephemeral coordinate.
- **Postmortem narration in code.** Reasoning about why an earlier
  attempt failed ("Wall 1 fix", "Wall 2 fix", "Wall 3 acceptance",
  "originally we tried X but it broke Y") belongs in the commit
  message or CHANGELOG, never in a checked-in comment.
- **AI attribution.** No `Co-Authored-By` trailers, no "Generated
  with Claude" footers, no bot signatures in commits, PR titles, PR
  descriptions, issue bodies, or comments.
- **GitHub issue numbers in commit messages, PR titles, or PR
  descriptions.** GitHub auto-links `#N` and notifies subscribers;
  reserve issue references for explicit human-curated cross-links.

### What comments are FOR

Source comments and docstrings exist to explain code that is not
obvious from the code itself. Acceptable categories:

- FFI / ABI contracts (NIL sentinels, alignment requirements,
  memory-ownership protocols across language boundaries).
- Memory ordering / atomicity rationale (which load is acquire,
  which store is release, what synchronizes-with what).
- Algorithmic invariants the type system cannot express (Vyukov
  sequence-counter discipline, committed-flag publication, EBR
  epoch advancement rules).
- Footgun callouts at sites that LOOK safe but are not (use-after-
  destroy, ARC + `ref T` slot copy hazards).
- Non-obvious workarounds with the constraint that produces them
  ("must run before X because Y", stated in present tense without
  reference to when X will go away).

Comments that restate the code are noise. `# increment counter`
above `counter += 1` adds nothing; delete it.

### Ephemeral docs do not get checked in

Implementation-phase audit trails — bench-delta postmortems, cascade
inventories, cross-doc re-gate reports, design rework deltas — do
not enter the tracked tree. The release-branch worktree is the right
home for them during development; the merge commit is where they
are dropped, not promoted to `docs/`.

The release-time documentation surface is:

- `README.md` — entry point.
- `docs/` (the mkdocs site, navigation defined in `mkdocs.yml`).
- `CHANGELOG.md` — versioned history.
- `AGENTS.md` — agent-facing operational notes (this file).
- `THIRD_PARTY_LICENSES.md`.

If a doc isn't reachable from one of those, it shouldn't be tracked.

## Reviewer config

### PR Review Bot

- Bot username: `gemini-code-assist`
- Re-review comment: `/gemini review`
- Auto-reviews on PR creation: no — manual `/gemini review` comment required every cycle (including the first)
- Parallel bot: `axiomantic-momus` (fires automatically via
  `.github/workflows/momus.yml`)
- Gating priority: gemini gates the PR; momus is informational unless
  gemini is unavailable (per memory
  `feedback_momus_dance_after_iteration`).

## Phase B: strict-LCRQ migration on MPMC (v5.0.0)

Starting in v5.0.0, the unbounded `Queue[T, ccMulti, ccMulti, ...]` uses
strict-LCRQ cells via debra DWCAS. This narrows `T` to `supportsCopyMem(T)`
AND `sizeof(T) <= 8`. For wider T, use `BQueue[T]` (bounded MPMC, Vyukov
per-slot seq), which preserves general T support including move-only types.

The migration was atomic across commits T0..T9 on
`feat/v5.0.0-strict-lcrq`. The T3..T7 range
(`77c7f20c..51f10b63`) contains partial-migration `STRICT-LCRQ-PARTIAL`
sentinels in source — use `git bisect skip` for SHAs in that range.
The green-gate commits are T8 (`33b8d49f`) and T9 (`cd8b27a1`); the
`STRICT-LCRQ-PARTIAL` marker count is 0 at and after T9.
CHANGELOG.md v5.0.0 has the full migration notes (BREAKING /
Added / Removed / Fixed / Dependencies / Bisect-notes) under the
"Phase B: strict-LCRQ migration on unbounded MPMC" subsection.

Cycle-4 (post-T16) gemini fixes landed two correctness changes worth
knowing when touching MPMC pop:
- **CR-1**: `waitForPublish` is bounded by `MaxWaitForPublishSpins =
  1024`, with escalation to `tryCloseOnEmpty` on budget exhaustion
  (defends LCRQ §4 progress against stalled producers).
- **CR-2**: the §5.3 CLOSED-detection branch falls through to the §5.2
  slow-path inline-skip rather than short-circuiting to eager
  retirement. Invariant change: `prevConsumerIdx` advances on **both**
  successful claims AND skipped-closed cells (previously claim-count-only).

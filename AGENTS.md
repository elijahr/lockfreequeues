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
facade, immediately before that CAS, in `unbounded_sipmuc.nim`'s
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

## v5.0.0 updates

Delta notes for v5.0.0-impl (`feat/v5.0.0-impl`). Historical content
above is preserved verbatim from `v4.2.0-bench-tightening`; this section
captures the deltas an agent landing on this branch needs to know.

- **TSAN hang mitigation — still applies.** The hang is a Nim runner +
  thread-sanitizer interaction, not queue-family-specific. Unified
  `Queue[…]` type does not change the symptom or the short-circuit
  (build then exec `.tmp/<test>` directly). Use as-is.
- **Defense placement SHAs `bb50bc9` + `7296240` are NOT reachable from
  v5.0.0-impl tip (`9cde893`).** Both commits live on the v4.3-task-14
  orphan branch and were not merged forward. The *principle* and the
  SPMC vs SPSC/MPSC mirrored-placement example remain authoritative as
  historical reference; if you need to inspect the original diffs,
  fetch them from the orphan branch. Future commit-point defense work
  in v5.0.0 should still follow the heuristic (locate the irreversible
  transition, place defense immediately before).
- **U-prefix typestate rule — fully operative.** `USPSCPop*`,
  `USPMCPop*`, `UMPMCPop*`, etc. state types persist in
  `src/lockfreequeues/typestates/unbounded_*.nim`. Phase 1's unified
  `Queue[…]` generic did not consolidate these away. SPSC PUSH remains
  the single un-prefixed exception per the historical rule. Pending
  Phase 3 Track E may revisit, but as of `9cde893` the rule is in
  effect and must be honored when adding new unbounded state graphs.
- **Source provenance.** This AGENTS.md was propagated from
  `v4.2.0-bench-tightening` (113-line source) during v5.0.0 Phase 4.7
  PR-prep. The v5.0.0-wave worktree previously had no AGENTS.md.

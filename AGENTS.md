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

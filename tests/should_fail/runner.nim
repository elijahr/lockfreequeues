## Driver for lockfreequeues' compile-fail test suite.
##
## Each entry asserts (a) the expected exit status from `nim c` (zero
## for positive cases, non-zero for negative cases) and (b) that the
## compiler's combined stdout+stderr contains a pinned error-message
## substring specific to the failure mode under test.
##
## Pinning the substring (rather than just the exit status) guards
## against silent regressions where the compile-fail still happens but
## the underlying check has rotted — e.g., a future overload-set change
## that drops the γ bounded-asymmetry guard, or a Strategy/cardinality
## phantom-param tightening that silently widens lookup.
##
## Ported from nim-debra 0.8.0's `tests/should_fail/runner.nim`
## (Phase 3.2.b.6) with a project-specific case table covering the
## 5 conditions enumerated in Doc C §6.3:
##   1. Consumer ST=stManual vs Queue ST=stEager (Strategy phantom).
##   2. ccCons=ccSingle queue rejects ccMulti DebraManager/handle.
##   3. ccCons=ccMulti  queue rejects ccSingle DebraManager.
##   4. (γ) bounded-asymmetry: retireOnCAS on Queue[..., rkNone, ...].
##   5. (γ) bounded-asymmetry: retireOnPublish on
##      Queue[..., ccCons=ccMulti, rkEbr, ...].
##
## Step 3.3.8 of Phase 3.3 lockfreequeues v5.0.0.

import std/[osproc, strformat, strutils]

type
  ExpectedOutcome = enum
    eoCompiles # `nim c` must exit 0; no substring needed.
    eoCompileFails # `nim c` must exit non-zero; substring must appear.

  Case = object
    name: string
    file: string
    outcome: ExpectedOutcome
    substring: string

const cases = @[
  Case(
    name: "t_queue_cardinality_mismatch §6.3 (1) — Consumer ST=stManual vs Queue ST=stEager",
    file: "tests/should_fail/strategy_st_mismatch.nim",
    outcome: eoCompileFails,
    substring: "stManual",
  ),
  Case(
    name: "t_queue_cardinality_mismatch §6.3 (2) — ccCons=ccSingle queue rejects ccMulti handle",
    file: "tests/should_fail/cc_consumer_single_rejects_multi.nim",
    outcome: eoCompileFails,
    substring: "newUnboundedMupsicQueue",
  ),
  Case(
    name: "t_queue_cardinality_mismatch §6.3 (3) — ccCons=ccMulti queue rejects ccSingle manager",
    file: "tests/should_fail/cc_consumer_multi_rejects_single.nim",
    outcome: eoCompileFails,
    substring: "newUnboundedMupmucQueue",
  ),
  Case(
    name: "t_queue_bounded_no_retire §6.3 (4) — retireOnCAS on Queue[..., rkNone, ...] (γ guard)",
    file: "tests/should_fail/bounded_no_retire_on_cas.nim",
    outcome: eoCompileFails,
    substring: "retireOnCAS",
  ),
  Case(
    name: "t_queue_bounded_no_retire §6.3 (5) — retireOnPublish on Queue[..., ccCons=ccMulti, rkEbr, ...] (γ guard)",
    file: "tests/should_fail/bounded_no_retire_on_publish_mc.nim",
    outcome: eoCompileFails,
    substring: "retireOnPublish",
  ),
  # 3.3.11-B Bundle J + M8 (family-level coverage of Bundle E
  # `{.error.}` cardinality gates). One case per BQueue/Queue * push/pop
  # family, exercising the cardinality `{.error.}` overload through the
  # family-named thin-wrappers (`newMupsicQueue`, `newSipmucQueue`,
  # `newMupmucQueue`, `newUnboundedSipmucQueue`). Family-level rather
  # than per-individual-wrapper per the M8 light-touch policy.
  Case(
    name: "t_bqueue_cardinality §6.3 (6) — direct push on ccProd=ccMulti BQueue is forbidden",
    file: "tests/should_fail/bqueue_multi_producer_direct_push.nim",
    outcome: eoCompileFails,
    substring: "multi-producer BQueue",
  ),
  Case(
    name: "t_bqueue_cardinality §6.3 (7) — direct pop on ccCons=ccMulti BQueue is forbidden",
    file: "tests/should_fail/bqueue_multi_consumer_direct_pop.nim",
    outcome: eoCompileFails,
    substring: "multi-consumer BQueue",
  ),
  Case(
    name: "t_queue_cardinality §6.3 (8) — direct pop on ccCons=ccMulti Queue is forbidden",
    file: "tests/should_fail/queue_multi_consumer_direct_pop.nim",
    outcome: eoCompileFails,
    substring: "multi-consumer Queue",
  ),
  Case(
    name: "t_bqueue_cardinality §6.3 (9) — direct batch push on ccProd=ccMulti BQueue is forbidden",
    file: "tests/should_fail/bqueue_multi_producer_batch_push.nim",
    outcome: eoCompileFails,
    substring: "batch push on a multi-producer BQueue",
  ),
]

proc runCase(c: Case): bool =
  let cmd =
    &"nim c --threads:on --hints:off --warnings:off --path:src --compileOnly {c.file}"
  let (output, exitCode) = execCmdEx(cmd)
  case c.outcome
  of eoCompiles:
    if exitCode != 0:
      echo &"[FAIL] {c.name}: expected exit 0, got {exitCode}"
      echo output
      return false
    echo &"[PASS] {c.name}"
    return true
  of eoCompileFails:
    if exitCode == 0:
      echo &"[FAIL] {c.name}: expected non-zero exit, got 0 (unexpected success)"
      echo output
      return false
    if not output.contains(c.substring):
      echo &"[FAIL] {c.name}: substring not found"
      echo &"       expected substring: {c.substring}"
      echo "       actual output:"
      echo output
      return false
    echo &"[PASS] {c.name} (exit {exitCode}, substring matched)"
    return true

proc main() =
  var failed = 0
  for c in cases:
    if not runCase(c):
      inc failed
  if failed > 0:
    echo &"\n{failed} compile-fail case(s) failed."
    quit(1)
  echo &"\nAll {cases.len} compile-fail cases passed."

main()

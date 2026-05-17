## Smoke tests for the v5.0.0 unified Queue generic's TYPE SHELL.
##
## A2 ships the 10-param generic type declaration plus the 9 Doc C
## §3.0.2.4 param-coherence guards lifted into a sibling template
## (`assertQueueParams`) invoked via the `validateQueueParams` proc.
## No method bodies yet — those live in Track B (rkNone) and Track E
## (rkEbr).
##
## The rkEbr-branch field declarations are mode-(a) stubs: the queue's
## RK=rkEbr fields are wrapped in `when false:` so the type instantiates
## without requiring nim-debra 0.8.0 types (DebraManager, ThreadHandle,
## Segment, CacheLineBytes). Manager E rewrites those field decls with
## real debra types when guava's nim-debra worktree linkage lands.
##
## What IS exercised here:
##   - All 9 static:assert param-coherence guards from Doc C §3.0.2.4
##     are PRESENT and ACTIVE; positive smoke instantiations confirm
##     they pass for valid shapes via `validateQueueParams`.
##   - The 10-param signature compiles with Doc C §3.0.1's exact param
##     order: T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads.
##   - Negative-control `compiles()` checks confirm each guard FIRES
##     for the corresponding invalid instantiation (the
##     `validateQueueParams` invocation fails to compile when an
##     assert is violated).
##
## What is NOT exercised here:
##   - push / pop / retireOnCAS / retireOnPublish: Tracks B and E.
##   - rkEbr-branch field offsets / =destroy hooks: Manager E.
##   - The full `nim check` expected-fail shell harness: Task A4.
##
## Impl plan: Track A, Task A2. Doc C §3.0.1, §3.0.2.4, §5.

import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

suite "Queue type shell — positive instantiations (rkNone)":

  test "bounded mupsic-equivalent shape compiles and validates":
    var q: Queue[int, ccMulti, ccSingle, stEager, rkNone, 16, 4, 0, 0, 0]
    discard addr q
    validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkNone,
                              16, 4, 0, 0, 0])

  test "bounded sipmuc-equivalent shape compiles and validates":
    var q: Queue[int, ccSingle, ccMulti, stEager, rkNone, 16, 0, 4, 0, 0]
    discard addr q
    validateQueueParams(Queue[int, ccSingle, ccMulti, stEager, rkNone,
                              16, 0, 4, 0, 0])

  test "bounded mupmuc-equivalent shape compiles and validates":
    var q: Queue[int, ccMulti, ccMulti, stEager, rkNone, 16, 4, 4, 0, 0]
    discard addr q
    validateQueueParams(Queue[int, ccMulti, ccMulti, stEager, rkNone,
                              16, 4, 4, 0, 0])

  test "bounded sipsic-equivalent shape compiles and validates":
    var q: Queue[int, ccSingle, ccSingle, stEager, rkNone, 16, 0, 0, 0, 0]
    discard addr q
    validateQueueParams(Queue[int, ccSingle, ccSingle, stEager, rkNone,
                              16, 0, 0, 0, 0])

suite "Queue type shell — positive instantiations (rkEbr, mode-(a) stubs)":

  test "unbounded mupsic-equivalent shape compiles and validates":
    var q: Queue[int, ccMulti, ccSingle, stEager, rkEbr, 0, 0, 0, 16, 4]
    discard addr q
    validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkEbr,
                              0, 0, 0, 16, 4])

  test "unbounded sipmuc-equivalent shape compiles and validates":
    var q: Queue[int, ccSingle, ccMulti, stEager, rkEbr, 0, 0, 0, 16, 4]
    discard addr q
    validateQueueParams(Queue[int, ccSingle, ccMulti, stEager, rkEbr,
                              0, 0, 0, 16, 4])

  test "unbounded mupmuc-equivalent shape compiles and validates":
    var q: Queue[int, ccMulti, ccMulti, stEager, rkEbr, 0, 0, 0, 16, 4]
    discard addr q
    validateQueueParams(Queue[int, ccMulti, ccMulti, stEager, rkEbr,
                              0, 0, 0, 16, 4])

suite "Queue type shell — positive controls confirm valid shapes compile":
  ## These compiles() checks are positive controls paired with the
  ## negative controls in the next suite. Each pair differs in EXACTLY
  ## one parameter (the property the guard targets).

  test "rkNone valid shape passes validateQueueParams via compiles()":
    check compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkNone,
                                16, 4, 0, 0, 0]))

  test "rkEbr valid shape passes validateQueueParams via compiles()":
    check compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkEbr,
                                0, 0, 0, 16, 4]))

suite "Queue type shell — 9 static:assert guards (negative controls)":
  ## Each `not compiles(...)` here is paired with a positive control in
  ## the preceding suite that differs only in the parameter the guard
  ## targets. This is the Doc C §3.0.2.4 reachability check at the
  ## smoke-test level (Task A4 adds a full nim-check shell harness).

  test "rkNone requires N > 0 (catches N=0)":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkNone,
                                0, 4, 0, 0, 0]))

  test "rkNone must have S = 0 (catches S != 0)":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkNone,
                                16, 4, 0, 8, 0]))

  test "rkNone must have MaxThreads = 0 (catches MT != 0)":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkNone,
                                16, 4, 0, 0, 4]))

  test "rkNone + ccProd=ccMulti requires P > 0":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkNone,
                                16, 0, 0, 0, 0]))

  test "rkNone + ccProd=ccSingle must have P == 0":
    check not compiles(
      validateQueueParams(Queue[int, ccSingle, ccSingle, stEager, rkNone,
                                16, 4, 0, 0, 0]))

  test "rkNone + ccCons=ccMulti requires C > 0":
    check not compiles(
      validateQueueParams(Queue[int, ccSingle, ccMulti, stEager, rkNone,
                                16, 0, 0, 0, 0]))

  test "rkNone + ccCons=ccSingle must have C == 0":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkNone,
                                16, 4, 4, 0, 0]))

  test "rkEbr requires S > 0":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkEbr,
                                0, 0, 0, 0, 4]))

  test "rkEbr requires MaxThreads > 0":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkEbr,
                                0, 0, 0, 16, 0]))

  test "rkEbr must have N == 0, P == 0, C == 0 (catches N != 0)":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, rkEbr,
                                8, 0, 0, 16, 4]))

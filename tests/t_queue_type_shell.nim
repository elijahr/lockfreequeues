## Smoke tests for the v5.0.0 type shell — BQueue + Queue.
##
## reshaped the legacy 10-param
## unified `Queue[T, ccProd, ccCons, ST, RK, N, P, C, S, MaxThreads]`
## into two narrower types:
##
##   - `BQueue[T, ccProd, ccCons, N, P, C]` — bounded, no debra.
##   - `Queue[T, ccProd, ccCons, ST, S, MaxThreads]` — unbounded,
##     with the `(ccSingle, ccSingle)` branch absorbing the standalone
##     `UnboundedSpsc[S, T]` (debra-free).
##
## What IS exercised here:
##   - All 4 cardinality combos instantiate under both BQueue and Queue.
##   - `validateBQueueParams` + `validateQueueParams` succeed on valid
##     shapes and FAIL via `not compiles(...)` on invalid shapes.
##   - 6 BQueue-side guards (N>0, P>0/=0 by cardinality, C>0/=0 by
##     cardinality) and 2 Queue-side guards (S>0, MaxThreads>0).

import unittest2

import lockfreequeues/bqueue
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "BQueue type shell — positive instantiations":

  test "bounded mpsc-equivalent shape compiles and validates":
    var q: BQueue[int, ccMulti, ccSingle, 16, 4, 0]
    discard addr q
    validateBQueueParams(BQueue[int, ccMulti, ccSingle, 16, 4, 0])

  test "bounded spmc-equivalent shape compiles and validates":
    var q: BQueue[int, ccSingle, ccMulti, 16, 0, 4]
    discard addr q
    validateBQueueParams(BQueue[int, ccSingle, ccMulti, 16, 0, 4])

  test "bounded mpmc-equivalent shape compiles and validates":
    var q: BQueue[int, ccMulti, ccMulti, 16, 4, 4]
    discard addr q
    validateBQueueParams(BQueue[int, ccMulti, ccMulti, 16, 4, 4])

  test "bounded spsc-equivalent shape compiles and validates":
    var q: BQueue[int, ccSingle, ccSingle, 16, 0, 0]
    discard addr q
    validateBQueueParams(BQueue[int, ccSingle, ccSingle, 16, 0, 0])

suite "Queue type shell — positive instantiations (unbounded)":

  test "unbounded spsc-absorbed shape compiles and validates":
    var q: Queue[int, ccSingle, ccSingle, stEager, 16, 4]
    discard addr q
    validateQueueParams(Queue[int, ccSingle, ccSingle, stEager, 16, 4])

  test "unbounded mpsc-equivalent shape compiles and validates":
    var q: Queue[int, ccMulti, ccSingle, stEager, 16, 4]
    discard addr q
    validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, 16, 4])

  test "unbounded spmc-equivalent shape compiles and validates":
    var q: Queue[int, ccSingle, ccMulti, stEager, 16, 4]
    discard addr q
    validateQueueParams(Queue[int, ccSingle, ccMulti, stEager, 16, 4])

  test "unbounded mpmc-equivalent shape compiles and validates":
    var q: Queue[int, ccMulti, ccMulti, stEager, 16, 4]
    discard addr q
    validateQueueParams(Queue[int, ccMulti, ccMulti, stEager, 16, 4])

suite "BQueue type shell — guard reachability (negative controls)":

  test "BQueue requires N > 0":
    check not compiles(
      validateBQueueParams(BQueue[int, ccMulti, ccSingle, 0, 4, 0]))

  test "BQueue + ccProd=ccMulti requires P > 0":
    check not compiles(
      validateBQueueParams(BQueue[int, ccMulti, ccSingle, 16, 0, 0]))

  test "BQueue + ccProd=ccSingle must have P == 0":
    check not compiles(
      validateBQueueParams(BQueue[int, ccSingle, ccSingle, 16, 4, 0]))

  test "BQueue + ccCons=ccMulti requires C > 0":
    check not compiles(
      validateBQueueParams(BQueue[int, ccSingle, ccMulti, 16, 0, 0]))

  test "BQueue + ccCons=ccSingle must have C == 0":
    check not compiles(
      validateBQueueParams(BQueue[int, ccMulti, ccSingle, 16, 4, 4]))

suite "Queue type shell — guard reachability (negative controls)":

  test "Queue requires S > 0":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, 0, 4]))

  test "Queue requires MaxThreads > 0":
    check not compiles(
      validateQueueParams(Queue[int, ccMulti, ccSingle, stEager, 16, 0]))

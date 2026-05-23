## Migrated from `t_sipsic.nim` — exercises the unified Queue type
## under the `ccSingle x ccSingle` (SPSC) bounded cardinality, which
## corresponds to the legacy `Sipsic[N, T]` shape.
##
## Mechanical conversion per Doc C 5 (migration table):
##   Sipsic[N, T] -> BQueue[T, ccSingle, ccSingle, ##                          N, 0, 0]
##   initSipsic[N, T]() -> newBQueue[T, ccSingle, ccSingle, ##                                    N, 0, 0]()
##
## Test count parity: 21 tests (matches t_sipsic.nim).
## Track B / Task B2. Doc C 3.7, 5, 6.1.

import options
import sequtils
import unittest2

import lockfreequeues
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import ./t_integration
import ./t_sic
import ./t_sip

var q = q_mod.newBQueue[int, ccSingle, ccSingle, 8, 0, 0]()

suite "BQueue[int, ccSingle, ccSingle, 8, 0, 0]":
  test "capacity":
    check(q.capacity == 8)

  test "initial state":
    q.checkState(
      head = 0, tail = 0, storage = repeat(0, 9) # N+1 slots
    )

suite "push(Queue SPSC, T)":
  setup:
    q.reset()

  test "basic":
    testSipPush(q)

  test "overflow":
    testSipPushOverflow(q)

  test "wrap":
    testSipPushWrap(q)

suite "push(Queue SPSC, seq[T])":
  setup:
    q.reset()

  test "basic":
    testSipPushSeq(q)

  test "overflow":
    testSipPushSeqOverflow(q)

  test "wrap":
    testSipPushSeqWrap(q)

suite "pop(Queue SPSC)":
  setup:
    q.reset()

  test "one":
    testSicPopOne(q)

  test "all":
    testSicPopAll(q)

  test "empty":
    testSicPopEmpty(q)

  test "too many":
    testSicPopTooMany(q)

  test "wrap":
    testSicPopWrap(q)

suite "pop(Queue SPSC, int)":
  setup:
    q.reset()

  test "one":
    testSicPopCountOne(q)

  test "all":
    testSicPopCountAll(q)

  test "empty":
    testSicPopCountEmpty(q)

  test "too many":
    testSicPopCountTooMany(q)

  test "wrap":
    testSicPopCountWrap(q)

suite "capacity(Queue SPSC)":
  test "basic":
    testCapacity(q)

suite "Queue SPSC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)

  test "wraps":
    testWraps(q)

## Migrated from `t_mupsic.nim` — exercises the unified Queue type
## under the `ccMulti x ccSingle` (MPSC) bounded cardinality, which
## corresponds to the legacy `Mupsic[N, P, T]` shape.
##
## Mechanical conversion per Doc C 5 (migration table):
##   Mupsic[N, P, T] -> BQueue[T, ccMulti, ccSingle, ##                            N, P, 0]
##   initMupsic[N, P, T]() -> newBQueue[T, ccMulti, ccSingle, ##                                       N, P, 0]()
##
## NOTE: the queue variable is named `q` (not `queue`) to avoid the
## name-collision with the imported `lockfreequeues/queue` module.
## Test count parity: 28 tests (matches t_mupsic.nim).
##
## Track B / Task B2. Doc C 3.7, 5, 6.1.

import options
import unittest2

import lockfreequeues
import lockfreequeues/bqueue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import ./t_integration
import ./t_mup
import ./t_sic

var q = q_mod.newBQueue[int, ccMulti, ccSingle, 8, 4, 0]()

suite "BQueue[int, ccMulti, ccSingle, 8, 4, 0]":
  test "capacity":
    check(q.capacity == 8)

  test "producerCount":
    check(q.producerCount == 4)

  test "initial state":
    q.checkState(head = 0'u64, tail = 0'u64)

suite "getProducer(Queue MPSC)":
  setup:
    q.reset()

  test "assigns by thread id":
    testMupGetProducerAssigns(q)

  test "reuses assigned":
    testMupGetProducerReusesAssigned(q)

  test "explicit index":
    testMupGetProducerExplicitIndex(q)

  test "throws NoProducersAvailableError":
    testMupGetProducerThrowsNoProducersAvailable(q)

suite "push(Queue MPSC)":
  setup:
    q.reset()

  # B.2 Bundle E: direct push on a ccMulti Queue is now a compile-time
  # `{.error.}`. The former runtime `InvalidCallDefect` smoke-tests are
  # superseded by Bundle J compile-fail negative-controls under
  # tests/should_fail/ (added in 3.3.11-B.3).

suite "push(QueueProducer MPSC, T)":
  setup:
    q.reset()

  test "basic":
    testMupPush(q)

  test "overflow":
    testMupPushOverflow(q)

  test "wrap":
    testMupPushWrap(q)

suite "push(QueueProducer MPSC, seq[T])":
  setup:
    q.reset()

  test "basic":
    testMupPushSeq(q)

  test "overflow":
    testMupPushSeqOverflow(q)

  test "wrap":
    testMupPushSeqWrap(q)

suite "pop(Queue MPSC)":
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

suite "pop(Queue MPSC, int)":
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

suite "capacity(Queue MPSC)":
  test "basic":
    testCapacity(q)

suite "Queue MPSC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)

  test "wraps":
    testWraps(q)

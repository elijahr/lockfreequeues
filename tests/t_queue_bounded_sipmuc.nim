## Migrated from `t_sipmuc.nim` — exercises the unified Queue type
## under the `ccSingle x ccMulti` (SPMC) bounded cardinality, which
## corresponds to the legacy `Sipmuc[N, C, T]` shape.
##
## Mechanical conversion per Doc C 5 (migration table):
##   Sipmuc[N, C, T] -> Queue[T, ccSingle, ccMulti, stEager, rkNone,
##                             N, 0, C, 0, 0]
##   initSipmuc[N, C, T]() -> initQueue[T, ccSingle, ccMulti, stEager,
##                                       N, 0, C]()
##
## Test count parity: 27 tests (matches t_sipmuc.nim).
## Track B / Task B2. Doc C 3.7, 5, 6.1.

import lockfreequeues/atomic_dsl
import options
import sequtils
import unittest2

import lockfreequeues
import lockfreequeues/exceptions
import lockfreequeues/queue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import ./t_integration
import ./t_suc

var q = q_mod.initQueue[int, ccSingle, ccMulti, stEager, 8, 0, 4]()

suite "Queue[int, ccSingle, ccMulti, stEager, rkNone, 8, 0, 4, 0, 0]":
  test "capacity":
    check(q.capacity == 8)

  test "consumerCount":
    check(q.consumerCount == 4)

  test "initial state":
    q.checkState(head = 0'u64, tail = 0'u64, data = repeat(0, 8))
    q.checkState(head = 0'u64, tail = 0'u64)

suite "getConsumer(Queue SPMC)":
  setup:
    q.reset()

  test "assigns by thread id":
    testSucGetConsumerAssigns(q)

  test "reuses assigned":
    testSucGetConsumerReusesAssigned(q)

  test "explicit index":
    testSucGetConsumerExplicitIndex(q)

  test "throws NoConsumersAvailableError":
    for c in 0 ..< 4:
      q.consumerThreadIds[c].store(c + 1000, moSequentiallyConsistent)

    expect NoConsumersAvailableError:
      discard q.getConsumer()

suite "pop(QueueConsumer SPMC)":
  setup:
    q.reset()

  test "one":
    testSucPopOne(q)

  test "all":
    testSucPopAll(q)

  test "empty":
    testSucPopEmpty(q)

  test "too many":
    testSucPopTooMany(q)

  test "wrap":
    testSucPopWrap(q)

suite "pop(QueueConsumer SPMC, int)":
  setup:
    q.reset()

  test "one":
    testSucPopCountOne(q)

  test "all":
    testSucPopCountAll(q)

  test "empty":
    testSucPopCountEmpty(q)

  test "too many":
    testSucPopCountTooMany(q)

  test "wrap":
    testSucPopCountWrap(q)

suite "pop(Queue SPMC)":
  setup:
    q.reset()

  # B.2 Bundle E: direct pop on a ccMulti-consumer Queue is now a
  # compile-time `{.error.}`. The former runtime `InvalidCallDefect`
  # smoke-tests are superseded by Bundle J compile-fail negative-
  # controls under tests/should_fail/ (added in 3.3.11-B.3).

suite "push(Queue SPMC, T)":
  setup:
    q.reset()

  test "basic":
    check(q.push(1) == true)
    q.checkState(head = 0'u64, tail = 1'u64)

  test "overflow":
    for i in 1 .. 8:
      check(q.push(i) == true)
    check(q.push(9) == false)

  test "wrap":
    for i in 1 .. 8:
      discard q.push(i)
    for i in 1 .. 4:
      discard q.getConsumer(0).pop()
    for i in 9 .. 12:
      check(q.push(i) == true)
    q.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "push(Queue SPMC, seq[T])":
  setup:
    q.reset()

  test "basic":
    check(q.push(@[1, 2, 3, 4]).isNone)
    q.checkState(head = 0'u64, tail = 4'u64)

  test "overflow":
    let unpushed = q.push(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    check(unpushed.isSome)
    check(unpushed.get == 8 .. 9)

  test "wrap":
    discard q.push(@[1, 2, 3, 4, 5, 6, 7, 8])
    for i in 1 .. 4:
      discard q.getConsumer(0).pop()
    check(q.push(@[9, 10, 11, 12]).isNone)
    q.checkState(head = 4'u64, tail = 12'u64, data = (@[9, 10, 11, 12, 5, 6, 7, 8]))

suite "capacity(Queue SPMC)":
  test "basic":
    testCapacity(q)

suite "Queue SPMC integration":
  setup:
    q.reset()

  test "head and tail reset":
    testHeadAndTailReset(q)

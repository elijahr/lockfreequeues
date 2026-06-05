## Phase B T14: positive control — bounded MPMC `BQueue[T]` preserves
## wide-T support after the v5.0.0 unbounded MPMC `sizeof(T) <= 8`
## narrowing.
##
## The v5.0.0 BREAKING change constrains the UNBOUNDED MPMC arm
## (`Queue[T, ccMulti, ccMulti, ...]`) to `supportsCopyMem(T) and
## sizeof(T) <= 8` because the strict-LCRQ migration publishes via
## 128-bit DWCAS into `Atomic[Pair[uint64, T]]` (design §11.2).
##
## The BOUNDED MPMC arm (`BQueue[T, ccMulti, ccMulti, ...]`) uses the
## classical Vyukov per-slot sequence-counter protocol (no DWCAS, no
## 8-byte payload bound) and is UNAFFECTED by the narrowing. This test
## is the structural assertion that `BQueue[T]` continues to accept
## `T` payloads larger than 8 bytes — concretely `array[3, int]` (24
## bytes on a 64-bit target).
##
## Twin of `tests/should_fail/unbounded_mpmc_wide_T_rejected.nim`
## (the negative control): together they form the SCOPE-7 structural
## tripwire against accidental cross-queue constraint extension during
## Phase B. If a regression accidentally widens the `sizeof(T) <= 8`
## guard into `bqueue.nim`, this file fails at compile-time — the
## tripwire fires before any user-visible breakage.
##
## Per design §9.3.1 / SCOPE-7. Runs under all four MMs via the
## standard `tests/test.nim` MM matrix.

import options
import unittest2

import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "Phase B T14: BQueue MPMC accepts wide T (positive control)":
  test "BQueue[array[3, int], ccMulti, ccMulti, 64, 8, 8] compiles + round-trips 4 distinct values":
    # array[3, int] = 24 bytes on a 64-bit target — well over the
    # unbounded MPMC arm's 8-byte ceiling. BQueue MUST accept it
    # because the Vyukov per-slot seq-counter protocol does NOT
    # require packing the payload alongside a 64-bit seq into a single
    # 16-byte DWCAS word (each slot's payload + counter live in
    # separate, independently-addressed cell fields).
    var q = initBQueue[array[3, int], ccMulti, ccMulti, 64, 8, 8]()
    var producer = q.getProducerHere(0)
    var consumer = q.getConsumerHere(0)

    let payloads: array[4, array[3, int]] =
      [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]]

    for p in payloads:
      check producer.push(p)

    for expected in payloads:
      let popped = consumer.pop()
      check popped.isSome
      check popped.get == expected

    check consumer.pop().isNone

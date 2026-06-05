## Unit test: MPMC consumer claim returns published values via DWCAS.
##
## Phase B Task T6 of the strict-LCRQ migration. After T6 wires
## `tryClaim(seg.cells[mySlot], expectedSeq=0)` into the MPMC arm of
## `pop` (replacing the T3 break-empty stub), a single-consumer pop
## following N pushes must return the published values in FIFO order
## and leave each cell in the claimed state (payload reset to
## default(T), seq still seq+1).
##
## Design references:
##   §5.2 — consumer claim path (tryClaim on cells[mySlot])
##   §6   — close-on-empty integration (HIGH-2 inline-skip)
##   §8   — memory ordering (success=moAcquireRelease, failure=moRelaxed)
##   §2.3.1 / CRITICAL-1 — tryClaim NEVER inspects observed.second:
##                         q.push(0) (default(T)) must return some(0).
##
## Pre-T6 baseline: the T3 stub `break` (after `discard prevIdx`)
## returned `none(T)` always. Both assertions below fail under T3..T5.

import std/options
import std/unittest

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/endpoint
import debra as debra_mod
from debra import DebraManager, initDebraManager

suite "T6: MPMC consumer claim returns published values (design §5.2, §6, §8)":
  test "T6.C1: push 1..4 then pop 4 times returns 1,2,3,4 FIFO":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)

    var producer = queue.getProducerHere()
    for i in 1 .. 4:
      producer.push(i)

    var consumer = queue.getConsumerHere()
    let r1 = consumer.pop()
    let r2 = consumer.pop()
    let r3 = consumer.pop()
    let r4 = consumer.pop()
    let r5 = consumer.pop()

    check r1 == some(1)
    check r2 == some(2)
    check r3 == some(3)
    check r4 == some(4)
    check r5 == none(int)

  test "T6.C2: push 0 (default(T)) then pop returns some(0) — CRITICAL-1 regression guard":
    # Per design §2.3.1 / CRITICAL-1, tryClaim MUST NOT inspect
    # observed.second. A legitimate publish of default(T) (e.g. 0 for
    # int, nil for ptr/ref) must be returned as some(default(T)),
    # NOT silently dropped as none(T). The spike's
    # `if observed.second == default(T): return none(T)` short-circuit
    # is forbidden in the production primitive; this test pins that.
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)

    var producer = queue.getProducerHere()
    producer.push(0)

    var consumer = queue.getConsumerHere()
    let r = consumer.pop()

    check r == some(0)

## T8 — MPMC pop §5.2 slow-path inline-skip regression coverage.
##
## Background
## ----------
## Phase B Task T8 wires the strict-LCRQ §5.2 slow-path on the MPMC
## consumer arm: when `mySlot >= tail` but a re-load shows the producer
## has reserved a tail slot past `mySlot` (i.e. the producer is
## mid-publish OR a peer consumer drove close-on-empty on an earlier
## slot), the consumer must NOT simply `break` out of the pop loop.
## Instead it drives `tryCloseOnEmpty(seg.cells[mySlot], 0'u64)` and
## inline-skips closed cells via a per-pop stack counter
## `closesSeenThisSegment`, escalating to `nextSeg` when the count
## reaches the StarvingThreshold = S bound (design §5.2.1, §7.1).
##
## The HIGH-2 review finding for this site was that a per-pop-call
## local counter cannot accumulate across pop() calls. A low-throughput
## consumer issuing one pop per request on a partially-closed segment
## would never reach the threshold within a single call → livelock.
## The fix is the inline-skip pattern: advance `mySlot` past closed
## cells WITHIN THE SAME pop() call, bounded by S iterations.
##
## Test strategy
## -------------
## The HIGH-2 livelock is fundamentally a multi-consumer race, and
## reliably reproducing close-on-empty arbitration requires concurrent
## consumers (which `t_lcrq_pop_race` already covers under stress). The
## tests here are deterministic single-threaded behavioral guards on
## the slow-path code path:
##
##   T8.S1: empty queue → pop returns none(T). Exercises the
##   `mySlot >= tail` branch with no producer activity. Validates the
##   slow-path doesn't infinite-loop, doesn't crash, and returns
##   none(T) cleanly when no successor segment exists.
##
##   T8.S2: drain a partially-filled segment, then push more, then
##   pop again. Exercises segment cross-over: the consumer's
##   prevConsumerIdx state must remain consistent across the
##   slow-path branch and subsequent fast-path claims.
##
##   T8.S3: alternating push/pop with small segment size. Forces
##   repeated entry into the `mySlot >= tail` branch (after each
##   pop the queue is briefly empty) without losing items.
##
## Design references:
##   §5.2   — MPMC consumer post-CAS empty branch (slow-path)
##   §5.2.1 — inline-skip rationale (HIGH-2 remediation)
##   §7.1   — StarvingThreshold = S formal bound
##   §7.2   — per-consumer-call close counter (closesSeenThisSegment)

import std/options
import std/unittest

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/endpoint
import debra as debra_mod
from debra import DebraManager, initDebraManager

suite "T8: MPMC pop §5.2 slow-path inline-skip (HIGH-2)":
  test "T8.S1: pop on empty queue returns none(T) cleanly":
    # Slow-path entry: mySlot == 0, tail == 0 → mySlot >= tail. Inside
    # the slow-path block the inner condition `mySlot < S and
    # seg.tail.load > mySlot` is false (tail is 0), so the slow-path
    # scan does nothing and we fall through to the nextSeg check;
    # nextSeg is nil → break with result = none(T).
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 8, 4](addr manager)

    var consumer = queue.getConsumerHere()
    let r = consumer.pop()

    check r == none(int)

  test "T8.S2: drain, refill, drain again — no items lost across slow-path entries":
    # After draining a partially-filled segment, the next pop sees
    # mySlot >= tail and enters the slow-path. A subsequent push must
    # be observable to the consumer on a later pop. This guards
    # against the bug where the slow-path inline-skip mutates
    # prevConsumerIdx state inconsistently with the producer.
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 8, 4](addr manager)

    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()

    producer.push(10)
    producer.push(20)
    producer.push(30)

    check consumer.pop() == some(10)
    check consumer.pop() == some(20)
    check consumer.pop() == some(30)
    check consumer.pop() == none(int) # slow-path entry, queue empty

    producer.push(40)
    producer.push(50)

    check consumer.pop() == some(40)
    check consumer.pop() == some(50)
    check consumer.pop() == none(int) # slow-path entry again

  test "T8.S3: alternating push/pop sequences — slow-path FIFO preserved":
    # Each pop empties the queue briefly, so every subsequent pop on
    # the empty state enters the slow-path. Verify FIFO across
    # repeated slow-path entries.
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 8, 4](addr manager)

    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()

    for i in 1 .. 12:
      producer.push(i)
      check consumer.pop() == some(i)
      check consumer.pop() == none(int)

  test "T8.S4: segment cross-over with slow-path on tail segment":
    # Push enough to span 2 segments (S=4 here), drain fully so the
    # consumer hits the slow-path on the second (tail) segment with
    # no successor. Verifies the slow-path's nextSeg==nil exit path.
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var queue = newUnboundedMpmcQueue[int, stEager, 4, 4](addr manager)

    var producer = queue.getProducerHere()
    var consumer = queue.getConsumerHere()

    for i in 1 .. 6: # 4 in seg0, 2 in seg1
      producer.push(i)

    for i in 1 .. 6:
      check consumer.pop() == some(i)

    check consumer.pop() == none(int) # slow-path on tail seg, no next

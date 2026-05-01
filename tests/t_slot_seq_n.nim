import unittest2
import lockfreequeues/atomic_dsl
import lockfreequeues/typestates/virtual_values_n
import lockfreequeues/typestates/slot_seq_n

# Helper: convert a raw int slot index to a PhysicalSlotN[N] via the
# typestate-blessed path (initRawN -> validate -> index). This mirrors how
# the bounded MPMC verbs will obtain a slot from a virtual position.
proc slot[N: static int](i: int): PhysicalSlotN[N] {.inline.} =
  initRawN[N](i).validate().index()

suite "SlotSeqN[N]":
  test "init sets seq[i] = i for N=4":
    var s: SlotSeqN[4]
    s.init()
    for i in 0 ..< 4:
      check(s.load(slot[4](i), moRelaxed) == uint64(i))

  test "store and load round-trip with explicit acquire/release":
    var s: SlotSeqN[8]
    s.init()
    let idx = slot[8](3)
    s.store(idx, 99'u64, moRelease)
    check(s.load(idx, moAcquire) == 99'u64)

  test "independent slots do not alias":
    var s: SlotSeqN[4]
    s.init()
    s.store(slot[4](0), 100'u64, moRelease)
    check(s.load(slot[4](0), moAcquire) == 100'u64)
    check(s.load(slot[4](1), moAcquire) == 1'u64)
    check(s.load(slot[4](2), moAcquire) == 2'u64)
    check(s.load(slot[4](3), moAcquire) == 3'u64)

  test "generation rollover sequence (write i, i+N, i+2N, ...)":
    # Drive a single slot through the producer/consumer alternation pattern:
    # init -> producer writes pos+1=1 -> consumer writes pos+N=4 -> producer
    # writes 5 -> consumer writes 8 -> ... For N=4 slot 0, this is the
    # sequence 0,1,4,5,8,9,12,13,...
    var s: SlotSeqN[4]
    s.init()
    let idx = slot[4](0)
    check(s.load(idx, moAcquire) == 0'u64)
    for k in 0 ..< 4:
      let producerWrite = uint64(k * 4 + 1)
      s.store(idx, producerWrite, moRelease)
      check(s.load(idx, moAcquire) == producerWrite)
      let consumerWrite = uint64((k + 1) * 4)
      s.store(idx, consumerWrite, moRelease)
      check(s.load(idx, moAcquire) == consumerWrite)

  # I3: explicit edge cases for the smallest legal queue sizes.

  test "N=1 edge case: single slot, every claim hits same physical slot":
    var s: SlotSeqN[1]
    s.init()
    let idx = slot[1](0)
    check(s.load(idx, moAcquire) == 0'u64)
    # For N=1, every generation writes seq+=1 (producer) then seq+=1 (consumer).
    for k in 0'u64 ..< 8'u64:
      s.store(idx, k * 2 + 1, moRelease)
      check(s.load(idx, moAcquire) == k * 2 + 1)
      s.store(idx, k * 2 + 2, moRelease)
      check(s.load(idx, moAcquire) == k * 2 + 2)

  test "N=2 edge case: smallest size where seq can lag a full generation":
    var s: SlotSeqN[2]
    s.init()
    check(s.load(slot[2](0), moRelaxed) == 0'u64)
    check(s.load(slot[2](1), moRelaxed) == 1'u64)
    # Producer at pos=0 writes seq[0]=1. Consumer leaves seq[0]=2 (pos+N).
    # Producer at pos=2 (slot 0 again) writes seq[0]=3. Consumer leaves =4.
    let s0 = slot[2](0)
    s.store(s0, 1'u64, moRelease)
    s.store(s0, 2'u64, moRelease)
    s.store(s0, 3'u64, moRelease)
    s.store(s0, 4'u64, moRelease)
    check(s.load(s0, moAcquire) == 4'u64)
    # Slot 1 is independent and still sees its initial value.
    check(s.load(slot[2](1), moAcquire) == 1'u64)

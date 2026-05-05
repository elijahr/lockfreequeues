## Per-slot sequence counters (Vyukov bounded MPMC).
##
## Each slot carries an Atomic[uint64] seq, initialised to its index. Producers
## and consumers compare a globally-monotonic claim cursor against this counter
## to decide whether the slot is owned by the current generation (claimable),
## the previous generation's pending consumer (full from the producer's POV),
## or a future generation (empty from the consumer's POV). See design doc
## §4 for the rationale behind the per-slot generation counter and §10.1 for
## the recipe this module implements.
##
## Memory ordering is supplied by the caller at every load/store; the module
## itself is order-agnostic so call sites can document intent inline. The
## order parameter is `static MemoryOrder` because `debra/atomics` requires
## compile-time validation of the load/store ordering domain.
##
## Indexing uses PhysicalSlotN[N] for type-safe slot access (carried over from
## the old CommittedFlagsN module) — an arbitrary `int` cannot be passed in,
## eliminating a class of off-by-one indexing bugs.

import ../atomic_dsl
import ./virtual_values_n

type SlotSeqN*[N: static int] = object
  ## Array of per-slot sequence counters. Used by bounded MPMC/SPMC/MPSC
  ## queues that adopt the Vyukov per-slot generation protocol.
  seqs*: array[N, Atomic[uint64]]

proc init*[N: static int](s: var SlotSeqN[N]) =
  ## Initialize seq[i] = i. CRITICAL: NOT zeros (zero-init violates the
  ## algorithm; the first producer at pos=0 expects seq[0]=0, seq[1]=1, ...).
  for i in 0 ..< N:
    s.seqs[i].store(uint64(i), moRelaxed)

proc load*[N: static int](
    s: var SlotSeqN[N], idx: PhysicalSlotN[N], order: static MemoryOrder
): uint64 {.inline.} =
  s.seqs[idx.slotValue].load(order)

proc store*[N: static int](
    s: var SlotSeqN[N], idx: PhysicalSlotN[N], val: uint64, order: static MemoryOrder
) {.inline.} =
  s.seqs[idx.slotValue].store(val, order)

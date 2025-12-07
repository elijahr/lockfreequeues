## SPMC Pop operation lifecycle typestate.
##
## Enforces correct sequencing for multi-consumer pop:
## Start -> LoadPointers -> CheckEmpty -> CheckCommitted -> TryClaim -> Complete
##
## Key invariant: Once a slot is claimed, it MUST be consumed. No abandonment.

import atomics
import options
import typestates

import ./virtual_values_n
import ./storage_n
import ./committed_flags_n
import ./atomic_loaders
import ./fullness_checks

type
  SPMCPopStart*[N: static int] = object
    ## Entry point. No data yet.

  SPMCPopPointersLoaded*[N: static int] = object
    ## Loaded reservedHead and tail.
    reservedHead*: WrappedValueN[N]
    tail*: WrappedValueN[N]

  SPMCPopNotEmpty*[N: static int] = object
    ## Confirmed queue has items.
    reservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPopSlotReady*[N: static int] = object
    ## Slot is committed - safe to claim.
    reservedHead*: WrappedValueN[N]
    newReservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPopSlotClaimed*[N: static int] = object
    ## CAS succeeded - we own this slot. MUST consume it.
    newReservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPopEmpty* = object
    ## Terminal: queue was empty.


typestate SPMCPopOp[N]:
  states SPMCPopStart[N], SPMCPopPointersLoaded[N], SPMCPopNotEmpty[N],
         SPMCPopSlotReady[N], SPMCPopSlotClaimed[N], SPMCPopEmpty
  transitions:
    SPMCPopStart[N] -> SPMCPopPointersLoaded[N]
    SPMCPopPointersLoaded[N] -> SPMCPopNotEmpty[N] | SPMCPopEmpty
    SPMCPopNotEmpty[N] -> SPMCPopSlotReady[N] | SPMCPopStart[N]
    SPMCPopSlotReady[N] -> SPMCPopSlotClaimed[N] | SPMCPopStart[N]


# Forward declaration for Sipmuc (avoid circular import)
type
  SipmucBase*[N, C: static int, T] = object
    head* {.align: 64.}: Atomic[int]
    reservedHead* {.align: 64.}: Atomic[int]
    tail* {.align: 64.}: Atomic[int]
    storage*: StorageN[N, T]
    committed*: CommittedFlagsN[N]


proc start*[N: static int](): SPMCPopStart[N] {.inline.} =
  ## Begin a pop operation.
  SPMCPopStart[N]()


proc loadPointers*[N, C: static int, T](
  op: SPMCPopStart[N],
  queue: var SipmucBase[N, C, T]
): SPMCPopPointersLoaded[N] {.inline, transition.} =
  ## Load reservedHead and tail atomically.
  let reservedHead = loadAcquireN[N](queue.reservedHead).validate()
  let tail = loadAcquireN[N](queue.tail).validate()
  SPMCPopPointersLoaded[N](reservedHead: reservedHead, tail: tail)


proc checkEmpty*[N: static int](
  op: SPMCPopPointersLoaded[N]
): SPMCPopNotEmpty[N] | SPMCPopEmpty {.inline, transition.} =
  ## Check if queue is empty.
  if emptyN(op.reservedHead, op.tail):
    SPMCPopEmpty()
  else:
    let slot = op.reservedHead.index()
    SPMCPopNotEmpty[N](reservedHead: op.reservedHead, slot: slot)


proc checkCommitted*[N, C: static int, T](
  op: SPMCPopNotEmpty[N],
  queue: var SipmucBase[N, C, T]
): SPMCPopSlotReady[N] | SPMCPopStart[N] {.inline, transition.} =
  ## Check if slot is committed. Uncommitted = retry from start.
  if not queue.committed.load(op.slot):
    SPMCPopStart[N]()  # Producer still writing, retry
  else:
    let newReservedHead = op.reservedHead.incOrResetN(1)
    SPMCPopSlotReady[N](
      reservedHead: op.reservedHead,
      newReservedHead: newReservedHead,
      slot: op.slot
    )


proc tryClaim*[N, C: static int, T](
  op: SPMCPopSlotReady[N],
  queue: var SipmucBase[N, C, T]
): SPMCPopSlotClaimed[N] | SPMCPopStart[N] {.inline, transition.} =
  ## CAS to claim the slot. Failure = retry from start.
  var expected = op.reservedHead.value
  if queue.reservedHead.compareExchangeWeak(expected, op.newReservedHead.value, moRelease, moAcquire):
    SPMCPopSlotClaimed[N](newReservedHead: op.newReservedHead, slot: op.slot)
  else:
    SPMCPopStart[N]()


proc complete*[N, C: static int, T](
  op: SPMCPopSlotClaimed[N],
  queue: var SipmucBase[N, C, T]
): T {.inline.} =
  ## Read value, clear committed, advance head. Returns the value.
  ## NOT a transition - this is the final extraction.
  let value = queue.storage[op.slot]
  queue.committed.store(op.slot, false)
  # Fire-and-forget head advance (best effort for other consumers)
  var expectedHead = op.newReservedHead.value - 1
  discard queue.head.compareExchangeWeak(expectedHead, op.newReservedHead.value, moRelease, moAcquire)
  value


proc extractNone*[T](op: SPMCPopEmpty): Option[T] {.inline.} =
  ## Terminal: extract none result.
  none(T)

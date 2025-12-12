## MPMC Pop operation lifecycle typestate.
##
## Enforces correct sequencing for multi-consumer pop in MPMC queues:
## Start -> LoadPointers -> CheckEmpty -> CheckCommitted -> TryClaim -> Complete
##
## Key difference from SPMC: uses reservedTail (not tail) for empty check,
## because producers reserve slots before writing.
##
## Key invariant: Once a slot is claimed, it MUST be consumed. No abandonment.
##
## Branching transitions use named result types:
## - EmptyCheck for checkEmpty (-> NotEmpty | Empty)
## - CommittedCheck for checkCommitted (-> SlotReady | Start)
## - ClaimResult for tryClaim (-> SlotClaimed | Start)

import atomics
import typestates

import ./virtual_values_n
import ./storage_n
import ./committed_flags_n
import ./atomic_loaders
import ./fullness_checks

type
  MPMCPopStart*[N: static int] = object
    ## Entry point. No data yet.

  MPMCPopPointersLoaded*[N: static int] = object
    ## Loaded reservedHead and reservedTail.
    reservedHead*: WrappedValueN[N]
    reservedTail*: WrappedValueN[N]

  MPMCPopNotEmpty*[N: static int] = object
    ## Confirmed queue has items.
    reservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  MPMCPopSlotReady*[N: static int] = object
    ## Slot is committed - safe to claim.
    reservedHead*: WrappedValueN[N]
    newReservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  MPMCPopSlotClaimed*[N: static int] = object
    ## CAS succeeded - we own this slot. MUST consume it.
    newReservedHead*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  MPMCPopEmpty*[N: static int] = object
    ## Terminal: queue was empty.
    ## Generic to allow type inference in branch constructors.


typestate MPMCPopOp[N: static int]:
  inheritsFromRootObj = true
  states MPMCPopStart[N], MPMCPopPointersLoaded[N], MPMCPopNotEmpty[N],
         MPMCPopSlotReady[N], MPMCPopSlotClaimed[N], MPMCPopEmpty[N]
  transitions:
    MPMCPopStart[N] -> MPMCPopPointersLoaded[N]
    MPMCPopPointersLoaded[N] -> MPMCPopNotEmpty[N] | MPMCPopEmpty[N] as MPMCEmptyCheck[N]
    MPMCPopNotEmpty[N] -> MPMCPopSlotReady[N] | MPMCPopStart[N] as MPMCCommittedCheck[N]
    MPMCPopSlotReady[N] -> MPMCPopSlotClaimed[N] | MPMCPopStart[N] as MPMCClaimResult[N]


# Forward declaration for Mupmuc (avoid circular import)
type
  MupmucBase*[N, P, C: static int, T] = object
    head* {.align: 64.}: Atomic[int]
    reservedHead* {.align: 64.}: Atomic[int]
    reservedTail* {.align: 64.}: Atomic[int]
    storage*: StorageN[N, T]
    committed*: CommittedFlagsN[N]


proc start*[N: static int](): MPMCPopStart[N] {.inline.} =
  ## Begin a pop operation.
  MPMCPopStart[N]()


proc loadPointers*[N, P, C: static int, T](
  op: MPMCPopStart[N],
  queue: var MupmucBase[N, P, C, T]
): MPMCPopPointersLoaded[N] {.inline, transition.} =
  ## Load reservedHead and reservedTail atomically.
  ## Note: MPMC uses reservedTail (not tail) because producers reserve before writing.
  let reservedHead = loadAcquireN[N](queue.reservedHead).validate()
  let reservedTail = loadAcquireN[N](queue.reservedTail).validate()
  MPMCPopPointersLoaded[N](reservedHead: reservedHead, reservedTail: reservedTail)


proc checkEmpty*[N: static int](
  op: MPMCPopPointersLoaded[N]
): MPMCEmptyCheck[N] {.inline, transition.} =
  ## Check if queue is empty. Returns branch type.
  ## Uses reservedTail for empty check (MPMC difference from SPMC).
  if emptyN(op.reservedHead, op.reservedTail):
    MPMCEmptyCheck[N] -> MPMCPopEmpty[N]()
  else:
    let slot = op.reservedHead.index()
    MPMCEmptyCheck[N] -> MPMCPopNotEmpty[N](reservedHead: op.reservedHead, slot: slot)


proc checkCommitted*[N, P, C: static int, T](
  op: MPMCPopNotEmpty[N],
  queue: var MupmucBase[N, P, C, T]
): MPMCCommittedCheck[N] {.inline, transition.} =
  ## Check if slot is committed. Uncommitted = retry from start.
  if not queue.committed.load(op.slot):
    MPMCCommittedCheck[N] -> MPMCPopStart[N]()  # Producer still writing, retry
  else:
    let newReservedHead = op.reservedHead.incOrResetN(1)
    MPMCCommittedCheck[N] -> MPMCPopSlotReady[N](
      reservedHead: op.reservedHead,
      newReservedHead: newReservedHead,
      slot: op.slot
    )


proc tryClaim*[N, P, C: static int, T](
  op: MPMCPopSlotReady[N],
  queue: var MupmucBase[N, P, C, T]
): MPMCClaimResult[N] {.inline, transition.} =
  ## CAS to claim the slot. Failure = retry from start.
  var expected = op.reservedHead.value
  if queue.reservedHead.compareExchangeWeak(expected, op.newReservedHead.value, moRelease, moAcquire):
    MPMCClaimResult[N] -> MPMCPopSlotClaimed[N](newReservedHead: op.newReservedHead, slot: op.slot)
  else:
    MPMCClaimResult[N] -> MPMCPopStart[N]()


proc complete*[N, P, C: static int, T](
  op: MPMCPopSlotClaimed[N],
  queue: var MupmucBase[N, P, C, T]
): T {.inline.} =
  ## Read value, clear committed, advance head. Returns the value.
  ## NOT a transition - this is the final extraction.
  let value = queue.storage[op.slot]
  queue.committed.store(op.slot, false)
  # Fire-and-forget head advance (best effort for other consumers)
  var expectedHead = op.newReservedHead.value - 1
  discard queue.head.compareExchangeWeak(expectedHead, op.newReservedHead.value, moRelease, moAcquire)
  value

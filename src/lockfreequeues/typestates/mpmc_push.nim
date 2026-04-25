## MPMC Push operation lifecycle typestate.
##
## Enforces correct sequencing for multi-producer push:
## Start -> LoadPointers -> CheckFull -> TryClaim -> WriteData -> Complete
##
## Key invariant: Once a slot is claimed via CAS, data MUST be written and committed.
##
## Key difference from MPSC: Uses reservedHead (not head) for fullness check,
## because consumers can lag behind in MPMC.
##
## Uses N-slot arithmetic with committed flags. CAS on reservedTail.

import atomics
import typestates

import ./virtual_values_n
import ./storage_n
import ./committed_flags_n
import ./atomic_loaders
import ./fullness_checks

type
  MPMCPushStart*[N: static int] = object ## Entry point. No data yet.

  MPMCPushPointersLoaded*[N: static int] = object
    ## Loaded reservedTail and reservedHead.
    reservedTail*: WrappedValueN[N]
    reservedHead*: WrappedValueN[N]

  MPMCPushNotFull*[N: static int] = object
    ## Confirmed queue has space. Ready to try CAS.
    reservedTail*: WrappedValueN[N]
    newReservedTail*: WrappedValueN[N]

  MPMCPushSlotClaimed*[N: static int] = object
    ## CAS succeeded - we own this slot. MUST write and commit.
    reservedTail*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  MPMCPushDataWritten*[N: static int] = object
    ## Data written to slot. MUST mark committed.
    slot*: PhysicalSlotN[N]

  MPMCPushFull*[N: static int] = object ## Terminal: queue was full.

typestate MPMCPushOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states MPMCPushStart[N],
    MPMCPushPointersLoaded[N],
    MPMCPushNotFull[N],
    MPMCPushSlotClaimed[N],
    MPMCPushDataWritten[N],
    MPMCPushFull[N]
  transitions:
    MPMCPushStart[N] -> MPMCPushPointersLoaded[N]
    MPMCPushPointersLoaded[N] ->
      MPMCPushNotFull[N] | MPMCPushFull[N] as MPMCPushFullCheck[N]
    MPMCPushNotFull[N] ->
      MPMCPushSlotClaimed[N] | MPMCPushStart[N] as MPMCPushClaimResult[N]
    MPMCPushSlotClaimed[N] -> MPMCPushDataWritten[N]

# Forward declaration for Mupmuc (avoid circular import)
type MupmucPushBase*[N, P, C: static int, T] = object
  head* {.align: 64.}: Atomic[int]
  reservedHead* {.align: 64.}: Atomic[int]
  reservedTail* {.align: 64.}: Atomic[int]
  storage*: StorageN[N, T]
  committed*: CommittedFlagsN[N]

proc start*[N: static int](): MPMCPushStart[N] {.inline.} =
  ## Begin a push operation.
  MPMCPushStart[N]()

proc loadPointers*[N, P, C: static int, T](
    op: MPMCPushStart[N], queue: var MupmucPushBase[N, P, C, T]
): MPMCPushPointersLoaded[N] {.inline, transition.} =
  ## Load reservedTail and reservedHead atomically.
  ## MPMC KEY: Uses reservedHead (not head) because consumers can lag.
  let reservedTail = loadAcquireN[N](queue.reservedTail).validate()
  let reservedHead = loadAcquireN[N](queue.reservedHead).validate()
  MPMCPushPointersLoaded[N](reservedTail: reservedTail, reservedHead: reservedHead)

proc checkFull*[N: static int](
    op: MPMCPushPointersLoaded[N]
): MPMCPushFullCheck[N] {.inline, transition.} =
  ## Check if queue is full. Returns branch type.
  ## MPMC uses reservedHead (not head) vs reservedTail for fullness check.
  if fullN(op.reservedHead, op.reservedTail):
    MPMCPushFullCheck[N] -> MPMCPushFull[N]()
  else:
    let newReservedTail = op.reservedTail.incOrResetN(1)
    MPMCPushFullCheck[N] ->
      MPMCPushNotFull[N](
        reservedTail: op.reservedTail, newReservedTail: newReservedTail
      )

proc tryClaim*[N, P, C: static int, T](
    op: MPMCPushNotFull[N], queue: var MupmucPushBase[N, P, C, T]
): MPMCPushClaimResult[N] {.inline, transition.} =
  ## CAS to claim the slot. Failure = retry from start.
  var expected = op.reservedTail.value
  if queue.reservedTail.compareExchangeWeak(
    expected, op.newReservedTail.value, moRelease, moAcquire
  ):
    let slot = op.reservedTail.index()
    MPMCPushClaimResult[N] ->
      MPMCPushSlotClaimed[N](reservedTail: op.reservedTail, slot: slot)
  else:
    MPMCPushClaimResult[N] -> MPMCPushStart[N]()

proc writeData*[N, P, C: static int, T](
    op: MPMCPushSlotClaimed[N], queue: var MupmucPushBase[N, P, C, T], item: T
): MPMCPushDataWritten[N] {.inline, transition.} =
  ## Write item to the claimed slot.
  queue.storage[op.slot] = item
  MPMCPushDataWritten[N](slot: op.slot)

proc complete*[N, P, C: static int, T](
    op: MPMCPushDataWritten[N], queue: var MupmucPushBase[N, P, C, T]
): bool {.inline.} =
  ## Mark slot as committed. Returns success.
  queue.committed.store(op.slot, true)
  true

proc extractFalse*[N: static int](op: MPMCPushFull[N]): bool {.inline.} =
  ## Terminal: extract false result (queue was full).
  false

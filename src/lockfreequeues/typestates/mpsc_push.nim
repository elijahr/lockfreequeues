## MPSC Push operation lifecycle typestate.
##
## Enforces correct sequencing for multi-producer push:
## Start -> LoadPointers -> CheckFull -> TryClaim -> WriteData -> Complete
##
## Key invariant: Once a slot is claimed via CAS, data MUST be written and committed.
##
## Uses N-slot arithmetic with committed flags. CAS on reservedTail.

import ../atomic_dsl
import typestates

import ./virtual_values_n
import ./storage_n
import ./committed_flags_n
import ./atomic_loaders
import ./fullness_checks

type
  MPSCPushStart*[N: static int] = object ## Entry point. No data yet.

  MPSCPushPointersLoaded*[N: static int] = object ## Loaded reservedTail and head.
    reservedTail*: WrappedValueN[N]
    head*: WrappedValueN[N]

  MPSCPushNotFull*[N: static int] = object
    ## Confirmed queue has space. Ready to try CAS.
    reservedTail*: WrappedValueN[N]
    newReservedTail*: WrappedValueN[N]

  MPSCPushSlotClaimed*[N: static int] = object
    ## CAS succeeded - we own this slot. MUST write and commit.
    reservedTail*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  MPSCPushDataWritten*[N: static int] = object
    ## Data written to slot. MUST mark committed.
    slot*: PhysicalSlotN[N]

  MPSCPushFull*[N: static int] = object ## Terminal: queue was full.

typestate MPSCPushOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states MPSCPushStart[N],
    MPSCPushPointersLoaded[N],
    MPSCPushNotFull[N],
    MPSCPushSlotClaimed[N],
    MPSCPushDataWritten[N],
    MPSCPushFull[N]
  transitions:
    MPSCPushStart[N] -> MPSCPushPointersLoaded[N]
    MPSCPushPointersLoaded[N] -> MPSCPushNotFull[N] | MPSCPushFull[N] as MPSCFullCheck[
      N
    ]
    MPSCPushNotFull[N] -> MPSCPushSlotClaimed[N] | MPSCPushStart[N] as MPSCClaimResult[
      N
    ]
    MPSCPushSlotClaimed[N] -> MPSCPushDataWritten[N]

# Forward declaration for Mupsic (avoid circular import)
type MupsicBase*[N, P: static int, T] = object
  head* {.align: 64.}: Atomic[int]
  reservedTail* {.align: 64.}: Atomic[int]
  storage*: StorageN[N, T]
  committed*: CommittedFlagsN[N]

proc start*[N: static int](): MPSCPushStart[N] {.inline.} =
  ## Begin a push operation.
  MPSCPushStart[N]()

proc loadPointers*[N, P: static int, T](
    op: MPSCPushStart[N], queue: var MupsicBase[N, P, T]
): MPSCPushPointersLoaded[N] {.inline, transition.} =
  ## Load reservedTail and head atomically.
  let reservedTail = loadAcquireN[N](queue.reservedTail).validate()
  let head = loadAcquireN[N](queue.head).validate()
  MPSCPushPointersLoaded[N](reservedTail: reservedTail, head: head)

proc checkFull*[N: static int](
    op: MPSCPushPointersLoaded[N]
): MPSCFullCheck[N] {.inline, transition.} =
  ## Check if queue is full. Returns branch type.
  ## MPSC uses head (single consumer) vs reservedTail for fullness check.
  if fullN(op.head, op.reservedTail):
    MPSCFullCheck[N] -> MPSCPushFull[N]()
  else:
    let newReservedTail = op.reservedTail.incOrResetN(1)
    MPSCFullCheck[N] ->
      MPSCPushNotFull[N](
        reservedTail: op.reservedTail, newReservedTail: newReservedTail
      )

proc tryClaim*[N, P: static int, T](
    op: MPSCPushNotFull[N], queue: var MupsicBase[N, P, T]
): MPSCClaimResult[N] {.inline, transition.} =
  ## CAS to claim the slot. Failure = retry from start.
  var expected = op.reservedTail.value
  if queue.reservedTail.compareExchangeWeak(
    expected, op.newReservedTail.value, moRelease, moAcquire
  ):
    let slot = op.reservedTail.index()
    MPSCClaimResult[N] ->
      MPSCPushSlotClaimed[N](reservedTail: op.reservedTail, slot: slot)
  else:
    MPSCClaimResult[N] -> MPSCPushStart[N]()

proc writeData*[N, P: static int, T](
    op: MPSCPushSlotClaimed[N], queue: var MupsicBase[N, P, T], item: T
): MPSCPushDataWritten[N] {.inline, transition.} =
  ## Write item to the claimed slot.
  queue.storage[op.slot] = item
  MPSCPushDataWritten[N](slot: op.slot)

proc complete*[N, P: static int, T](
    op: MPSCPushDataWritten[N], queue: var MupsicBase[N, P, T]
): bool {.inline.} =
  ## Mark slot as committed. Returns success.
  queue.committed.store(op.slot, true)
  true

proc extractFalse*[N: static int](op: MPSCPushFull[N]): bool {.inline.} =
  ## Terminal: extract false result (queue was full).
  false

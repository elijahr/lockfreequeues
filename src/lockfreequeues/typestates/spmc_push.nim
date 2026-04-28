## SPMC Push operation lifecycle typestate.
##
## Enforces correct sequencing for single-producer push:
## Start -> LoadPointers -> CheckFull -> WriteData -> Complete
##
## Key invariant: Once data is written, committed flag MUST be set and tail advanced.
##
## Uses N-slot arithmetic with committed flags.

import ../atomic_dsl
import typestates

import ./virtual_values_n
import ./storage_n
import ./committed_flags_n
import ./atomic_loaders
import ./fullness_checks
import ./spmc_pop # For SipmucBase

type
  SPMCPushStart*[N: static int] = object ## Entry point. No data yet.

  SPMCPushPointersLoaded*[N: static int] = object ## Loaded tail and reservedHead.
    tail*: WrappedValueN[N]
    reservedHead*: WrappedValueN[N]

  SPMCPushNotFull*[N: static int] = object ## Confirmed queue has space.
    tail*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPushDataWritten*[N: static int] = object
    ## Data written to slot. MUST mark committed and advance tail.
    tail*: WrappedValueN[N]
    newTail*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  SPMCPushFull*[N: static int] = object ## Terminal: queue was full.

typestate SPMCPushOp[N: static int]:
  inheritsFromRootObj = true
  consumeOnTransition = false # Allow values to be passed across case branches
  states SPMCPushStart[N],
    SPMCPushPointersLoaded[N],
    SPMCPushNotFull[N],
    SPMCPushDataWritten[N],
    SPMCPushFull[N]
  transitions:
    SPMCPushStart[N] -> SPMCPushPointersLoaded[N]
    SPMCPushPointersLoaded[N] -> SPMCPushNotFull[N] | SPMCPushFull[N] as SPMCFullCheck[
      N
    ]
    SPMCPushNotFull[N] -> SPMCPushDataWritten[N]

proc start*[N: static int](): SPMCPushStart[N] {.inline.} =
  ## Begin a push operation.
  SPMCPushStart[N]()

proc loadPointers*[N, C: static int, T](
    op: SPMCPushStart[N], queue: var SipmucBase[N, C, T]
): SPMCPushPointersLoaded[N] {.inline, transition.} =
  ## Load tail and reservedHead atomically.
  let tail = loadAcquireN[N](queue.tail).validate()
  let reservedHead = loadAcquireN[N](queue.reservedHead).validate()
  SPMCPushPointersLoaded[N](tail: tail, reservedHead: reservedHead)

proc checkFull*[N: static int](
    op: SPMCPushPointersLoaded[N]
): SPMCFullCheck[N] {.inline, transition.} =
  ## Check if queue is full. Returns branch type.
  if fullN(op.reservedHead, op.tail):
    SPMCFullCheck[N] -> SPMCPushFull[N]()
  else:
    let slot = op.tail.index()
    SPMCFullCheck[N] -> SPMCPushNotFull[N](tail: op.tail, slot: slot)

proc writeData*[N, C: static int, T](
    op: SPMCPushNotFull[N], queue: var SipmucBase[N, C, T], item: T
): SPMCPushDataWritten[N] {.inline, transition.} =
  ## Write item to the slot.
  ##
  ## Wait for `committed[slot]` to be `false` before writing. The fullness
  ## check via `reservedHead` already establishes the cross-cycle
  ## happens-before chain, so this load is functionally redundant. It
  ## exists to give TSAN a direct release/acquire pair on the slot's
  ## `committed` flag between a consumer's
  ## `committed.store(false, release)` and this write. See
  ## `mpsc_push.writeData` for the same pattern.
  while queue.committed.load(op.slot):
    discard
  queue.storage[op.slot] = item
  let newTail = op.tail.incOrResetN(1)
  SPMCPushDataWritten[N](tail: op.tail, newTail: newTail, slot: op.slot)

proc complete*[N, C: static int, T](
    op: SPMCPushDataWritten[N], queue: var SipmucBase[N, C, T]
): bool {.inline.} =
  ## Mark committed and advance tail. Returns success.
  queue.committed.store(op.slot, true)
  queue.tail.storeReleaseN(op.newTail)
  true

proc extractFalse*[N: static int](op: SPMCPushFull[N]): bool {.inline.} =
  ## Terminal: extract false result (queue was full).
  false

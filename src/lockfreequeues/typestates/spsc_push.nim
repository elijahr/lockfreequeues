## SPSC Push operation lifecycle typestate.
##
## Enforces correct sequencing for single-producer push:
## Start -> LoadPointers -> CheckFull -> WriteData -> Complete
##
## Key invariant: Once data is written, tail MUST be advanced.
##
## Uses N+1 slot arithmetic (no committed flags needed for SPSC).

import debra/atomics
import typestates

import ./virtual_values_n1
import ./storage_n1
import ./atomic_loaders
import ./fullness_checks

type
  SPSCPushStart*[N: static int] = object ## Entry point. No data yet.

  SPSCPushPointersLoaded*[N: static int] = object ## Loaded head and tail.
    head*: WrappedValueN1[N]
    tail*: WrappedValueN1[N]

  SPSCPushNotFull*[N: static int] = object ## Confirmed queue has space.
    tail*: WrappedValueN1[N]
    slot*: PhysicalSlotN1[N]

  SPSCPushDataWritten*[N: static int] = object
    ## Data written to slot. MUST advance tail.
    newTail*: WrappedValueN1[N]

  SPSCPushFull*[N: static int] = object ## Terminal: queue was full.

typestate SPSCPushOp[N: static int]:
  inheritsFromRootObj = true
  opaqueStates = true
  states SPSCPushStart[N],
    SPSCPushPointersLoaded[N],
    SPSCPushNotFull[N],
    SPSCPushDataWritten[N],
    SPSCPushFull[N]
  initial:
    SPSCPushStart[N]
  terminal:
    SPSCPushDataWritten[N]
    SPSCPushFull[N]
  transitions:
    SPSCPushStart[N] -> SPSCPushPointersLoaded[N]
    SPSCPushPointersLoaded[N] -> SPSCPushNotFull[N] | SPSCPushFull[N] as SPSCFullCheck[
      N
    ]
    SPSCPushNotFull[N] -> SPSCPushDataWritten[N]

# Forward declaration for Spsc (avoid circular import)
type SpscBase*[N: static int, T] = object
  head* {.align: 64.}: Atomic[int]
  tail* {.align: 64.}: Atomic[int]
  storage*: StorageN1[N, T]

proc start*[N: static int](): SPSCPushStart[N] {.inline.} =
  ## Begin a push operation.
  SPSCPushStart[N]()

proc loadPointers*[N: static int, T](
    op: SPSCPushStart[N], queue: var SpscBase[N, T]
): SPSCPushPointersLoaded[N] {.inline, transition.} =
  ## Load head and tail atomically.
  let tail = loadAcquireN1[N](queue.tail).validate()
  let head = loadSequentialN1[N](queue.head).validate()
  SPSCPushPointersLoaded[N](head: head, tail: tail)

proc checkFull*[N: static int](
    op: SPSCPushPointersLoaded[N]
): SPSCFullCheck[N] {.inline, transition.} =
  ## Check if queue is full. Returns branch type.
  if fullN1(op.head, op.tail):
    SPSCFullCheck[N] -> SPSCPushFull[N]()
  else:
    let slot = op.tail.index()
    SPSCFullCheck[N] -> SPSCPushNotFull[N](tail: op.tail, slot: slot)

proc writeData*[N: static int, T](
    op: SPSCPushNotFull[N], queue: var SpscBase[N, T], item: sink T
): SPSCPushDataWritten[N] {.inline, transition.} =
  ## Write item to the slot.
  queue.storage[op.slot] = item
  let newTail = op.tail.incOrResetN1(1)
  SPSCPushDataWritten[N](newTail: newTail)

proc complete*[N: static int, T](
    op: SPSCPushDataWritten[N], queue: var SpscBase[N, T]
): bool {.inline, notATransition.} =
  ## Advance tail and return success.
  queue.tail.storeReleaseN1(op.newTail)
  true

proc extractFalse*[N: static int](op: SPSCPushFull[N]): bool {.notATransition.} =
  ## Terminal: extract false result (queue was full).
  false

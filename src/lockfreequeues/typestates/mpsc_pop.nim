## MPSC Pop operation lifecycle typestate.
##
## Enforces correct sequencing for single-consumer pop:
## Start -> LoadPointers -> CheckEmpty -> CheckCommitted -> Complete
##
## Key difference from SPMC/MPMC: Uncommitted = terminal (return None), not retry.
## Single consumer owns head, so no CAS needed.
##
## Uses N-slot arithmetic with committed flags.

import atomics
import typestates

import ./virtual_values_n
import ./storage_n
import ./committed_flags_n
import ./atomic_loaders
import ./fullness_checks
import ./mpsc_push  # For MupsicBase

type
  MPSCPopStart*[N: static int] = object
    ## Entry point. No data yet.

  MPSCPopPointersLoaded*[N: static int] = object
    ## Loaded head and reservedTail.
    head*: WrappedValueN[N]
    reservedTail*: WrappedValueN[N]

  MPSCPopNotEmpty*[N: static int] = object
    ## Confirmed queue has items. Need to check committed.
    head*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  MPSCPopSlotReady*[N: static int] = object
    ## Slot is committed - safe to read.
    head*: WrappedValueN[N]
    slot*: PhysicalSlotN[N]

  MPSCPopEmpty*[N: static int] = object
    ## Terminal: queue was empty (or head slot not committed).


typestate MPSCPopOp[N: static int]:
  inheritsFromRootObj = true
  states MPSCPopStart[N], MPSCPopPointersLoaded[N], MPSCPopNotEmpty[N],
         MPSCPopSlotReady[N], MPSCPopEmpty[N]
  transitions:
    MPSCPopStart[N] -> MPSCPopPointersLoaded[N]
    MPSCPopPointersLoaded[N] -> MPSCPopNotEmpty[N] | MPSCPopEmpty[N] as MPSCEmptyCheck[N]
    MPSCPopNotEmpty[N] -> MPSCPopSlotReady[N] | MPSCPopEmpty[N] as MPSCCommittedCheck[N]


proc start*[N: static int](): MPSCPopStart[N] {.inline.} =
  ## Begin a pop operation.
  MPSCPopStart[N]()


proc loadPointers*[N, P: static int, T](
  op: MPSCPopStart[N],
  queue: var MupsicBase[N, P, T]
): MPSCPopPointersLoaded[N] {.inline, transition.} =
  ## Load head and reservedTail atomically.
  let head = loadAcquireN[N](queue.head).validate()
  let reservedTail = loadAcquireN[N](queue.reservedTail).validate()
  MPSCPopPointersLoaded[N](head: head, reservedTail: reservedTail)


proc checkEmpty*[N: static int](
  op: MPSCPopPointersLoaded[N]
): MPSCEmptyCheck[N] {.inline, transition.} =
  ## Check if queue is empty. Returns branch type.
  if emptyN(op.head, op.reservedTail):
    MPSCEmptyCheck[N] -> MPSCPopEmpty[N]()
  else:
    let slot = op.head.index()
    MPSCEmptyCheck[N] -> MPSCPopNotEmpty[N](head: op.head, slot: slot)


proc checkCommitted*[N, P: static int, T](
  op: MPSCPopNotEmpty[N],
  queue: var MupsicBase[N, P, T]
): MPSCCommittedCheck[N] {.inline, transition.} =
  ## Check if slot is committed.
  ## MPSC KEY: Uncommitted = terminal (return Empty), NOT retry like SPMC/MPMC.
  if not queue.committed.load(op.slot):
    MPSCCommittedCheck[N] -> MPSCPopEmpty[N]()  # Producer still writing - return none
  else:
    MPSCCommittedCheck[N] -> MPSCPopSlotReady[N](head: op.head, slot: op.slot)


proc complete*[N, P: static int, T](
  op: MPSCPopSlotReady[N],
  queue: var MupsicBase[N, P, T]
): T {.inline.} =
  ## Read value, clear committed, advance head. Returns the value.
  let value = queue.storage[op.slot]
  queue.committed.store(op.slot, false)
  let newHead = op.head.incOrResetN(1)
  queue.head.storeReleaseN(newHead)
  value

## SPSC Pop operation lifecycle typestate.
##
## Enforces correct sequencing for single-consumer pop:
## Start -> LoadPointers -> CheckEmpty -> Complete
##
## Key invariant: Once NotEmpty is reached, we MUST read and advance head.
##
## Uses N+1 slot arithmetic (no committed flags needed for SPSC).

import atomics
import typestates

import ./virtual_values_n1
import ./storage_n1
import ./atomic_loaders
import ./fullness_checks
import ./spsc_push # For SipsicBase

type
  SPSCPopStart*[N: static int] = object ## Entry point. No data yet.

  SPSCPopPointersLoaded*[N: static int] = object ## Loaded head and tail.
    head*: WrappedValueN1[N]
    tail*: WrappedValueN1[N]

  SPSCPopNotEmpty*[N: static int] = object ## Confirmed queue has items. MUST complete.
    head*: WrappedValueN1[N]
    slot*: PhysicalSlotN1[N]

  SPSCPopEmpty*[N: static int] = object ## Terminal: queue was empty.

typestate SPSCPopOp[N: static int]:
  inheritsFromRootObj = true
  states SPSCPopStart[N], SPSCPopPointersLoaded[N], SPSCPopNotEmpty[N], SPSCPopEmpty[N]
  transitions:
    SPSCPopStart[N] -> SPSCPopPointersLoaded[N]
    SPSCPopPointersLoaded[N] -> SPSCPopNotEmpty[N] | SPSCPopEmpty[N] as SPSCEmptyCheck[
      N
    ]

proc start*[N: static int](): SPSCPopStart[N] {.inline.} =
  ## Begin a pop operation.
  SPSCPopStart[N]()

proc loadPointers*[N: static int, T](
    op: SPSCPopStart[N], queue: var SipsicBase[N, T]
): SPSCPopPointersLoaded[N] {.inline, transition.} =
  ## Load head and tail atomically.
  let head = loadAcquireN1[N](queue.head).validate()
  let tail = loadSequentialN1[N](queue.tail).validate()
  SPSCPopPointersLoaded[N](head: head, tail: tail)

proc checkEmpty*[N: static int](
    op: SPSCPopPointersLoaded[N]
): SPSCEmptyCheck[N] {.inline, transition.} =
  ## Check if queue is empty. Returns branch type.
  if emptyN1(op.head, op.tail):
    SPSCEmptyCheck[N] -> SPSCPopEmpty[N]()
  else:
    let slot = op.head.index()
    SPSCEmptyCheck[N] -> SPSCPopNotEmpty[N](head: op.head, slot: slot)

proc complete*[N: static int, T](
    op: SPSCPopNotEmpty[N], queue: var SipsicBase[N, T]
): T {.inline.} =
  ## Read value, advance head. Returns the value.
  let value = queue.storage[op.slot]
  let newHead = op.head.incOrResetN1(1)
  queue.head.storeReleaseN1(newHead)
  value

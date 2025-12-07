## Per-slot commit flags for MPSC/SPMC/MPMC queues.
##
## Only accepts PhysicalSlotN[N] for type-safe slot access.

import atomics
import ./virtual_values_n

type
  CommittedFlagsN*[N: static int] = object
    flags*: array[N, Atomic[bool]]


proc init*[N: static int](c: var CommittedFlagsN[N]) =
  for i in 0..<N:
    c.flags[i].store(false, moRelaxed)

proc load*[N: static int](c: var CommittedFlagsN[N], idx: PhysicalSlotN[N]): bool {.inline.} =
  c.flags[idx.slotValue].load(moAcquire)

proc store*[N: static int](c: var CommittedFlagsN[N], idx: PhysicalSlotN[N], val: bool) {.inline.} =
  c.flags[idx.slotValue].store(val, moRelease)

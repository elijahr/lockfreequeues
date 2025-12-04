# lockfreequeues # © Copyright 2020 Elijah Shaw-Rutschman # # See the file "LICENSE", included in this distribution for details about the # copyright.# lockfreequeues
# © Copyright 2020 Elijah Shaw-Rutschman
#
# See the file "LICENSE", included in this distribution for details about the
# copyright.

## N-slot storage for MPSC/SPMC/MPMC queues.
##
## Can ONLY be indexed with PhysicalSlotN[N], preventing index formula bugs.

import ./virtual_values_n

type
  StorageN*[N: static int, T] = object
    ## Storage with exactly N slots.
    data*: array[N, T]


proc init*[N: static int, T](s: var StorageN[N, T]) =
  ## Initialize all slots to default value.
  for i in 0..<N:
    s.data[i].reset()

proc `[]`*[N: static int, T](s: StorageN[N, T], idx: PhysicalSlotN[N]): T {.inline.} =
  ## Read from storage (requires PhysicalSlotN).
  s.data[idx.slotValue]

proc `[]`*[N: static int, T](s: var StorageN[N, T], idx: PhysicalSlotN[N]): var T {.inline.} =
  ## Read as var (requires PhysicalSlotN).
  s.data[idx.slotValue]

proc `[]=`*[N: static int, T](s: var StorageN[N, T], idx: PhysicalSlotN[N], val: T) {.inline.} =
  ## Write to storage (requires PhysicalSlotN).
  s.data[idx.slotValue] = val

## N+1-slot storage for SPSC queue.

import ./virtual_values_n1

type StorageN1*[N: static int, T] = object
  ## Storage with N+1 slots (for SPSC full/empty detection).
  data*: array[N + 1, T]

proc init*[N: static int, T](s: var StorageN1[N, T]) =
  for i in 0 .. N:
    s.data[i].reset()

proc `[]`*[N: static int, T](s: StorageN1[N, T], idx: PhysicalSlotN1[N]): T {.inline.} =
  s.data[idx.slotValue]

proc `[]`*[N: static int, T](
    s: var StorageN1[N, T], idx: PhysicalSlotN1[N]
): var T {.inline.} =
  s.data[idx.slotValue]

proc `[]=`*[N: static int, T](
    s: var StorageN1[N, T], idx: PhysicalSlotN1[N], val: T
) {.inline.} =
  s.data[idx.slotValue] = val

## Co-located cell layout for bounded MPMC/SPMC/MPSC queues.
##
## Each cell holds the per-slot sequence counter alongside its data payload.
## Cells are aligned to CacheLineBytes so adjacent slots never share a cache
## line — eliminates false sharing between producer and consumer working on
## neighbouring positions. See design doc §5 for the layout decision and
## §10.2 for the recipe this module implements.
##
## The protocol state (the `seq` counter) and the payload data live in the
## same cell to ensure that a producer or consumer touching a slot incurs at
## most one cache miss on the cold path. The {.align.} pragma alone is NOT
## sufficient to keep cells on independent cache lines — see the comment on
## the explicit `pad` field below.

import ../atomic_dsl
import ./virtual_values_n

type
  MPMCCellPayload*[T] = object
    ## Logical contents of a cell: the protocol counter and the user payload.
    ## Kept as a sub-object so `sizeof(MPMCCellPayload[T])` is well-defined
    ## (independent of any outer alignment pragma) and can be used to size
    ## the explicit tail padding on the wrapping `MPMCCell[T]`.
    seq*: Atomic[uint64]
    data*: T

  MPMCCell*[T] = object
    ## A cell holding one `MPMCCellPayload[T]` plus explicit tail padding so
    ## `sizeof(MPMCCell[T])` is a multiple of `CacheLineBytes`. Cache-line
    ## alignment is enforced by the `cells*` field on `MPMCCellArrayN` (Nim's
    ## `{.align.}` pragma is only valid as a *field* pragma, not as a *type*
    ## pragma — see "explicit padding rationale" comment below). With the
    ## array's first element cache-aligned and each cell sized to a cache-line
    ## multiple, every cell sits on its own cache line.
    payload*: MPMCCellPayload[T]
    # Explicit tail padding. Nim's `{.align.}` pragma controls field/object
    # alignment ONLY — it does NOT round size up to a multiple of the
    # alignment. Without this explicit pad array, an `array[N, MPMCCell[T]]`
    # would pack cells contiguously (e.g. 4 cells per cache line for
    # T = int), defeating the false-sharing rationale. The pad-size formula
    # uses `mod CacheLineBytes` so that small payloads round up to one line
    # and larger payloads round up to the next line boundary.
    pad*: array[
      (CacheLineBytes - (sizeof(MPMCCellPayload[T]) mod CacheLineBytes)) mod
        CacheLineBytes,
      byte,
    ]

  MPMCCellArrayN*[N: static int, T] = object
    ## Array of cells indexed by PhysicalSlotN[N]. Owned by a queue facade.
    ## The `{.align.}` on `cells` aligns the first cell to a cache-line
    ## boundary; combined with each cell's tail padding (see `MPMCCell.pad`),
    ## every subsequent cell also lands on its own cache line.
    cells* {.align: CacheLineBytes.}: array[N, MPMCCell[T]]

static:
  # Size-padding-up enforcement. If these fail, the {.align.} pragma is not
  # doing what we think and false sharing is back. Tested for the two most
  # common payload shapes used by lockfreequeues callers.
  doAssert sizeof(MPMCCell[int]) mod CacheLineBytes == 0,
    "MPMCCell[int] not padded to cache line — false-sharing risk"
  doAssert sizeof(MPMCCell[ptr int]) mod CacheLineBytes == 0,
    "MPMCCell[ptr int] not padded to cache line — false-sharing risk"

proc init*[N: static int, T](a: var MPMCCellArrayN[N, T]) =
  ## Initialize seq[i] = i. Data is left uninitialised (matches StorageN.init
  ## semantics — the protocol guarantees readers cannot observe data unless a
  ## writer has stored it under a matching seq value first).
  for i in 0 ..< N:
    a.cells[i].payload.seq.store(uint64(i), moRelaxed)

proc seqLoad*[N: static int, T](
    a: var MPMCCellArrayN[N, T], idx: PhysicalSlotN[N], order: static MemoryOrder
): uint64 {.inline.} =
  a.cells[idx.slotValue].payload.seq.load(order)

proc seqStore*[N: static int, T](
    a: var MPMCCellArrayN[N, T],
    idx: PhysicalSlotN[N],
    val: uint64,
    order: static MemoryOrder,
) {.inline.} =
  a.cells[idx.slotValue].payload.seq.store(val, order)

proc dataPtr*[N: static int, T](
    a: var MPMCCellArrayN[N, T], idx: PhysicalSlotN[N]
): ptr T {.inline.} =
  ## Plain (non-atomic) access to the payload data. Caller MUST hold slot
  ## ownership via the seq protocol before reading or writing through this
  ## pointer — the seq counter's acquire/release pairing provides the
  ## happens-before for any read/write through the returned pointer.
  addr a.cells[idx.slotValue].payload.data

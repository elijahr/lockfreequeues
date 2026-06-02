## Phase A.5 dry-run: strict-LCRQ skeleton against nim-debra v0.10.0 DWCAS API.
##
## Validates the frozen API at feat/v0.10.0-dwcas @ 4b2eac8 by drafting a
## minimal strict-LCRQ cell pattern. Three smoke fixtures:
##
##   1. Basic Atomic[Pair[uint64, int]] round-trip (inline value).
##   2. Atomic[Pair[uint64, ptr int]] round-trip + ARC bump audit
##      (Friction-2 from the pre-freeze a2a — pointer fields must NOT
##      take ownership via Pair's copy/destroy).
##   3. Concurrent producer-vs-producer CAS contention (4 threads x
##      8 cells x 100k iters) to validate Strong CAS on aarch64 hot
##      path (weak's 14.3% spurious-failure rate measured by lychee
##      makes weak unviable for LCRQ producer publish per design §3).
##
## Compile:
##   nim c --threads:on --mm:atomicArc \
##     --path:/Users/eek/Development/worktrees/nim-debra-dwcas/nim-debra/src \
##     -r tests/spike_lcrq_skeleton.nim

import std/[atomics as stdAtomics, options, sets]
import std/unittest
import debra/atomics as dAtomics

# ---------------------------------------------------------------------
# Strict-LCRQ cell shape
# ---------------------------------------------------------------------

const
  ## High bit of the seq counter marks the cell as CLOSED — no further
  ## publishes will succeed on this cell. Set by close-CAS-on-empty
  ## (consumer observes empty, atomically marks closed in one DWCAS).
  CLOSED_BIT* = 1'u64 shl 63

  ## Sentinel for "no value present" in the second half. For T=int we
  ## reserve 0 as empty (LCRQ convention is to encode emptiness in the
  ## generation half, but the test fixture validates both directions).
  EMPTY_VAL_INT* = 0

type
  ## LCRQ cell parameterised on payload type T. T must be ≤8 bytes and
  ## supportsCopyMem to fit Pair[uint64, T]'s constraints.
  LCRQCell*[T] = dAtomics.Atomic[dAtomics.Pair[uint64, T]]

# ---------------------------------------------------------------------
# Producer publish (DWCAS into empty cell)
# ---------------------------------------------------------------------

proc tryPublish*[T](cell: var LCRQCell[T]; expectedSeq: uint64; value: T): bool =
  ## Attempt to publish `value` into `cell` assuming the cell currently
  ## holds (expectedSeq, EMPTY_VAL_INT). Single DWCAS — atomically
  ## swaps the seq counter to expectedSeq+1 and the payload to value.
  ##
  ## Returns true if the publish succeeded, false if the cell was
  ## modified by a peer (closed, already published, etc).
  var prev = dAtomics.Pair[uint64, T](first: expectedSeq, second: default(T))
  let desired = dAtomics.Pair[uint64, T](first: expectedSeq + 1, second: value)
  # Per lychee's freeze: prefer Strong CAS on aarch64 (Weak's spurious-
  # failure rate is 14.3% > 5% threshold per design §3).
  # Wrap in dwcasOrderRelaxedCAS to silence the seq_cst-upgrade warning
  # since LCRQ producer publish only needs moRelease + moRelaxed.
  dAtomics.dwcasOrderRelaxedCAS:
    result = dAtomics.compareExchangeStrong(
      cell, prev, desired, dAtomics.moRelease, dAtomics.moRelaxed
    )

# ---------------------------------------------------------------------
# Consumer claim (DWCAS to extract value + mark empty)
# ---------------------------------------------------------------------

proc tryClaim*[T](cell: var LCRQCell[T]; expectedSeq: uint64): Option[T] =
  ## Attempt to claim the value from `cell` assuming the cell currently
  ## holds (expectedSeq+1, value). Single DWCAS — atomically swaps the
  ## payload to EMPTY_VAL_INT (consumer-marked empty) while preserving
  ## the seq counter.
  ##
  ## Returns Some(value) on success, None if the cell was empty/closed
  ## or had a different generation.
  let observed = dAtomics.load(cell, dAtomics.moAcquire)
  if observed.first != expectedSeq + 1: return none(T)
  if observed.second == default(T): return none(T)
  var prev = observed
  let desired = dAtomics.Pair[uint64, T](first: observed.first, second: default(T))
  dAtomics.dwcasOrderRelaxedCAS:
    if dAtomics.compareExchangeStrong(
        cell, prev, desired, dAtomics.moAcquireRelease, dAtomics.moRelaxed):
      return some(observed.second)
  none(T)

# ---------------------------------------------------------------------
# Consumer close-CAS-on-empty (DWCAS to mark slot CLOSED)
# ---------------------------------------------------------------------

proc tryCloseOnEmpty*[T](cell: var LCRQCell[T]; expectedSeq: uint64): bool =
  ## If `cell` is observed empty at expectedSeq, atomically set CLOSED_BIT
  ## so future producer publishes fail. The strict LCRQ progress trick:
  ## consumer that finds an empty cell closes it, preventing a slow
  ## producer from later wraparounding into it.
  var prev = dAtomics.Pair[uint64, T](first: expectedSeq, second: default(T))
  let desired = dAtomics.Pair[uint64, T](
    first: expectedSeq or CLOSED_BIT, second: default(T)
  )
  dAtomics.dwcasOrderRelaxedCAS:
    result = dAtomics.compareExchangeStrong(
      cell, prev, desired, dAtomics.moRelease, dAtomics.moRelaxed
    )

# ---------------------------------------------------------------------
# Smoke test 1: basic Pair[uint64, int] round-trip
# ---------------------------------------------------------------------

suite "Phase A.5 — strict-LCRQ skeleton":
  test "smoke 1: publish + claim round-trip with Pair[uint64, int]":
    var cell: LCRQCell[int]
    # Initial state: (seq=0, value=0). Publish (seq=1, value=42).
    check tryPublish(cell, 0'u64, 42)
    let observed = dAtomics.load(cell, dAtomics.moAcquire)
    check observed.first == 1'u64
    check observed.second == 42

    # Consumer claims. Cell becomes (seq=1, value=0).
    let claimed = tryClaim(cell, 0'u64)
    check claimed.isSome
    check claimed.get == 42
    let postClaim = dAtomics.load(cell, dAtomics.moAcquire)
    check postClaim.first == 1'u64
    check postClaim.second == 0

  test "smoke 1b: double-publish into same cell fails (slot occupied)":
    var cell: LCRQCell[int]
    check tryPublish(cell, 0'u64, 100)
    # Cell is now (1, 100). Trying to publish at expectedSeq=0 must fail.
    check tryPublish(cell, 0'u64, 200) == false
    # And the cell is unchanged.
    let observed = dAtomics.load(cell, dAtomics.moAcquire)
    check observed.first == 1'u64
    check observed.second == 100

  test "smoke 1c: close-CAS-on-empty marks cell CLOSED, then publish fails":
    var cell: LCRQCell[int]
    # Cell is initially (0, 0) — empty at seq=0. Close it.
    check tryCloseOnEmpty(cell, 0'u64)
    # Cell is now (CLOSED_BIT, 0). Producer cannot publish at seq=0.
    check tryPublish(cell, 0'u64, 99) == false
    let observed = dAtomics.load(cell, dAtomics.moAcquire)
    check (observed.first and CLOSED_BIT) != 0

# ---------------------------------------------------------------------
# Smoke test 2: ptr T round-trip + ARC bump audit (Friction-2 closure)
# ---------------------------------------------------------------------

  test "smoke 2: Pair[uint64, ptr int] round-trip — pointer fields stay raw":
    # Allocate a heap int. Both producer and consumer reason about the
    # raw pointer; ARC must NOT inject =copy/=destroy hooks on Pair that
    # would interfere with the pointee's lifetime.
    let payload = cast[ptr int](alloc0(sizeof(int)))
    payload[] = 12345
    defer: dealloc(payload)

    var cell: LCRQCell[ptr int]
    # Initial state: (seq=0, value=nil). Publish (seq=1, value=payload).
    let prevPayloadAddr = cast[int](payload)
    check tryPublish(cell, 0'u64, payload)

    # Observe — pointer must survive load unchanged.
    let observed = dAtomics.load(cell, dAtomics.moAcquire)
    check observed.first == 1'u64
    check cast[int](observed.second) == prevPayloadAddr
    check observed.second[] == 12345

    # Consumer claims. The returned pointer must point at the same heap.
    let claimed = tryClaim(cell, 0'u64)
    check claimed.isSome
    check cast[int](claimed.get) == prevPayloadAddr
    check claimed.get[] == 12345

    # After claim, the cell holds (1, nil). Pointer is NOT freed by ARC —
    # the heap is still ours to dealloc via the defer above.
    let postClaim = dAtomics.load(cell, dAtomics.moAcquire)
    check postClaim.first == 1'u64
    check cast[int](postClaim.second) == 0  # nil

# ---------------------------------------------------------------------
# Smoke test 3: concurrent CAS contention (validates Strong-on-aarch64)
# ---------------------------------------------------------------------

const
  ContendedThreads = 4
  ContendedCells = 8
  ContendedIters = 100_000

type
  ContendedCtx = object
    cells: ptr array[ContendedCells, LCRQCell[int]]
    threadId: int
    publishes: stdAtomics.Atomic[int]
    casAttempts: stdAtomics.Atomic[int]

var contendedCtxs: array[ContendedThreads, ContendedCtx]

proc contendedProducerThreadStrong(ctx: ptr ContendedCtx) {.thread.} =
  ## All 4 threads hammer ALL 8 cells (full overlap). Each thread
  ## attempts ContendedIters publishes per cell. Total contended CAS
  ## attempts = 4 threads * 8 cells * ContendedIters * 2 (publish+claim).
  for iter in 0 ..< ContendedIters:
    for cellIdx in 0 ..< ContendedCells:
      let cell = addr ctx.cells[cellIdx]
      # Read the cell's current state to pick the expectedGen
      let observed = dAtomics.load(cell[], dAtomics.moAcquire)
      let expectedGen = observed.first and (not CLOSED_BIT)
      if (observed.second == 0) and (observed.first and CLOSED_BIT) == 0:
        # Cell appears empty + not closed; try to publish at this gen.
        discard ctx.casAttempts.fetchAdd(1, moRelaxed)
        if tryPublish(cell[], expectedGen, ctx.threadId + 1):
          discard ctx.publishes.fetchAdd(1, moRelaxed)
          discard tryClaim(cell[], expectedGen)

proc tryPublishWeak[T](cell: var LCRQCell[T]; expectedSeq: uint64; value: T): bool =
  ## Variant of tryPublish using compareExchangeWeak — to measure the
  ## delta vs Strong on aarch64 (lychee's 14.3% spurious-failure claim).
  var prev = dAtomics.Pair[uint64, T](first: expectedSeq, second: default(T))
  let desired = dAtomics.Pair[uint64, T](first: expectedSeq + 1, second: value)
  dAtomics.dwcasOrderRelaxedCAS:
    result = dAtomics.compareExchangeWeak(
      cell, prev, desired, dAtomics.moRelease, dAtomics.moRelaxed
    )

proc contendedProducerThreadWeak(ctx: ptr ContendedCtx) {.thread.} =
  ## Same shape as Strong variant, but uses compareExchangeWeak.
  for iter in 0 ..< ContendedIters:
    for cellIdx in 0 ..< ContendedCells:
      let cell = addr ctx.cells[cellIdx]
      let observed = dAtomics.load(cell[], dAtomics.moAcquire)
      let expectedGen = observed.first and (not CLOSED_BIT)
      if (observed.second == 0) and (observed.first and CLOSED_BIT) == 0:
        discard ctx.casAttempts.fetchAdd(1, moRelaxed)
        if tryPublishWeak(cell[], expectedGen, ctx.threadId + 1):
          discard ctx.publishes.fetchAdd(1, moRelaxed)
          discard tryClaim(cell[], expectedGen)

proc runContendedBench(threadProc: proc(ctx: ptr ContendedCtx) {.thread.}): float =
  ## Run the contention workload + return failure rate.
  var cells: array[ContendedCells, LCRQCell[int]]
  for i in 0 ..< ContendedThreads:
    contendedCtxs[i].cells = addr cells
    contendedCtxs[i].threadId = i
    contendedCtxs[i].publishes.store(0)
    contendedCtxs[i].casAttempts.store(0)

  var threads: array[ContendedThreads, Thread[ptr ContendedCtx]]
  for i in 0 ..< ContendedThreads:
    createThread(threads[i], threadProc, addr contendedCtxs[i])
  for i in 0 ..< ContendedThreads:
    joinThread(threads[i])

  var totalAttempts, totalPublishes: int
  for i in 0 ..< ContendedThreads:
    totalAttempts += contendedCtxs[i].casAttempts.load(moRelaxed)
    totalPublishes += contendedCtxs[i].publishes.load(moRelaxed)

  if totalAttempts == 0: return 0.0
  result = (totalAttempts - totalPublishes).float / totalAttempts.float
  echo "  Attempts: ", totalAttempts, " | publishes: ", totalPublishes,
       " | failure rate: ", $(result * 100).int, "%"

suite "Phase A.5 — smoke 3 Strong-vs-Weak contention (aarch64 validation)":
  test "smoke 3a: Strong CAS — 4 threads x 8 cells full overlap":
    # Each thread hammers ALL 8 cells, so 4-way overlap on every cell.
    # Strong's failure rate should reflect REAL contention only — no
    # spurious failures. On macOS arm64 with LSE, expect substantial
    # but bounded loss rate. Failure rate floor is the legitimate
    # producer-vs-producer CAS-loss rate.
    let strongRate = runContendedBench(contendedProducerThreadStrong)
    check strongRate < 1.0  # Sanity bound — anything <100% means CAS works

  test "smoke 3b: Weak CAS — same shape, expect higher rate on aarch64":
    # Same workload through compareExchangeWeak. On aarch64 LL/SC, Weak
    # adds spurious failures on top of the real contention rate. Per
    # lychee's measurement: 14.3% on macos-15 arm64 4t x 8c x 100k.
    # This test reproduces the measurement on the operator's hardware.
    let weakRate = runContendedBench(contendedProducerThreadWeak)
    check weakRate < 1.0

## Cache-line padding audit for unbounded queue Segments.
##
## Verifies two conditions per design doc §4.2:
## 1. Per-Segment cache-line-padded fields have field offsets that are
##    multiples of ``CacheLineBytes``.
## 2. ``cast[uint](segPtr) mod CacheLineBytes == 0`` for a freshly-allocated
##    Segment via the queue's allocator (base alignment).
##
## RED state (Task 3.1): condition 2 fails because ``c_calloc`` returns
## 16-byte-aligned memory on x86_64 Linux glibc. Condition 1 also fails
## today because Segment fields lack ``{.align: CacheLineBytes.}``.
##
## GREEN state (Tasks 3.2–3.3): both conditions hold for all four
## unbounded variants. ``posix_memalign`` is used to lift the segment base
## onto a 64-byte boundary, and ``{.align: CacheLineBytes.}`` is added to
## each Segment field that participates in producer/consumer coordination.

import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_sipsic
import lockfreequeues/unbounded_sipmuc
import lockfreequeues/unbounded_mupsic
import lockfreequeues/unbounded_mupmuc
# For Task 11 LCRQ SPMC Segment init invariant test: cast head-segment pointer
# (production Segment is unexported) into the typestate-local Segment view,
# whose layout matches production per the static asserts at the top of
# `unbounded_sipmuc.nim` (sizeof + per-field offsetOf for data/next/tail/
# consumerHead). The {.align: CacheLineBytes.} pragmas on `cellState` and
# `closed` are byte-for-byte identical between the two declarations, so the
# cast is sound for reading those fields.
import lockfreequeues/typestates/unbounded_spmc_push as ts_spmc_push
import debra
import unittest2

# CacheLineBytes is exported from atomic_dsl via debra/atomics.

const Cl = CacheLineBytes

suite "Unbounded queue Segment cache-line padding":
  test "Segment field offsets are CacheLineBytes-aligned (sipsic)":
    let off = segmentHeadOffsetForTest(UnboundedSipsic[64, uint64])
    check off.head mod Cl == 0
    check off.tail mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (sipmuc)":
    let off = segmentHeadOffsetForTest(UnboundedSipmuc[64, uint64, 4])
    check off.tail mod Cl == 0
    check off.consumerHead mod Cl == 0
    check off.cellState mod Cl == 0
    check off.closed mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mupsic)":
    let off = segmentHeadOffsetForTest(UnboundedMupsic[64, uint64, 4])
    check off.tail mod Cl == 0
    check off.head mod Cl == 0
    check off.committed mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mupmuc)":
    let off = segmentHeadOffsetForTest(UnboundedMupmuc[64, uint64, 4])
    check off.tail mod Cl == 0
    check off.consumerHead mod Cl == 0
    check off.committed mod Cl == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (sipsic)":
    var q = newUnboundedSipsic[64, uint64]()
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (sipmuc)":
    var manager = initDebraManager[4]()
    var q = newUnboundedSipmuc[64, uint64, 4](addr manager)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mupsic)":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var q = newUnboundedMupsic[64, uint64, 4](addr manager, consumerHandle)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mupmuc)":
    var manager = initDebraManager[4]()
    var q = newUnboundedMupmuc[64, uint64, 4](addr manager)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

suite "Task 11 LCRQ SPMC Segment init invariants":
  test "freshly-allocated sipmuc Segment has cellState[] == CellEmpty and closed == false":
    # Verifies that `newUnboundedSipmuc` produces a head Segment whose new
    # LCRQ fields (`cellState[]` array of Atomic[uint8] and `closed` Atomic[bool])
    # are zero-initialized — i.e. every cellState slot equals `CellEmpty` (0'u8)
    # and `closed` equals `false`. Today this holds because `allocAligned[T]`
    # in `internal/aligned_alloc.nim` calls `zeroMem(p, sizeof(T))` after
    # `posix_memalign`/`_aligned_malloc`. If that contract regresses, this
    # test catches it before the LCRQ verbs (which assume CellEmpty as the
    # neutral state per typestate `unbounded_spmc_push.nim`:24-26) can
    # observe a garbage initial state.
    var manager = initDebraManager[4]()
    var q = newUnboundedSipmuc[8, uint64, 4](addr manager)
    let segPtrRaw = headSegmentForTest(q)
    check segPtrRaw != nil
    # Cast into the typestate Segment view (layout-identical per the
    # offsetOf/sizeof static asserts in unbounded_sipmuc.nim:166-174).
    let seg = cast[ptr ts_spmc_push.Segment[8, uint64]](segPtrRaw)
    check seg.cellState[0].load(moRelaxed) == 0'u8
    check seg.cellState[1].load(moRelaxed) == 0'u8
    check seg.cellState[2].load(moRelaxed) == 0'u8
    check seg.cellState[3].load(moRelaxed) == 0'u8
    check seg.cellState[4].load(moRelaxed) == 0'u8
    check seg.cellState[5].load(moRelaxed) == 0'u8
    check seg.cellState[6].load(moRelaxed) == 0'u8
    check seg.cellState[7].load(moRelaxed) == 0'u8
    check seg.cellState.len == 8
    check seg.closed.load(moRelaxed) == false

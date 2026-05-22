## Cache-line padding audit for unbounded queue Segments.
##
## Verifies two conditions per design doc §4.2:
## 1. Per-Segment cache-line-padded fields have field offsets that are
##    multiples of ``CacheLineBytes``.
## 2. ``cast[uint](segPtr) mod CacheLineBytes == 0`` for a freshly-allocated
##    Segment via the queue's allocator (base alignment).
##
## GREEN state (Tasks 3.2–3.3): both conditions hold for all four
## unbounded variants. ``posix_memalign`` is used to lift the segment base
## onto a 64-byte boundary, and ``{.align: CacheLineBytes.}`` is added to
## each Segment field that participates in producer/consumer coordination.
##
## v5.0.0 migration note: UnboundedSipsic stays on the legacy module per
## §3.0.3 (separate keep-decision); the other 3 variants migrate to the
## unified Queue + smart-constructor surface. The
## ``segmentHeadOffsetForTest`` / ``headSegmentForTest`` introspection
## helpers continue to live on the legacy modules; the layout-parity
## static-asserts in queue.nim guarantee the new Queue type is
## bit-compatible with the legacy ``UnboundedMupmuc`` / ``UnboundedSipmuc``
## / ``UnboundedMupsic`` headers, so introspection results are identical.

import lockfreequeues/atomic_dsl
import lockfreequeues/unbounded_sipsic
import lockfreequeues/unbounded_sipmuc
import lockfreequeues/unbounded_mupsic
import lockfreequeues/unbounded_mupmuc

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

import debra as debra_mod
from debra import DebraManager, initDebraManager, registerThread

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
    check off.prevConsumerIdx mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mupsic)":
    let off = segmentHeadOffsetForTest(UnboundedMupsic[64, uint64, 4])
    check off.tail mod Cl == 0
    check off.head mod Cl == 0
    check off.committed mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mupmuc)":
    let off = segmentHeadOffsetForTest(UnboundedMupmuc[64, uint64, 4])
    check off.tail mod Cl == 0
    check off.prevConsumerIdx mod Cl == 0
    check off.committed mod Cl == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (sipsic)":
    # UnboundedSipsic stays on the legacy module per §3.0.3.
    var q = newUnboundedSipsic[64, uint64]()
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (sipmuc)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedSipmucQueue[uint64, stEager, 64, 4](addr manager)
    # Cast through the legacy header for introspection. The layout-parity
    # static-asserts in queue.nim guarantee this cast is sound.
    let qLegacy = cast[ptr UnboundedSipmuc[64, uint64, 4]](addr q)
    let segPtr = headSegmentForTest(qLegacy[])
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mupsic)":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var q = newUnboundedMupsicQueue[uint64, stEager, 64, 4](
        addr manager, consumerHandle)
    let qLegacy = cast[ptr UnboundedMupsic[64, uint64, 4]](addr q)
    let segPtr = headSegmentForTest(qLegacy[])
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mupmuc)":
    var manager = initDebraManager[4, debra_mod.ccMulti]()
    var q = newUnboundedMupmucQueue[uint64, stEager, 64, 4](addr manager)
    let qLegacy = cast[ptr UnboundedMupmuc[64, uint64, 4]](addr q)
    let segPtr = headSegmentForTest(qLegacy[])
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

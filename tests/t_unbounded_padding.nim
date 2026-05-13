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

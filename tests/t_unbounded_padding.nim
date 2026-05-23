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
## v5.0.0 migration note: post-3.3.11-B.2.5 the standalone
## `UnboundedSipsic[S, T]` was absorbed into
## `Queue[T, ccSingle, ccSingle, stEager, S, MaxThreads]`. The sipsic
## padding checks now go through the unified Queue + Segment helpers
## like the other three variants.

import lockfreequeues/atomic_dsl

import lockfreequeues/queue as q_mod
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

# nim-debra surface for the unbounded smart-constructor manager. Selective
# `from ... import` matches the queue.nim convention and keeps
# `debra.ccSingle` / `debra.ccMulti` qualified-only, avoiding the
# unqualified `PinScopeCardinality` collision with the stub.
from debra import DebraManager, initDebraManager, registerThread

import unittest2

# CacheLineBytes is exported from atomic_dsl via debra/atomics.

const Cl = CacheLineBytes

suite "Unbounded queue Segment cache-line padding":
  test "Segment field offsets are CacheLineBytes-aligned (sipsic)":
    # Queue[T, ccSingle, ccSingle, _, 64, 4] — sipsic-absorbed Segment
    # carries `tail` (Atomic) and `head` (non-atomic int) as cache-line-
    # padded fields. `committed` and `prevConsumerIdx` are not present.
    type Seg = q_mod.Segment[uint64, ccSingle, ccSingle, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentHeadOffsetForTest(Seg) mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (sipmuc)":
    # Queue[T, ccSingle, ccMulti, _, 64, 4] — Segment for
    # the sipmuc-equiv shape carries `tail` and `prevConsumerIdx` as
    # cache-line-padded fields. `head` and `committed` are not present
    # on this shape (their helpers would compile-fail here).
    type Seg = q_mod.Segment[uint64, ccSingle, ccMulti, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentPrevConsumerIdxOffsetForTest(Seg) mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mupsic)":
    # Queue[T, ccMulti, ccSingle, _, rkEbr, ...] — Segment for the
    # mupsic-equiv shape carries `tail`, `head`, and `committed` as
    # cache-line-padded fields. `prevConsumerIdx` is not present.
    type Seg = q_mod.Segment[uint64, ccMulti, ccSingle, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentHeadOffsetForTest(Seg) mod Cl == 0
    check segmentCommittedOffsetForTest(Seg) mod Cl == 0

  test "Segment field offsets are CacheLineBytes-aligned (mupmuc)":
    # Queue[T, ccMulti, ccMulti, _, rkEbr, ...] — Segment for the
    # mupmuc-equiv shape carries `tail`, `prevConsumerIdx`, and
    # `committed` as cache-line-padded fields. `head` is not present on
    # the ccProd==ccMulti × ccCons==ccMulti shape (only on
    # ccProd==ccMulti × ccCons==ccSingle).
    type Seg = q_mod.Segment[uint64, ccMulti, ccMulti, 64]
    check segmentTailOffsetForTest(Seg) mod Cl == 0
    check segmentPrevConsumerIdxOffsetForTest(Seg) mod Cl == 0
    check segmentCommittedOffsetForTest(Seg) mod Cl == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (sipsic)":
    var q = newUnboundedSipsicQueue[uint64, stEager, 64, 4]()
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (sipmuc)":
    var manager = initDebraManager[4, debra.ccMulti]()
    var q = newUnboundedSipmucQueue[uint64, stEager, 64, 4](addr manager)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mupsic)":
    var manager = initDebraManager[4]()
    let consumerHandle = registerThread(manager)
    var q = newUnboundedMupsicQueue[uint64, stEager, 64, 4](
        addr manager, consumerHandle)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

  test "freshly-allocated Segment base is CacheLineBytes-aligned (mupmuc)":
    var manager = initDebraManager[4, debra.ccMulti]()
    var q = newUnboundedMupmucQueue[uint64, stEager, 64, 4](addr manager)
    let segPtr = headSegmentForTest(q)
    check segPtr != nil
    check (cast[uint](segPtr) mod Cl.uint) == 0

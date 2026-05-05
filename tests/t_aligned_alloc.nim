## Unit tests for ``internal/aligned_alloc.nim``.
##
## Verifies that ``allocAligned[T]`` returns ``CacheLineBytes``-aligned,
## zero-initialized memory across a range of payload sizes (struct under,
## equal-to, and over a single cache line).

import lockfreequeues/atomic_dsl
import lockfreequeues/internal/aligned_alloc
import unittest2

type
  Tiny = object
    a: int

  Line = object
    a: int
    b: int
    c: int
    d: int
    e: int
    f: int
    g: int
    h: int

  Big = object
    a: array[256, byte]

suite "internal/aligned_alloc.allocAligned":
  test "tiny payload (sizeof < CacheLineBytes) is 64B-aligned":
    let p = allocAligned[Tiny]()
    check p != nil
    check (cast[uint](p) mod CacheLineBytes.uint) == 0
    check p.a == 0 # zero-initialized
    freeAligned(p)

  test "line-sized payload (sizeof == CacheLineBytes) is 64B-aligned":
    let p = allocAligned[Line]()
    check p != nil
    check (cast[uint](p) mod CacheLineBytes.uint) == 0
    check p.a == 0
    check p.h == 0
    freeAligned(p)

  test "big payload (sizeof > CacheLineBytes) is 64B-aligned":
    let p = allocAligned[Big]()
    check p != nil
    check (cast[uint](p) mod CacheLineBytes.uint) == 0
    for i in 0 ..< 256:
      check p.a[i] == 0.byte
    freeAligned(p)

  test "many allocations are all 64B-aligned":
    var ptrs: array[64, ptr Line]
    for i in 0 ..< 64:
      ptrs[i] = allocAligned[Line]()
      check ptrs[i] != nil
      check (cast[uint](ptrs[i]) mod CacheLineBytes.uint) == 0
    for i in 0 ..< 64:
      freeAligned(ptrs[i])

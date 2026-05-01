## Cache-line-aligned heap allocation for unbounded queue Segments.
##
## Project-wide invariant (design doc §4.2): every ``Segment[S, T]`` allocation
## must be aligned to ``CacheLineBytes`` (64 on x86_64) so that the
## ``{.align: CacheLineBytes.}`` pragma on internal Atomic fields lifts those
## fields onto distinct physical cache lines, not merely distinct intra-struct
## offsets that share a 16-byte-aligned base with adjacent allocations.
##
## ``c_calloc`` / ``c_malloc`` only guarantee ``2 * sizeof(size_t) == 16`` bytes
## of alignment under glibc and macOS libSystem. Without ``posix_memalign``, the
## first cache-line slot of every Segment is split across two physical lines
## and false-shares with whatever neighbours the heap happens to place
## adjacent.
##
## Compile probe verified at impl-plan time (Task 3.2.0): the C
## ``posix_memalign`` from ``<stdlib.h>`` is callable from both ``nim c`` and
## ``nim cpp`` on macOS (libSystem) and Linux glibc, returning 64-byte
## aligned memory and ``rc == 0`` on success.
##
## Note: ``std/posix.posix_memalign`` was the first candidate, but on macOS
## the Apple SDK declares the first parameter with the
## ``__unsafe_indexable`` attribute under C++, which the Nim wrapper does
## not match — ``nim cpp`` then fails with
## "cannot convert argument of incomplete type 'void *' to 'void **'".
## The local importc shim below uses the canonical C signature, which
## clang accepts in both C and C++ modes.

proc posix_memalign(
    memptr: ptr pointer, alignment: csize_t, size: csize_t
): cint {.importc, header: "<stdlib.h>".}

import ../atomic_dsl
export CacheLineBytes

proc allocAligned*[T](): ptr T =
  ## Allocate one zero-initialized ``T`` on a ``CacheLineBytes`` boundary.
  ##
  ## Raises ``OutOfMemDefect`` on allocation failure (matches the existing
  ## ``c_calloc`` failure path in unbounded queue ``newSegment`` procs).
  ##
  ## The caller owns the returned pointer; release with ``freeAligned`` or
  ## the standard ``c_free`` (``posix_memalign`` blocks are compatible with
  ## ``free`` per POSIX).
  var p: pointer
  if posix_memalign(addr p, csize_t(CacheLineBytes), csize_t(sizeof(T))) != 0:
    raise newException(OutOfMemDefect, "posix_memalign failed for " & $T)
  zeroMem(p, sizeof(T))
  result = cast[ptr T](p)

when isMainModule:
  # Smoke test: verify allocAligned returns 64-byte aligned memory.
  type Probe = object
    a: int
    b: array[128, byte]
  let p = allocAligned[Probe]()
  doAssert p != nil
  doAssert (cast[uint](p) mod CacheLineBytes.uint) == 0
  echo "allocAligned[Probe] -> ", cast[uint](p), " (mod 64 = ", cast[uint](p) mod 64'u, ")"

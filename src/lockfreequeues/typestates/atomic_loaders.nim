## Type-safe atomic load/store for queue pointers.

import atomics
import ./virtual_values_n
import ./virtual_values_n1


# N-slot loaders
proc loadAcquireN*[N: static int](a: var Atomic[int]): RawLoadedN[N] {.inline.} =
  initRawN[N](a.load(moAcquire))

proc loadSequentialN*[N: static int](a: var Atomic[int]): RawLoadedN[N] {.inline.} =
  initRawN[N](a.load(moSequentiallyConsistent))


# N+1-slot loaders
proc loadAcquireN1*[N: static int](a: var Atomic[int]): RawLoadedN1[N] {.inline.} =
  initRawN1[N](a.load(moAcquire))

proc loadSequentialN1*[N: static int](a: var Atomic[int]): RawLoadedN1[N] {.inline.} =
  initRawN1[N](a.load(moSequentiallyConsistent))


# N-slot store - ONLY way to extract value from WrappedValueN
proc storeReleaseN*[N: static int](a: var Atomic[int], v: WrappedValueN[N]) {.inline.} =
  a.store(v.value, moRelease)


# N+1-slot store - ONLY way to extract value from WrappedValueN1
proc storeReleaseN1*[N: static int](a: var Atomic[int], v: WrappedValueN1[N]) {.inline.} =
  a.store(v.value, moRelease)

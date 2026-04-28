## Atomic primitives and ergonomic DSL for lockfreequeues.
##
## Re-exports `debra/atomics` (Atomic[T], MemoryOrder, AtomicFlag,
## load, store, exchange, fetch*, compareExchangeStrong, compareExchangeWeak,
## CacheLineBytes, fences) and `debra/atomics/dsl` (relaxed/acquire/release/
## sequential shorthand for load and store).
##
## Provides one local compatibility shim: a bare `compareExchange` that
## delegates to `compareExchangeStrong`, matching the historical
## `std/atomics` spelling used throughout lockfreequeues.

import debra/atomics
export atomics

import debra/atomics/dsl
export dsl

proc compareExchange*[T](
    loc: var Atomic[T];
    expected: var T;
    desired: T;
    success: static MemoryOrder = moSequentiallyConsistent;
    failure: static MemoryOrder = moSequentiallyConsistent;
): bool {.inline.} =
  ## Strong compare-and-exchange. Compatibility spelling for
  ## `compareExchangeStrong`; matches `std/atomics`'s unsuffixed name.
  compareExchangeStrong(loc, expected, desired, success, failure)

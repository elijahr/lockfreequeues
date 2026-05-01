## Atomic primitives and ergonomic DSL for lockfreequeues.
##
## Re-exports `debra/atomics` (Atomic[T], MemoryOrder, AtomicFlag,
## load, store, exchange, fetch*, compareExchange, compareExchangeStrong,
## compareExchangeWeak, CacheLineBytes, fences) and `debra/atomics/dsl`
## (relaxed/acquire/release/sequential shorthand for load and store).

import debra/atomics
export atomics

import debra/atomics/dsl
export dsl

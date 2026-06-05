## Phase B T13: negative control — unbounded MPMC `Queue[T]` rejects
## wide T at compile time.
##
## Per v5.0.0 BREAKING (design §11.2): the strict-LCRQ migration
## publishes via 128-bit DWCAS into `Atomic[Pair[uint64, T]]`, which
## constrains T to `supportsCopyMem(T) and sizeof(T) <= 8` on the
## `ccMulti × ccMulti` arm of `Queue`. Compiling a queue with
## `sizeof(T) > 8` MUST fail.
##
## Concretely: `array[3, int]` is 24 bytes on a 64-bit target — well
## over the 8-byte ceiling.
##
## Two layered guards reject wide T (either is sufficient; in
## practice (1) fires first at construction):
##   1. debra's `enforceDwcasConstraints` static assertion fires from
##      `Atomic[Pair[uint64, T]].store` inside `newSegment`:
##      "sizeof(B) <= 8 Pair half-type ... must be <= 8 bytes".
##   2. The v5.0.0 `{.error.}` block in `proc push` (queue.nim L1136-
##      L1145): "requires sizeof(T) <= 8".
##
## The runner pins debra's substring ("Pair half-type") — the OUTER
## enforcement layer that fires at construction. If the narrowing is
## ever removed from the unbounded MPMC arm, BOTH layers stop firing
## and the test fails — the tripwire is sound either way.
##
## This is the structural twin of
## `tests/t_bqueue_mpmc_wide_T_accepted.nim` (the positive control):
## together they form the SCOPE-7 tripwire against accidental
## cross-queue constraint extension during Phase B.

import lockfreequeues/queue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

proc main() =
  var q = newUnboundedMpmcQueue[array[3, int], stEager, 16, 4]()
  var producer = q.getProducerHere()
  let item: array[3, int] = [1, 2, 3]
  # Wide T (24 bytes) on the ccMulti × ccMulti arm must fail with the
  # pinned substring "requires sizeof(T) <= 8".
  producer.push(item)

main()

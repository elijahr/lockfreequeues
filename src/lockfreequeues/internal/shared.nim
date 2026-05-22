## Shared helpers consumed by both `bqueue` and `queue` post-3.3.11-B.
##
## This module is the M2 anchor for cross-cutting helpers that BQueue
## (bounded, no debra) and Queue (unbounded, debra-integrated) both
## depend on. Per the brief's no-cross-import / no-duplication
## constraint, anything that lives here must NOT be re-declared in
## either consuming module.
##
## **Scope policy.** `internal/` is private by convention — downstream
## consumers reaching into `lockfreequeues/internal/shared` are off the
## supported surface. Helpers that declare or consume typestates do NOT
## live here (per F.3.5 intra-module containment, those stay in their
## owning file).
##
## **B.1 status.** During sub-dispatch B.1 (Bundles A + B only), the
## still-unified `queue.nim` is left intact and continues to declare
## its own `NoSlice` constant. The constant is re-defined here so the
## new `bqueue.nim` can pull it from a future-stable home without
## reaching into queue.nim. Bundle C (sub-dispatch B.2) will strip the
## duplicate from queue.nim and route both modules through this file.
## The transient duplication is intentional, narrowly scoped, and
## byte-identical between the two homes — Bundle C is responsible for
## the consolidation.

import options

const NoSlice* = none(HSlice[int, int])
  ## Canonical "no failed range" sentinel for batch-push return values.
  ##
  ## Both BQueue and Queue batch-`push` overloads return
  ## `Option[HSlice[int, int]]` where `none` means the whole batch
  ## succeeded and `some(lo .. hi)` flags the slice of input items that
  ## did NOT make it onto the queue (capacity full).
  ##
  ## Defined here so both modules reference the same `none(HSlice[...])`
  ## value rather than each constructing their own — keeps the API
  ## semantics aligned by construction.

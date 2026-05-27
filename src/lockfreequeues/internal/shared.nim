## Shared helpers consumed by both `bqueue` and `queue`.
##
## Cross-cutting helpers that BQueue (bounded, no debra) and Queue
## (unbounded, debra-integrated) both depend on. Anything that lives
## here must NOT be re-declared in either consuming module.
##
## **Scope policy.** `internal/` is private by convention — downstream
## consumers reaching into `lockfreequeues/internal/shared` are off the
## supported surface. Helpers that declare or consume typestates do NOT
## live here (intra-module containment keeps those in their owning
## file).

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

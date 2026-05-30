##
## Endpoint types for static thread-affinity. See design §3.3.1.
##
## Spike C2.5 result: single-family import graph clean (outcome G).
##
## C3 ships the base three typestates (`Unbound` / `Bound` / `Closed`)
## as generic over `(T, Tag, queueT)` only. The plan template originally
## sketched a `when queueT is Queue:` branch carrying a debra
## `ThreadHandle[queueT.MaxThreads]` field; Nim 2.2's eager generic
## resolution rejects `is Queue` on a 6-static-param generic without
## bound arguments. Per pepper's MCLD call (2026-05-30): the Queue
## specialisation (`handle` field, registerThread/unregisterThread,
## close transition) moves wholesale to Task C6, where the queue-
## specific behaviour already lands. C3 deviates from the plan template
## only in moving the `when`-branch to its natural home; the spirit
## (compile-time Queue specialisation) is preserved at C6 via either a
## distinct `QueueBound` variant, a queueT-constrained re-introduction
## of the `when`-branch, or proc overloads — whichever reads cleanest at
## the implementation site.
##
## R10 fallback (per design §3.3.1): if the three-axis generic typestate
## trips a nim-typestates corner case in Task C4, drop `queueT` from the
## typestate axis and store it as a non-typestate field.

{.experimental: "strictEffects".}

type
  Unbound*[T; Tag; queueT] = object
    queue*: ptr queueT
    idx*: int

  Bound*[T; Tag; queueT] = object
    queue*: ptr queueT
    idx*: int
    when defined(debug):
      attachedTid*: int

  Closed*[T; Tag; queueT] = object

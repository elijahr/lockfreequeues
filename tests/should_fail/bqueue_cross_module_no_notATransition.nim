## 3.3.11-B.4.1.6 Bundle F.3.5 deliberate-negative cross-module
## containment test (case 14):
##
## Verifies that a `{.transition.}`-tagged proc declared in an
## EXTERNAL module (i.e., a different file from the BQueueLifecycle
## typestate declaration in `bqueue.nim`) is REJECTED by the
## typestates v0.9.3 verifier. The reject site is
## `nim-typestates/src/typestates/pragmas.nim:742-751`:
##
##     Cannot define transition on typestate '<name>' from external
##     module. The typestate was defined in '<path>'. Transitions
##     must be defined in the same module as the typestate
##     declaration. Hint: Use {.notATransition.} for read-only
##     operations on imported states.
##
## This is the load-bearing test that proves F.3.5 intra-module
## containment is actually enforced — without it, the same-module
## discipline of Bundle F (`bqueue.nim` owns both the BQueueLifecycle
## typestate declaration and every state-preserving op) would be a
## convention rather than a checked invariant.
##
## Per the master brief F.3.5: "Both the Lifecycle and Claim-state
## typestate declarations AND their consuming procs MUST live in the
## same module ... to avoid the cross-module prohibition firing."

import lockfreequeues/bqueue
import typestates

# A `{.transition.}` proc on the BQueueLifecycle states, declared in
# THIS test module rather than in `bqueue.nim`. The verifier must
# reject this at the `{.transition.}` pragma site.
proc evilTransition*[
    T;
    ccProd, ccCons: static PinScopeCardinality,
    N, P, C: static int,
](
    s: BQueueInit[T, ccProd, ccCons, N, P, C]
): BQueueDestroyed[T, ccProd, ccCons, N, P, C] {.transition.} =
  BQueueDestroyed[T, ccProd, ccCons, N, P, C](
    BQueueLifecycleCtx[T, ccProd, ccCons, N, P, C](s)
  )

# EXPECTED COMPILE ERROR — pragmas.nim:742-751:
# "Cannot define transition on typestate 'BQueueLifecycle' from
# external module."

## §6.3 condition (4) / γ bounded-asymmetry guard: `q.retireOnCAS(...)`
## on a bounded queue (`BQueue`) must fail to compile.
##
## BQueue (bounded) and Queue (unbounded) are
## separate types. `retireOnCAS` is defined only on `Queue` — there is
## no `retireOnCAS` overload on `BQueue` at all, so the dot-call cannot
## resolve and compilation fails with method-not-defined.

import std/atomics

import lockfreequeues/bqueue
import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/internal/pinscope_stub

import debra as debra_mod
from debra import
  DebraManager, initDebraManager, registerThread, pinScope, unpinned, Destructor

proc main() =
  # Build a real ccMulti pinned scope so the non-receiver args type-check
  # cleanly and the resolution failure is unambiguously on the receiver
  # (i.e. the γ guard via RK = rkNone, not an arg-mismatch).
  var manager = initDebraManager[4, debra_mod.ccMulti]()
  let handle = registerThread(manager)
  var scope = pinScope(unpinned(handle))
  # Bounded receiver (RK = rkNone) — no `retireOnCAS` overload exists.
  # Use newMpmcQueue smart constructor to dodge bare ccMulti type-literal
  # collisions (umbrella enum + debra enum share the same identifier
  # in this module since both are imported).
  var bq = newMpmcQueue[int, 16, 4, 4]()
  var dummyAtomic: Atomic[pointer]
  discard bq.retireOnCAS(
    scope, dummyAtomic, pointer(nil), pointer(nil), Destructor(nil)
  )

main()

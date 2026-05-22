## §6.3 condition (4) / γ bounded-asymmetry guard: `q.retireOnCAS(...)`
## on a bounded queue (`Queue[..., RK = rkNone, ...]`) must fail to
## compile.
##
## Per Doc C §3.0.2, `retireOnCAS` / `retireOnPublish` are defined only
## for `RK == rkEbr` (the receiver-type overload constraint). The γ
## guard fires via UFCS lookup failure: no `proc retireOnCAS` overload
## accepts a `Queue[..., rkNone, ...]` receiver, so the dot-call cannot
## resolve.

import std/atomics

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
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
  # Use newMupmucQueue smart-ctor to dodge bare ccMulti type-literal
  # collisions (umbrella enum + debra enum share the same identifier
  # in this module since both are imported).
  var bq = newMupmucQueue[int, 16, 4, 4]()
  var dummyAtomic: Atomic[pointer]
  discard bq.retireOnCAS(
    scope, dummyAtomic, pointer(nil), pointer(nil), Destructor(nil)
  )

main()

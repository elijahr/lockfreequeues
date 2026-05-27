## §6.3 condition (5) / γ bounded-asymmetry guard: `q.retireOnPublish(...)`
## on an unbounded `Queue[..., ccCons = ccMulti, RK = rkEbr, ...]` must
## fail to compile.
##
## Per Doc C §3.0.2, `retireOnPublish` is defined only when
## `RK == rkEbr AND ccCons == ccSingle` (the DR-S4 single-writer foot-gun
## gate). Calling it on a multi-consumer rkEbr queue must fail UFCS
## lookup at the dot-call site.

import std/atomics

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

import debra as debra_mod
from debra import initDebraManager, registerThread, pinScope, unpinned, Destructor

proc main() =
  var manager = initDebraManager[4, debra_mod.ccMulti]()
  let handle = registerThread(manager)
  var scope = pinScope(unpinned(handle))
  # ccCons = ccMulti, RK = rkEbr — `retireOnPublish` is gated to
  # ccCons = ccSingle only, so no overload accepts this receiver.
  var q = newUnboundedMpmcQueue[int, stEager, 16, 4](addr manager)
  var dummyAtomic: Atomic[pointer]
  q.retireOnPublish(scope, dummyAtomic, pointer(nil), Destructor(nil))

main()

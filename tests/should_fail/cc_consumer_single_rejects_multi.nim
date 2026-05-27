## §6.3 condition (2) / brief §3.3: a Queue with `ccCons == ccSingle`
## rejects a `ccMulti` DebraManager/handle pair.
##
## `newUnboundedMpscQueue` (`ccMulti × ccSingle`) borrow-overload
## requires `DebraManager[MT, debra.ccSingle]` and
## `ThreadHandle[MT, debra.ccSingle]` per Doc C §3.0.4 / §3.1. Passing
## a ccMulti-cardinality manager/handle pair must fail type-checking.

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

import debra as debra_mod
from debra import initDebraManager, registerThread

proc main() =
  var manager = initDebraManager[4, debra_mod.ccMulti]()
  let handle = registerThread(manager) # ThreadHandle[4, debra.ccMulti]
  # newUnboundedMpscQueue's borrow overload requires
  # `DebraManager[4, debra.ccSingle]`; passing the ccMulti pair must
  # fail type-checking with a type-mismatch error.
  var q = newUnboundedMpscQueue[int, stEager, 16, 4](addr manager, handle)
  discard q.segmentCount()

main()

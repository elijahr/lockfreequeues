## §6.3 condition (3) / brief §3.3: a Queue with `ccCons == ccMulti`
## rejects a `ccSingle` DebraManager.
##
## `newUnboundedMupmucQueue` (`ccMulti × ccMulti`) borrow-overload
## requires `DebraManager[MT, debra.ccMulti]` per Doc C §3.0.4 / §3.1
## (Step 3.3.4.5 soundness fix: consumer-pin CC must be ccMulti for
## ccCons == ccMulti). Passing a ccSingle-cardinality manager must
## fail type-checking.

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub

from debra import initDebraManager

proc main() =
  # initDebraManager[MT] defaults the CC to debra.ccSingle, producing
  # `DebraManager[4, debra.ccSingle]`. Feed it to a ccCons == ccMulti
  # smart-constructor that demands `DebraManager[4, debra.ccMulti]`.
  var manager = initDebraManager[4]()
  var q = newUnboundedMupmucQueue[int, stEager, 16, 4](addr manager)
  discard q.segmentCount()

main()

## ccSingle BQueueProducer cannot call `attach()`.
##
## Claim-state typestate uses a single user-facing object
## type with `when ccProd == ccMulti:` internal layout switch (Wall 2
## fix from B.4.1.5). `attach` is declared ONLY with the
## `BQueueProducer[T, ccMulti, ccCons, N, P, C]` param signature, so
## the compiler statically excludes ccSingle from the attach overload
## set. Calling `attach()` on a `BQueueProducer[..., ccSingle, ...]`
## must produce a "type mismatch" diagnostic that names the
## user-visible alias type `BQueueProducer` (NOT a `*Multi`/`*Single`
## backing type).

import lockfreequeues/bqueue

proc main() =
  var q = newSpscQueue[int, 8]()
  # A ccSingle BQueueProducer is constructible but has no attach
  # overload. The type-mismatch diagnostic comes from Nim's overload
  # resolution — there is literally no proc named `attach` whose
  # first param matches `var BQueueProducer[int, ccSingle, ...]`.
  var p: BQueueProducer[int, ccSingle, ccSingle, 8, 0, 0]
  p.queue = addr q
  p.attach() # EXPECTED COMPILE ERROR

main()

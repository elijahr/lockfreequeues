discard """
  errormsg: "SpscProducerTag"
"""
## C9 tripwire (c): a region marked `{.forbids: [SpscProducerTag].}`
## that calls a `{.tags: [SpscProducerTag, ...].}` proc must reject at
## compile time under `{.experimental: "strictEffects".}`. This is the
## load-bearing test for the effect-region static guarantee — the BQueue
## push overload at `bqueue.nim` carries
## `{.tags: [Tag, TypestateOp, RootEffect].}`; with `Tag = SpscProducerTag`
## at the call site, the forbids region rejects.

{.experimental: "strictEffects".}

import lockfreequeues/bqueue
import lockfreequeues/endpoint
import lockfreequeues/role_tags

proc pureRegion(
    b: var Bound[int, SpscProducerTag, BQueue[int, ccMulti, ccSingle, 64, 4, 0]]
) {.forbids: [SpscProducerTag].} =
  discard b.push(1)
    # MUST FAIL: push() carries SpscProducerTag in its effect set;
    # this region forbids that tag.

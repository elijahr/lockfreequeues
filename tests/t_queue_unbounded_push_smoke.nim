## Smoke fixtures for the rkEbr push body
## across all 4 cardinality variants (spsc-equiv, spmc-equiv,
## mpsc-equiv, mpmc-equiv).
##
## Exercises:
##   - 4-variant push compiles and runs end-to-end via the unified
##     `Queue[..., rkEbr, ...]` shape with `getProducer().push(item)`.
##   - Segment-growth boundary: pushing SEGSIZE+N items crosses one or
##     more segment boundaries; `segmentCount` increments and items
##     are accounted in `len`.
##   - §3.5.6 Pin-Claim Ordering: multi-producer variants exercise the
##     `pinScope(unpinned(self.handle))` path. The visual-review
##     guarantee that the pin is acquired BEFORE the segment-pointer
##     load is encoded in `src/lockfreequeues/queue.nim`'s push body
##     (see the §3.5.6 comment block above the `block:` scope in the
##     ccProd == ccMulti branch).
##
## **Behaviour gap acknowledged**: pop lands in a follow-up. These smoke
## fixtures exercise push only; pop is invoked via the existing rkNone
## stubs would not work for rkEbr queues. We verify push-side
## observable state (`len`, `segmentCount`) instead of round-tripping
## items.
##
## 

import unittest2

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

suite "rkEbr push smoke — spsc-equiv (ccSingle × ccSingle)":
  test "single item push increments len":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    p.push(42)
    check q.len() == 1
    check q.segmentCount() == 1

  test "fills first segment without growth":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 8:
      p.push(i)
    check q.len() == 8
    check q.segmentCount() == 1

  test "crosses segment boundary on item SEGSIZE+1":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 9: # SEGSIZE=8 → item 9 forces growth.
      p.push(i)
    check q.len() == 9
    check q.segmentCount() == 2

suite "rkEbr push smoke — spmc-equiv (ccSingle × ccMulti)":
  test "single item push increments len":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    p.push(42)
    check q.len() == 1
    check q.segmentCount() == 1

  test "crosses segment boundary":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 17: # crosses 2 boundaries (8 → 16 → 17)
      p.push(i)
    check q.len() == 17
    check q.segmentCount() == 3

suite "rkEbr push smoke — mpsc-equiv (ccMulti × ccSingle)":
  ## §3.5.4 pin-only site. Pin acquired BEFORE segment-pointer load
  ## (§3.5.6 Pin-Claim Ordering).
  test "single producer pushes items, pin/unpin cycle clean":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 5:
      p.push(i)
    check q.len() == 5
    check q.segmentCount() == 1

  test "single producer crosses segment boundary":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 17:
      p.push(i)
    check q.len() == 17
    check q.segmentCount() == 3

suite "rkEbr push smoke — mpmc-equiv (ccMulti × ccMulti)":
  ## §3.5.5 pin-only site. Pin acquired BEFORE segment-pointer load
  ## (§3.5.6 Pin-Claim Ordering).
  test "single producer pushes items, pin/unpin cycle clean":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 5:
      p.push(i)
    check q.len() == 5
    check q.segmentCount() == 1

  test "single producer crosses segment boundary":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    for i in 0 ..< 17:
      p.push(i)
    check q.len() == 17
    check q.segmentCount() == 3

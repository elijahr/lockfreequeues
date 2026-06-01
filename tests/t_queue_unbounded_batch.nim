## Smoke fixtures for the v5.0.0 rkEbr batch push/pop wrappers across
## all 4 cardinality variants.
##
## Exercises (8 tests):
##   - `QueueProducer.push(items: openArray[T])` round-trip across the
##     4 rkEbr cardinality variants (spsc-equiv, spmc-equiv,
##     mpsc-equiv, mpmc-equiv): push N items via openArray, drain
##     via single-item pop, assert order + content.
##   - `pop(count: int): Option[seq[T]]` round-trip across the 4
##     rkEbr cardinality variants: push N items via the new batch
##     push, then `pop(count)`, assert returned `Option[seq[T]]` is
##     `some` with correct elements.
##   - Boundary checks: `pop(0)` returns `none`; `pop(count)` where
##     count > available returns `some(seq)` with up-to-available
##     elements.
##
## 
## Gap-fill between 3.3.6a (spsc call-site migration) and 3.3.6b-e
## (bulk migration). Pure additive; thin loop wrappers over the
## existing single-item rkEbr push/pop bodies.

import unittest2
import std/options

import lockfreequeues/queue
import lockfreequeues/strategy
import lockfreequeues/reclamation
import lockfreequeues/internal/pinscope_stub
import lockfreequeues/endpoint
import lockfreequeues/role_tags

# --- push(openArray) round-trip — all 4 cardinality variants -------------

suite "rkEbr batch push (openArray) — spsc-equiv (ccSingle × ccSingle)":
  test "openArray push then drain via single-item pop preserves FIFO":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    let items = [10, 20, 30, 40, 50]
    p.push(items)
    check q.len() == items.len
    for i in 0 ..< items.len:
      let r = lfqConsumer.pop()
      check r.isSome
      check r.get == items[i]
    check lfqConsumer.pop().isNone

suite "rkEbr batch push (openArray) — spmc-equiv (ccSingle × ccMulti)":
  test "openArray push then drain via single-item pop preserves FIFO":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    let items = [11, 21, 31, 41, 51]
    p.push(items)
    check q.len() == items.len
    for i in 0 ..< items.len:
      let r = c.pop()
      check r.isSome
      check r.get == items[i]
    check c.pop().isNone

suite "rkEbr batch push (openArray) — mpsc-equiv (ccMulti × ccSingle)":
  test "openArray push then drain via single-item pop preserves FIFO":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    var lfqConsumer = q.bindConsumer()
    var p = q.getProducerHere()
    let items = [12, 22, 32, 42, 52]
    p.push(items)
    check q.len() == items.len
    for i in 0 ..< items.len:
      let r = lfqConsumer.pop()
      check r.isSome
      check r.get == items[i]
    check lfqConsumer.pop().isNone

suite "rkEbr batch push (openArray) — mpmc-equiv (ccMulti × ccMulti)":
  test "openArray push then drain via single-item pop preserves FIFO":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    let items = [13, 23, 33, 43, 53]
    p.push(items)
    check q.len() == items.len
    for i in 0 ..< items.len:
      let r = c.pop()
      check r.isSome
      check r.get == items[i]
    check c.pop().isNone

# --- pop(count) round-trip — all 4 cardinality variants ------------------

suite "rkEbr batch pop (count) — spsc-equiv (ccSingle × ccSingle)":
  test "push then pop(count) returns some(seq) with correct elements":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    let items = [100, 101, 102, 103, 104]
    p.push(items)
    let r = lfqConsumer.pop(items.len)
    check r.isSome
    let got = r.get
    check got.len == items.len
    for i in 0 ..< items.len:
      check got[i] == items[i]
    check lfqConsumer.pop().isNone

  test "pop(0) returns none":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    p.push(7)
    check lfqConsumer.pop(0).isNone
    # Item is still there.
    check q.len() == 1
    check lfqConsumer.pop().get == 7

  test "pop(count > available) returns some(seq) of up-to-available":
    var q = newQueue(Queue[int, ccSingle, ccSingle, stEager, 8, 4])
    var p = q.getProducerHere()
    p.push([1, 2, 3])
    let r = lfqConsumer.pop(10)
    check r.isSome
    let got = r.get
    check got.len == 3
    check got == @[1, 2, 3]
    check lfqConsumer.pop().isNone

suite "rkEbr batch pop (count) — mpsc-equiv (ccMulti × ccSingle)":
  test "push then pop(count) returns some(seq) with correct elements":
    var q = newQueue(Queue[int, ccMulti, ccSingle, stEager, 8, 4])
    var lfqConsumer = q.bindConsumer()
    var p = q.getProducerHere()
    let items = [200, 201, 202, 203, 204]
    p.push(items)
    let r = lfqConsumer.pop(items.len)
    check r.isSome
    let got = r.get
    check got.len == items.len
    for i in 0 ..< items.len:
      check got[i] == items[i]
    check lfqConsumer.pop().isNone

suite "rkEbr batch pop (count) — spmc-equiv (ccSingle × ccMulti)":
  test "push then pop(count) via QueueConsumer returns some(seq)":
    var q = newQueue(Queue[int, ccSingle, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    let items = [300, 301, 302, 303, 304]
    p.push(items)
    let r = c.pop(items.len)
    check r.isSome
    let got = r.get
    check got.len == items.len
    for i in 0 ..< items.len:
      check got[i] == items[i]
    check c.pop().isNone

  # B.2 direct batch pop on a ccMulti-consumer Queue is now
  # a compile-time `{.error.}`. compile-fail negative-controls
  # under tests/should_fail/ exercise the gate.

suite "rkEbr batch pop (count) — mpmc-equiv (ccMulti × ccMulti)":
  test "push then pop(count) via QueueConsumer returns some(seq)":
    var q = newQueue(Queue[int, ccMulti, ccMulti, stEager, 8, 4])
    var p = q.getProducerHere()
    var c = q.getConsumerHere()
    let items = [400, 401, 402, 403, 404]
    p.push(items)
    let r = c.pop(items.len)
    check r.isSome
    let got = r.get
    check got.len == items.len
    for i in 0 ..< items.len:
      check got[i] == items[i]
    check c.pop().isNone

  # B.2 direct batch pop on a ccMulti-consumer Queue is now
  # a compile-time `{.error.}`. compile-fail negative-controls
  # under tests/should_fail/ exercise the gate.

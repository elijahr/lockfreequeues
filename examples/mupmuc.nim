## Example: Multi-producer, multi-consumer (MPMC) bounded queue using
## the unified `Queue` generic.
##
## v5.0.0 cascade migration: the legacy `Mupmuc[N, P, C, T]` family was
## collapsed into `Queue[T, ccMulti, ccMulti, stEager, rkNone, N, P, C,
## 0, 0]`. Producers and consumers are obtained via `q.getProducer()` /
## `q.getConsumer()` (one per thread).

import options
import random

import lockfreequeues

var
  # Queue that can hold 8 ints at a time,
  # with 32 producer & 32 consumer workers
  q = newMupmucQueue[int, 8, 32, 32]()


proc consumerFunc() {.thread.} =
  # Get a unique consumer for this thread
  var consumer = q.getConsumer()

  # Try to pop a single item from the queue; pop() returns Option[int]
  let item = consumer.pop()

  echo "[consumer ", consumer.idx, "] popped item: ", item

  # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
  let items = consumer.pop(4)

  echo "[consumer ", consumer.idx, "] popped items: ", items


proc producerFunc() {.thread.} =
  # Get a unique producer for this thread
  var producer = q.getProducer()

  let item = rand(100)

  # Try to push a single item; push will return false when queue is full
  echo "[producer ", producer.idx, "] pushed item: ", item, "? ", producer.push(item)

  let items = @[
    rand(100),
    rand(100),
    rand(100),
    rand(100),
  ]

  # Try to push the items. If not all items could be pushed,
  # the remainder is returned as an Option[HSlice[int, int]] suitable for
  # slicing the sequence.
  let remainder = producer.push(items)

  if remainder.isSome:
    echo "[producer ", producer.idx, "] pushed items: ", items[
        0..<remainder.get.a], ", unpushed items: ", items[remainder.get]
  else:
    echo "[producer ", producer.idx, "] pushed all items: ", items


var threads: array[64, Thread[void]]

for p in 0..<32:
  threads[p].createThread(producerFunc)

for c in 32..<64:
  threads[c].createThread(consumerFunc)

joinThreads(threads)

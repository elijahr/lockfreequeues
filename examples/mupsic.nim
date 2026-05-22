## Example usage of the unified `Queue` generic in MPSC (multi-producer,
## single-consumer) bounded cardinality.
##
## v5.0.0 cascade migration: the legacy `Mupsic[N, P, T]` family was
## collapsed into `Queue[T, ccMulti, ccSingle, stEager, rkNone, N, P,
## 0, 0, 0]`. The constructor short form below uses the
## `newMupsicQueue[T, N, P]()` smart-constructor added in v5.0.0
## (Doc C §3.0.4). Producers are obtained via `q.getProducer()` (one
## per thread) and push through the returned `QueueProducer`.

import options
import random

import lockfreequeues

var
  # Queue that can hold 8 ints at a time,
  # with 32 producer workers
  q = newMupsicQueue[int, 8, 32]()


proc consumerFunc() {.thread.} =
  for i in 0..32:
    # Try to pop a single item from the queue; pop() returns Option[int]
    let item = q.pop()

    echo "[consumer] popped item: ", item

    # Try to pop four items from the queue; pop(int) returns Option[seq[int]]
    let items = q.pop(4)

    echo "[consumer] popped items: ", items


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


var threads: array[33, Thread[void]]

threads[0].createThread(consumerFunc)

for p in 1..32:
  threads[p].createThread(producerFunc)

joinThreads(threads)
